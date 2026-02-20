import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';

import 'manifest_parser.dart';
import 'segment_cache.dart';
import '../services/logger_service.dart';

/// Local HTTP proxy that intercepts HLS manifest and segment requests.
///
/// The proxy:
///  1. Serves rewritten manifests (segment URLs → proxy URLs).
///  2. Serves cached segments or downloads them on-demand.
///  3. Handles HTTP Range requests (needed by Android ExoPlayer).
///  4. De-duplicates concurrent downloads for the same resource.
///  5. Supports cancellation of pending downloads via Dio CancelTokens.
class ProxyServer {
  // ---------------------------------------------------------------------------
  // Dependencies
  // ---------------------------------------------------------------------------
  final SegmentCache cache;

  /// Pool of 4 Dio clients for parallel requests without head-of-line blocking.
  static const int _clientPoolSize = 4;
  final List<Dio> _clientPool;
  int _clientIndex = 0;

  /// Returns the next client from the round-robin pool.
  Dio get _nextClient {
    final client = _clientPool[_clientIndex % _clientPoolSize];
    _clientIndex++;
    return client;
  }

  ProxyServer({required this.cache}) : _clientPool = List.generate(
      _clientPoolSize, 
      (_) => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent': 'Mozilla/5.0 (compatible; HLSProxy/1.0)',
          'Accept': '*/*',
          'Connection': 'keep-alive',
        },
      ))
  );

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  HttpServer? _server;
  int _port = 0;

  /// Track in-flight downloads → prevents redundant fetches.
  final Map<String, Completer<Uint8List>> _inFlightDownloads = {};
  
  /// Track cancel tokens to allow aborting requests if the user swipes away quickly.
  final Map<String, CancelToken> _cancelTokens = {};

  /// LRU in-memory cache for rewritten manifests.
  /// Strictly capped at [_maxManifestCacheEntries] to prevent OOM on long sessions.
  /// Using LinkedHashMap for O(1) LRU eviction (insertion-order = access-order).
  final LinkedHashMap<String, Uint8List> _manifestCache = LinkedHashMap<String, Uint8List>();
  static const int _maxManifestCacheEntries = 100;

  /// LRU put helper for [_manifestCache].
  ///
  /// Evicts the least-recently-used entry when the cap is reached.
  void _putManifest(String key, Uint8List data) {
    _manifestCache.remove(key); // Remove old entry if it exists (re-insert at end)
    if (_manifestCache.length >= _maxManifestCacheEntries) {
      _manifestCache.remove(_manifestCache.keys.first); // Evict LRU
    }
    _manifestCache[key] = data;
  }

  /// In-memory cache for segment URL lists (used by PreloadManager).
  final Map<String, List<String>> _segmentListCache = {};

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  int get port => _port;
  String get baseUrl => 'http://127.0.0.1:$_port';

  /// Start the proxy on a random available port on the loopback interface.
  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    LoggerService.i('[ProxyServer] Listening on $baseUrl');
    _server!.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    for (final token in _cancelTokens.values) {
      if (!token.isCancelled) token.cancel('ProxyServer shutting down');
    }
    _cancelTokens.clear();
    for (final client in _clientPool) {
      client.close(force: true);
    }
  }
  
  /// Call this when a video is swiped away to halt its pending downloads
  void cancelPendingDownloads(List<String> urls) {
    for (final url in urls) {
      final token = _cancelTokens.remove(url);
      if (token != null && !token.isCancelled) {
        token.cancel('Swiped away');
        LoggerService.d('[ProxyServer] 🛑 Cancelled download: ...${url.substring(url.length - 20 > 0 ? url.length - 20 : 0)}');
      }
    }
  }

  /// Build the proxy URL the video player should load for a given HLS
  /// manifest.
  String getProxiedManifestUrl(String originalUrl) {
    return '$baseUrl/manifest.m3u8?url=${Uri.encodeComponent(originalUrl)}';
  }

  // ---------------------------------------------------------------------------
  // Request router
  // ---------------------------------------------------------------------------

  Future<void> _handleRequest(HttpRequest request) async {
    // CORS headers (needed in debug / web)
    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS');
    request.response.headers.set('Access-Control-Allow-Headers', '*');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = 204;
      await request.response.close();
      return;
    }

    final url = request.uri.queryParameters['url'];
    if (url == null || url.isEmpty) {
      request.response.statusCode = 400;
      request.response.write('Missing ?url= parameter');
      await request.response.close();
      return;
    }

    // IMPORTANT: If the client (VideoPlayer) disconnects early, we should cancel
    // the downstream fetching to save total bandwidth.
    // We attach a listener to the client connection.
    request.response.done.catchError((_) {}).then((_) {
       // If the proxy finished properly, this is a no-op.
       // If the player closed the connection early, this gives us a hook.
    });

    try {
      final path = request.uri.path;
      if (path.endsWith('.m3u8') || path.contains('/manifest')) {
        await _handleManifest(request, url);
      } else {
        // Assume segment
        await _handleSegment(request, url);
      }
    } catch (e, st) {
      LoggerService.e('[ProxyServer] Error handling ${request.uri}: $e', stackTrace: st);
      // Fallback: Redirect to original on crash
      try {
         request.response.redirect(Uri.parse(url), status: HttpStatus.movedTemporarily);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------------------
  // Manifest handler
  // ---------------------------------------------------------------------------

  Future<void> _handleManifest(HttpRequest request, String url) async {
    final cacheKey = 'manifest:$url';

    // 1. Serve from memory cache (Fastest — 0ms)
    if (_manifestCache.containsKey(cacheKey)) {
      LoggerService.d('[ProxyServer] 🚀 Serving MANIFEST from MEMORY: $url');
      _writeManifestResponse(request, _manifestCache[cacheKey]!);
      return;
    }

    // 2. Serve from disk cache (Offline-first — survives app restarts)
    final cached = await cache.get(cacheKey);
    if (cached != null) {
      LoggerService.i('[ProxyServer] 📦 Serving MANIFEST from DISK CACHE: $url');
      _putManifest(cacheKey, cached); // Promote to memory (re-inserts at MRU end)
      _writeManifestResponse(request, cached);
      return;
    }

    // 3. Download original manifest (requires network)
    final data = await _downloadWithTimeout(url);
    if (data == null) {
      // The device is offline AND the manifest was not in disk cache.
      // Do NOT redirect — the original URL is also unreachable offline.
      // Return a proper 503 so the VideoPlayer shows a clean Retry button.
      LoggerService.w('[ProxyServer] ⚠️ Manifest unavailable offline and not cached: $url');
      try {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        request.response.write('Offline — manifest not cached');
        await request.response.close();
      } catch (_) {}
      return;
    }

    final content = utf8.decode(data, allowMalformed: true);

    // 4. Parse & rewrite (on background isolate to keep UI thread unblocked)
    final payload = ManifestParsePayload(content, url, baseUrl);
    ManifestResult result;
    
    if (ManifestParser.isMasterPlaylist(content)) {
      result = await compute(parseMasterPlaylistIsolate, payload);
    } else {
      result = await compute(parseMediaPlaylistIsolate, payload);
    }

    final rewritten = Uint8List.fromList(utf8.encode(result.rewrittenContent));

    // 5. Cache rewritten manifest to DISK so offline restarts can serve it
    _putManifest(cacheKey, rewritten); // Memory (LRU bounded)
    await cache.put(cacheKey, rewritten); // Permanent disk

    // 6. Respond
    _writeManifestResponse(request, rewritten);
  }

  void _writeManifestResponse(HttpRequest request, Uint8List data) {
    try {
       request.response.headers.set('Content-Type', 'application/vnd.apple.mpegurl');
       request.response.headers.contentLength = data.length;
       request.response.add(data);
       request.response.close();
    } catch (_) {
       // Ignore broken pipe
    }
  }

  // ---------------------------------------------------------------------------
  // Segment handler (with Range support for ExoPlayer)
  // ---------------------------------------------------------------------------

  Future<void> _handleSegment(HttpRequest request, String url) async {
    final data = await getOrDownloadSegment(url);
    if (data == null) {
      LoggerService.w('[ProxyServer] Failed to fetch segment: $url. Redirecting to upstream.');
      // FALLBACK: Redirect to original URL
      try { request.response.redirect(Uri.parse(url), status: HttpStatus.movedTemporarily); } catch (_) {}
      return;
    }

    try {
      // Content type
      final contentType = _segmentContentType(url);
      request.response.headers.set('Content-Type', contentType);
      request.response.headers.set('Accept-Ranges', 'bytes');
  
      // Range request?
      final rangeHeader = request.headers.value('range');
      if (rangeHeader != null) {
        final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
        if (match != null) {
          final start = int.parse(match.group(1)!);
          final end = match.group(2)!.isEmpty
              ? data.length - 1
              : int.parse(match.group(2)!);
          final clampedEnd = end.clamp(start, data.length - 1);
          final length = clampedEnd - start + 1;
  
          request.response.statusCode = 206;
          request.response.headers
              .set('Content-Range', 'bytes $start-$clampedEnd/${data.length}');
          request.response.headers.contentLength = length;
          
          // ZERO-TOLERANCE VM OPTIMIZATION:
          // Instead of manually copying a 2MB array from RAM -> RAM during a Range request
          // (data.sublist), we create a lightweight C-pointer view over the existing array. 
          // 0 bytes reallocated. Perfect ExoPlayer streaming.
          request.response.add(Uint8List.sublistView(data, start, clampedEnd + 1));
          await request.response.close();
          return;
        }
      }
  
      // Full response
      request.response.headers.contentLength = data.length;
      request.response.add(data);
      await request.response.close();
    } catch (_) {
      // Ignore broken pipes from closed players
    }
  }

  String _segmentContentType(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m4s') || lower.contains('.mp4') ||
        lower.contains('.m4v') || lower.contains('.m4a') ||
        lower.contains('.fmp4') || lower.contains('.cmfv') ||
        lower.contains('.cmfa')) {
      return 'video/mp4';
    }
    if (lower.contains('.aac')) return 'audio/aac';
    return 'video/MP2T'; // .ts / .ts?params default
  }

  // ---------------------------------------------------------------------------
  // Segment download with de-duplication
  // ---------------------------------------------------------------------------

  /// Returns cached segment bytes or downloads & caches them.
  ///
  /// Concurrent requests for the same URL share a single download.
  Future<Uint8List?> getOrDownloadSegment(String url) async {
    // 1. Cache hit
    final cached = await cache.get(url);
    if (cached != null) {
        LoggerService.d('[ProxyServer] 📦 Serving SEGMENT from OFFLINE CACHE: ...${url.substring(url.length - 20 > 0 ? url.length - 20 : 0)}');
        return cached;
    }

    // 2. Already downloading?
    if (_inFlightDownloads.containsKey(url)) {
      try {
        return await _inFlightDownloads[url]!.future;
      } catch (_) {
        return null;
      }
    }

    // 3. Start download
    final completer = Completer<Uint8List>();
    _inFlightDownloads[url] = completer;

    try {
      final data = await _downloadWithTimeout(url);
      if (data != null) {
        await cache.put(url, data);
        completer.complete(data);
        return data;
      }
      if (!completer.isCompleted) {
        completer.completeError(Exception('Download failed or cancelled for $url'));
      }
      return null;
    } catch (e) {
      if (!completer.isCompleted) completer.completeError(e);
      return null;
    } finally {
      _inFlightDownloads.remove(url);
      _cancelTokens.remove(url);
    }
  }

  // ---------------------------------------------------------------------------
  // Manifest pre-download (used by PreloadManager)
  // ---------------------------------------------------------------------------

  /// Download, parse, rewrite, and cache a manifest.  Returns the list of
  /// segment URLs for preloading.
  ///
  /// For master playlists the first variant is recursively fetched so that
  /// segment URLs can be returned.
  Future<List<String>> downloadAndCacheManifest(String url) async {
    final cacheKey = 'manifest:$url';

    // 1. Memory cache hit
    if (_segmentListCache.containsKey(url)) {
      return _segmentListCache[url]!;
    }

    // 2. Disk cache hit
    final cached = await cache.get(cacheKey);
    if (cached != null) {
      // We already have the rewritten manifest; try to get the segment list
      // from the original.
      final originalKey = 'original:$url';
      final originalData = await cache.get(originalKey);
      if (originalData != null) {
        final content = utf8.decode(originalData, allowMalformed: true);
        if (!ManifestParser.isMasterPlaylist(content)) {
          final payload = ManifestParsePayload(content, url, baseUrl);
          final result = await compute(parseMediaPlaylistIsolate, payload);
          return result.segmentUrls;
        }
      }
    }

    // Download fresh
    final data = await _downloadWithTimeout(url);
    if (data == null) return const [];

    final content = utf8.decode(data, allowMalformed: true);

    // Cache original (for segment-URL extraction later)
    await cache.put('original:$url', data);

    final payload = ManifestParsePayload(content, url, baseUrl);
    ManifestResult result;
    
    if (ManifestParser.isMasterPlaylist(content)) {
      result = await compute(parseMasterPlaylistIsolate, payload);
      final rewritten =
          Uint8List.fromList(utf8.encode(result.rewrittenContent));
      _putManifest(cacheKey, rewritten); // Cache in memory (LRU)
      await cache.put(cacheKey, rewritten); // And disk

      // Pick first (lowest-bandwidth) variant for pre-loading
      if (result.variantUrls.isNotEmpty) {
        return downloadAndCacheManifest(result.variantUrls.first);
      }
      return const [];
    } else {
      result = await compute(parseMediaPlaylistIsolate, payload);
      final rewritten =
          Uint8List.fromList(utf8.encode(result.rewrittenContent));
      _putManifest(cacheKey, rewritten); // Cache in memory (LRU)
      await cache.put(cacheKey, rewritten);
      
      final urls = result.segmentUrls;
      _segmentListCache[url] = urls; // Cache list in memory
      return urls;
    }
  }

  // ---------------------------------------------------------------------------
  // HTTP helper
  // ---------------------------------------------------------------------------

  /// Downloads [url] with timeout, retry, and exponential backoff using Dio.
  /// Uses a fresh client from the pool so large downloads don't block other requests.
  Future<Uint8List?> _downloadWithTimeout(
    String url, {
    int retries = 2,
  }) async {
    // Generate cancel token to allow aborting this specific download
    final cancelToken = CancelToken();
    _cancelTokens[url] = cancelToken;
    
    final client = _nextClient;
    int attempt = 0;
    
    while (attempt < retries) {
      if (cancelToken.isCancelled) {
          LoggerService.d('[ProxyServer] Download aborted early via CancelToken: $url');
          return null;
      }
      
      if (attempt > 0) {
        final backoff = Duration(milliseconds: 300 * (1 << (attempt - 1)));
        LoggerService.w('[ProxyServer] Retrying ($attempt/$retries) for $url after ${backoff.inMilliseconds}ms');
        try {
          await Future.delayed(backoff);
        } catch (_) {}
      }
      attempt++;

      final start = DateTime.now();
      try {
        LoggerService.d('[ProxyServer] Download Attempt $attempt: ...${url.substring(url.length - 15 > 0 ? url.length - 15 : 0)}');
        
        final response = await client.get<List<int>>(
          url,
          cancelToken: cancelToken,
          options: Options(responseType: ResponseType.bytes),
        );

        final elapsed = DateTime.now().difference(start).inMilliseconds;

        if (response.statusCode != null && response.statusCode! >= 200 && response.statusCode! < 300) {
          // ZERO-TOLERANCE VM OPTIMIZATION:
          // Dio ResponseType.bytes heavily uses Uint8List under the hood. 
          // By checking the runtime type, we can instantly bridge the memory
          // to our caching pipeline without triggering a `fromList` loop 
          // that would copy 5,000,000 individual bytes and starve the GC.
          final rawData = response.data;
          final Uint8List bytes = rawData is Uint8List 
              ? rawData 
              : Uint8List.fromList(rawData as List<int>);

          LoggerService.d('[ProxyServer] Downloaded ${bytes.length} bytes in ${elapsed}ms: ...${url.substring(url.length - 15 > 0 ? url.length - 15 : 0)}');
          return bytes;
        }

        // 503 Service Unavailable -> Retryable
        if (response.statusCode == 503 || response.statusCode == 429) {
          LoggerService.w('[ProxyServer] HTTP ${response.statusCode} (Retryable) for $url');
          continue; // Trigger retry
        }

        LoggerService.e('[ProxyServer] HTTP ${response.statusCode} in ${elapsed}ms for $url');
        return null; 

      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
           LoggerService.d('[ProxyServer] Download CANCELLED by user: ...${url.substring(url.length - 15 > 0 ? url.length - 15 : 0)}');
           return null;
        }
        
        if (e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout) {
           LoggerService.e('[ProxyServer] Timeout downloading $url');
           continue; // Retry
        }
        
        if (e.type == DioExceptionType.connectionError) {
           LoggerService.w('[ProxyServer] 🚫 OFFLINE / Network unreachable for $url. Error: ${e.message}');
           return null; // Don't retry if offline
        }
        
        LoggerService.e('[ProxyServer] DioError for $url: ${e.message}');
        // Might be a 404/403
        if (e.response?.statusCode != 503 && e.response?.statusCode != 429) {
            return null; 
        }
      } catch (e) {
        LoggerService.e('[ProxyServer] Download error for $url: $e');
        return null;
      }
    }
    return null; // All retries failed
  }
}
