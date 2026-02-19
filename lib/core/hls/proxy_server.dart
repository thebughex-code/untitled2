import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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
class ProxyServer {
  // ---------------------------------------------------------------------------
  // Dependencies
  // ---------------------------------------------------------------------------
  final SegmentCache cache;
  final http.Client _httpClient = http.Client();

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  HttpServer? _server;
  int _port = 0;

  /// Track in-flight downloads → prevents redundant fetches.
  final Map<String, Completer<Uint8List>> _inFlightDownloads = {};

  ProxyServer({required this.cache});

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
    _httpClient.close();
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

    // 1. Serve from cache
    final cached = await cache.get(cacheKey);
    if (cached != null) {
      LoggerService.i('[ProxyServer] 📦 Serving MANIFEST from OFFLINE CACHE: $url');
      _writeManifestResponse(request, cached);
      return;
    }

    // 2. Download original manifest
    final data = await _downloadWithTimeout(url);
    if (data == null) {
      LoggerService.w('[ProxyServer] Failed to fetch manifest: $url. Redirecting to upstream.');
      // FALLBACK: Redirect to original URL so player can try directly
      request.response.redirect(Uri.parse(url), status: HttpStatus.movedTemporarily);
      return;
    }

    final content = utf8.decode(data, allowMalformed: true);

    // 3. Parse & rewrite
    ManifestResult result;
    if (ManifestParser.isMasterPlaylist(content)) {
      result = ManifestParser.parseMasterPlaylist(content, url, baseUrl);
    } else {
      result = ManifestParser.parseMediaPlaylist(content, url, baseUrl);
    }

    final rewritten = Uint8List.fromList(utf8.encode(result.rewrittenContent));

    // 4. Cache rewritten manifest
    await cache.put(cacheKey, rewritten);

    // 5. Respond
    _writeManifestResponse(request, rewritten);
  }

  void _writeManifestResponse(HttpRequest request, Uint8List data) {
    request.response.headers
        .set('Content-Type', 'application/vnd.apple.mpegurl');
    request.response.headers.contentLength = data.length;
    request.response.add(data);
    request.response.close();
  }

  // ---------------------------------------------------------------------------
  // Segment handler (with Range support for ExoPlayer)
  // ---------------------------------------------------------------------------

  Future<void> _handleSegment(HttpRequest request, String url) async {
    final data = await getOrDownloadSegment(url);
    if (data == null) {
      LoggerService.w('[ProxyServer] Failed to fetch segment: $url. Redirecting to upstream.');
      // FALLBACK: Redirect to original URL
      request.response.redirect(Uri.parse(url), status: HttpStatus.movedTemporarily);
      return;
    }

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
        request.response.add(data.sublist(start, clampedEnd + 1));
        await request.response.close();
        return;
      }
    }

    // Full response
    request.response.headers.contentLength = data.length;
    request.response.add(data);
    await request.response.close();
  }

  String _segmentContentType(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('.m4s') || lower.contains('.mp4') || lower.contains('.m4v') || lower.contains('.m4a')) {
      return 'video/mp4';
    }
    if (lower.contains('.aac')) return 'audio/aac';
    return 'video/MP2T'; // .ts default
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
        completer.completeError(Exception('Download failed for $url'));
      }
      return null;
    } catch (e) {
      if (!completer.isCompleted) completer.completeError(e);
      return null;
    } finally {
      _inFlightDownloads.remove(url);
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

    // Already cached? Re-parse from original to extract segment URLs.
    final cached = await cache.get(cacheKey);
    if (cached != null) {
      // We already have the rewritten manifest; try to get the segment list
      // from the original.
      final originalKey = 'original:$url';
      final originalData = await cache.get(originalKey);
      if (originalData != null) {
        final content = utf8.decode(originalData, allowMalformed: true);
        if (!ManifestParser.isMasterPlaylist(content)) {
          final result =
              ManifestParser.parseMediaPlaylist(content, url, baseUrl);
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

    ManifestResult result;
    if (ManifestParser.isMasterPlaylist(content)) {
      result = ManifestParser.parseMasterPlaylist(content, url, baseUrl);
      final rewritten =
          Uint8List.fromList(utf8.encode(result.rewrittenContent));
      await cache.put(cacheKey, rewritten);

      // Pick first (lowest-bandwidth) variant for pre-loading
      if (result.variantUrls.isNotEmpty) {
        return downloadAndCacheManifest(result.variantUrls.first);
      }
      return const [];
    } else {
      result = ManifestParser.parseMediaPlaylist(content, url, baseUrl);
      final rewritten =
          Uint8List.fromList(utf8.encode(result.rewrittenContent));
      await cache.put(cacheKey, rewritten);
      return result.segmentUrls;
    }
  }

  // ---------------------------------------------------------------------------
  // HTTP helper
  // ---------------------------------------------------------------------------

  Future<Uint8List?> _downloadWithTimeout(
    String url, {
    Duration timeout = const Duration(seconds: 15),
    int retries = 3,
  }) async {
    int attempt = 0;
    while (attempt < retries) {
      if (attempt > 0) {
        // Exponential backoff: 500ms, 1000ms, 2000ms
        final backoff = Duration(milliseconds: 500 * (1 << (attempt - 1)));
        LoggerService.w('[ProxyServer] Retrying ($attempt/$retries) for $url after ${backoff.inMilliseconds}ms');
        await Future.delayed(backoff);
      }
      attempt++;

      final start = DateTime.now();
      try {
        LoggerService.d('[ProxyServer] Download Attempt $attempt: $url');
        final response = await _httpClient.get(
          Uri.parse(url),
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
          },
        ).timeout(timeout);

        final elapsed = DateTime.now().difference(start).inMilliseconds;

        if (response.statusCode >= 200 && response.statusCode < 300) {
          LoggerService.d('[ProxyServer] Downloaded ${response.bodyBytes.length} bytes in ${elapsed}ms: $url');
          return response.bodyBytes;
        }

        // 503 Service Unavailable -> Retryable
        if (response.statusCode == 503 || response.statusCode == 429) {
          LoggerService.w('[ProxyServer] HTTP ${response.statusCode} (Retryable) for $url');
          continue; // Trigger retry
        }

        LoggerService.e('[ProxyServer] HTTP ${response.statusCode} in ${elapsed}ms for $url');
        // Non-retryable error (404, 403, 500 etc)
        // For now, we return null, which triggers the Redirect fallback
        return null; 

      } on TimeoutException {
        LoggerService.e('[ProxyServer] Timeout downloading $url');
        // Retry on timeout? Maybe.
        continue;
      } on SocketException catch (e) {
        LoggerService.w('[ProxyServer] 🚫 OFFLINE / Network unreachable for $url. Error: $e');
        return null; // Don't retry if offline
      } on HandshakeException catch (e) {
        LoggerService.e('[ProxyServer] 🔒 SSL Handshake failed for $url. Error: $e');
        return null;
      } catch (e) {
        LoggerService.e('[ProxyServer] Download error for $url: $e');
        return null;
      }
    }
    return null; // All retries failed
  }
}
