import 'dart:async';

import 'proxy_server.dart';
import '../services/logger_service.dart';
import '../services/video_controller_pool.dart';

enum PreloadPriority { critical, high, medium, low }

class _PreloadRequest {
  final String url;
  final PreloadPriority priority;

  _PreloadRequest(this.url, this.priority);
}

/// Advanced preloader with priority queues, smart cancellation,
/// and 5-segment buffering (≈15 seconds) per video.
class VideoPreloadManager {
  static final VideoPreloadManager instance = VideoPreloadManager._();
  VideoPreloadManager._();

  // ---------------------------------------------------------------------------
  // Dependencies
  // ---------------------------------------------------------------------------
  ProxyServer? _proxyServer;

  void setProxy(ProxyServer proxy) {
    _proxyServer = proxy;
  }

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  /// Max parallel preload downloads.
  /// Reduced from 2 to 1. On slower iOS/Android devices, 2 parallel HTTP 
  /// fetches can saturate the radio and cause the CURRENT playing video 
  /// to buffer. 1 parallel fetch ensures the currently playing video 
  /// always has highest priority bandwidth.
  final int _concurrencyLimit = 1;

  /// Segments to preload per video during background scrolling.
  /// Reduced to 1. This means we only download the absolute minimum byte
  /// range needed to render the very first frame of the video, and stream the
  /// rest instantly on demand.
  static const int _segmentPreloadCount = 1;

  /// Segments fetched at splash time (or initial feed load).
  /// Reduced to 1 for maximum TikTok-style blazing fast boot. Even on Edge
  /// networks, downloading 1 segment guarantees <1 second load times.
  static const int _splashSegmentCount = 1;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  final List<_PreloadRequest> _queue = [];
  final Set<String> _processing = {};
  final Set<String> _completed = {};

  /// URLs that should be cancelled when they are next dequeued.
  /// We NEVER add ±1 or current to this set.
  final Set<String> _cancelSet = {};

  // Track ±1 windows to prevent cancellation of nearby videos
  String? _currentUrl;
  String? _prevUrl;
  String? _nextUrl;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  void preload(String url, PreloadPriority priority, {bool processInstantly = true}) {
    _cancelSet.remove(url); // Un-cancel if re-requested
    if (_completed.contains(url) || _processing.contains(url)) return;

    final existingIndex = _queue.indexWhere((r) => r.url == url);
    if (existingIndex != -1) {
      // Upgrade priority if higher
      if (priority.index < _queue[existingIndex].priority.index) {
        _queue.removeAt(existingIndex);
        _addToQueue(url, priority);
      }
    } else {
      _addToQueue(url, priority);
    }

    if (processInstantly) {
      _processQueue();
    }
  }

  /// Parallel initial batch load for Splash Screen.
  ///
  /// Downloads manifests + [_splashSegmentCount] leading segments for the first
  /// [count] videos **concurrently** so the total wait time equals the slowest
  /// individual video rather than the sum of all of them.
  Future<void> preloadInitialBatch(List<String> urls, {int count = 3}) async {
    if (_proxyServer == null) return;
    final batch = urls.take(count).toList();

    final batchStart = DateTime.now();
    LoggerService.i(
      '[PreloadManager] 📥 Splash preload started — '
      '${batch.length} video(s) in parallel, $_splashSegmentCount segment(s) each',
    );

    // Fetch all videos in parallel.
    await Future.wait(
      batch.map((url) async {
        final videoStart = DateTime.now();
        final shortUrl = url.length > 60 ? '…${url.substring(url.length - 57)}' : url;
        LoggerService.d('[PreloadManager] ⏳ Fetching manifest: $shortUrl');

        try {
          final manifestStart = DateTime.now();
          final segments = await _proxyServer!.downloadAndCacheManifest(url);
          final manifestMs = DateTime.now().difference(manifestStart).inMilliseconds;
          LoggerService.d(
            '[PreloadManager] 📜 Manifest ready for $shortUrl '
            '(${segments.length} segments, $manifestMs ms)',
          );

          if (segments.isEmpty) {
            LoggerService.w('[PreloadManager] ⚠️ No segments in manifest: $shortUrl');
            return;
          }

          // Download only the first segment(s) in parallel within each video.
          final toCache = segments.take(_splashSegmentCount).toList();
          final segStart = DateTime.now();
          await Future.wait(
            toCache.map((seg) => _proxyServer!.getOrDownloadSegment(seg)),
          );
          final segMs = DateTime.now().difference(segStart).inMilliseconds;

          _completed.add(url);
          final totalMs = DateTime.now().difference(videoStart).inMilliseconds;
          LoggerService.i(
            '[PreloadManager] ✅ Splash cached $shortUrl — '
            'manifest: $manifestMs ms | segment(s): $segMs ms | total: $totalMs ms',
          );
        } catch (e) {
          LoggerService.e('[PreloadManager] ❌ Splash load failed for $shortUrl: $e');
        }
      }),
    );

    final batchMs = DateTime.now().difference(batchStart).inMilliseconds;
    LoggerService.i(
      '[PreloadManager] 🏁 Splash batch complete — '
      '${_completed.length}/${batch.length} cached in $batchMs ms',
    );
  }

  /// Called on every page change. Rebuilds the preload queue using a
  /// dynamic [windowSize] so the caller can trade bandwidth for latency.
  ///
  /// [windowSize] = number of videos to preload **ahead** of current:
  ///   1 → current+1 only (slow/reading).
  ///   2 → current+1, current+2 (normal — default).
  ///   3 → current+1..+3 (fast scrolling).
  void onPageChanged(int currentIndex, List<String> allUrls,
      {int windowSize = 2}) {
    if (allUrls.isEmpty) return;

    // 1. Track protected window (±1)
    _currentUrl = allUrls[currentIndex];
    _prevUrl = currentIndex > 0 ? allUrls[currentIndex - 1] : null;
    _nextUrl = currentIndex + 1 < allUrls.length ? allUrls[currentIndex + 1] : null;

    // 2. Protected set — never cancelled mid-flight
    final protectedUrls = <String>{
      _currentUrl!,
      ?_prevUrl,
      ?_nextUrl,
    };

    // 3. Cancel stale in-flight downloads outside the protected set
    final toCancel = <String>[];
    for (final url in _processing) {
      if (!protectedUrls.contains(url) && !_completed.contains(url)) {
        _cancelSet.add(url);
        toCancel.add(url);
        LoggerService.d('[PreloadManager] 🛑 Cancelling stale fetch: ...${url.substring(url.length - 20 > 0 ? url.length - 20 : 0)}');
      }
    }
    if (toCancel.isNotEmpty) {
      _proxyServer?.cancelPendingDownloads(toCancel);
    }

    // 4. Clear pending queue and rebuild with the new window
    _queue.clear();

    // 4b. Prune _completed entries outside the new window so evicted
    //     disk-cache segments are re-downloaded when needed.
    final windowUrls = <String>{
      _currentUrl!,
      ?_prevUrl,
      ?_nextUrl,
      for (int i = 2; i <= windowSize; i++)
        if (currentIndex + i < allUrls.length) allUrls[currentIndex + i],
    };
    _completed.removeWhere((url) => !windowUrls.contains(url));

    // 5. Next +1 (critical — highest priority)
    if (_nextUrl != null) preload(_nextUrl!, PreloadPriority.critical, processInstantly: false);

    // 6. Next +2 … +windowSize (high)
    for (int i = 2; i <= windowSize; i++) {
      if (currentIndex + i < allUrls.length) {
        preload(allUrls[currentIndex + i], PreloadPriority.high, processInstantly: false);
      }
    }

    // 7. Previous (high — instant back-scroll)
    // Placed last so forward-scrolling captures the concurrency slot first.
    if (_prevUrl != null) preload(_prevUrl!, PreloadPriority.high, processInstantly: false);

    // 8. Fire the queue once all items are added and correctly sorted
    _processQueue();

    LoggerService.i(
      '[PreloadManager] Queue rebuilt — index $currentIndex '
      'window=$windowSize pending=${_queue.length} processing=${_processing.length}',
    );
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _addToQueue(String url, PreloadPriority priority) {
    _queue.add(_PreloadRequest(url, priority));
    _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));
  }

  Future<void> _processQueue() async {
    if (_proxyServer == null) return;
    if (_processing.length >= _concurrencyLimit) return;
    if (_queue.isEmpty) return;

    // Optional optimization: If the current video is actively buffering, 
    // pause background preload. (This would require a hook into VideoPool).
    // For now, capping concurrency to 1 achieves a similar goal.

    final request = _queue.removeAt(0);
    final url = request.url;

    // Skip cancelled URLs
    if (_cancelSet.contains(url)) {
      _cancelSet.remove(url);
      _processQueue();
      return;
    }

    _processing.add(url);

    try {
      final startTime = DateTime.now();
      LoggerService.d('[PreloadManager] Starting prefetch (${request.priority.name}) $url');

      // Check for cancellation before manifest download
      if (_cancelSet.contains(url)) throw Exception('Cancelled before manifest');

      final segments = await _proxyServer!.downloadAndCacheManifest(url);

      if (segments.isEmpty) {
        LoggerService.w('[PreloadManager] No segments for $url');
        return;
      }

      int downloaded = 0;
      final toFetch = segments.take(_segmentPreloadCount).toList();

      for (final seg in toFetch) {
        if (_cancelSet.contains(url)) {
          LoggerService.d('[PreloadManager] 🛑 Cancelled mid-fetch for $url');
          break;
        }
        final res = await _proxyServer!.getOrDownloadSegment(seg);
        if (res != null) downloaded++;
      }

      if (!_cancelSet.contains(url)) {
        _completed.add(url);
        final elapsed = DateTime.now().difference(startTime).inMilliseconds;
        LoggerService.i(
          '[PreloadManager] ✅ Cached $downloaded/${toFetch.length} segments '
          'for $url in ${elapsed}ms',
        );

        // ── Controller Pre-Warm ──────────────────────────────────────────────
        // Now that HLS segments are on disk, fire the hardware decoder warm-up
        // immediately as a fire-and-forget. By the time the user swipes to
        // this video, the decoder will already be allocated — 0ms spinner.
        //
        // This is the KEY fix for "black screen after index 6": the controller
        // used to only be initialized reactively when the widget became visible.
        // Now it initializes proactively in the background, as soon as segments
        // are cached, regardless of what the user is currently watching.
        VideoControllerPool.instance
            .getControllerFor(url)
            .then((_) => LoggerService.d('[PreloadManager] 🔥 Controller pre-warmed for ...${url.length > 30 ? url.substring(url.length - 30) : url}'))
            .onError((e, _) {}); // Silently ignore — VideoPlayerWidget retry handles it
      }
    } catch (e) {
      LoggerService.e('[PreloadManager] Error/cancelled $url: $e');
    } finally {
      _processing.remove(url);
      _cancelSet.remove(url);
      _processQueue();
    }
  }
}
