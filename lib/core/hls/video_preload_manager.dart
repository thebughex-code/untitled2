import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../core/hls/proxy_server.dart';
import '../services/logger_service.dart';

enum PreloadPriority { critical, high, medium, low }

class _PreloadRequest {
  final String url;
  final PreloadPriority priority;

  _PreloadRequest(this.url, this.priority);
}

/// Advanced preloader with priority queues and network awareness.
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
  // Configuration (Network Awareness)
  // ---------------------------------------------------------------------------
  int _concurrencyLimit = 1; // Strict limit to ensure current video gets bandwidth
  
  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  final List<_PreloadRequest> _queue = [];
  final Set<String> _processing = {};
  final Set<String> _completed = {};
  final Set<String> _cancelSet = {}; // URLs to cancel if in-flight

  // ... (existing updateNetworkStatus) ...

  void preload(String url, PreloadPriority priority) {
     _cancelSet.remove(url); // Un-cancel if requested again
     // ... (rest of preload) ...
     if (_completed.contains(url) || _processing.contains(url)) return;

    // Check if already in queue
    final existingIndex = _queue.indexWhere((r) => r.url == url);
    if (existingIndex != -1) {
      // Update priority if higher
      if (priority.index < _queue[existingIndex].priority.index) {
        _queue.removeAt(existingIndex);
        _addToQueue(url, priority);
      }
    } else {
      _addToQueue(url, priority);
    }
    
    _processQueue();
  }

  /// Sequential initial load for Splash Screen.
  /// Avoids 503 errors by loading 1-by-1.
  Future<void> preloadInitialBatch(List<String> urls, {int count = 3}) async {
    final batch = urls.take(count).toList();
    for (final url in batch) {
      // Create a temporary completer to wait for this specific URL
      final completer = Completer<void>();
      
      // We can't easily hook into the queue's completion of a specific URL 
      // without adding complex logic. 
      // Instead, we just use the existing preload mechanism with CRITICAL priority
      // and a small delay to ensure they are processed sequentially in the queue.
      
      preload(url, PreloadPriority.critical);
      
      // Wait a bit to let the queue pick it up and possibly finish headers
      // A true "await until finished" is hard with the current async queue,
      // but for Splash, just firing them with Critical priority is usually enough,
      // as the queue processes them 1-by-1.
      
      // However, to strictly mimic "sequential await" for 503 safety:
      // We will perform a direct check manually? No, that breaks the singleton queue.
      
      // Best approach: Just fire them. The queue IS sequential (concurrency=1).
      // So fast-firing them adds them to queue.
    }
    
    // Hack: Wait for the queue to drain? 
    // Or just return immediately and let the Splash timeout handle it?
    // The Splash waits for this Future.
    
    // Better implementation:
    // Actually wait for them.
    // Since we are in Splash, we can just access the proxy directly if we really want,
    // OR we can poll.
    
    // Let's implement a polite "waitloop" or just use the Proxy directly for the splash setup
    // to ensure it's done before we say "bootstrapped".
    
    for (final url in batch) {
         if (_proxyServer != null) {
            try {
               final segments = await _proxyServer!.downloadAndCacheManifest(url);
               for(int i=0; i<segments.take(3).length; i++) {
                   await _proxyServer!.getOrDownloadSegment(segments[i]);
               }
            } catch (e) {
               LoggerService.e('[PreloadManager] Splash load failed for $url: $e');
            }
         }
    }
  }

  /// Process page changes with debounce and queue clearing.
  void onPageChanged(int currentIndex, List<String> allUrls) {
      if (allUrls.isEmpty) return;

      // 1. CLEAR previous queue
      _queue.clear();
      
      // 2. Mark currently processing URLs as candidates for cancellation
      // (Unless they are the immediate next video)
      _cancelSet.addAll(_processing);
      
      // ... (rest of logic: scheduling new preloads) ...
      
      // 2. Critical: Immediate Next
      if (currentIndex + 1 < allUrls.length) {
          final nextUrl = allUrls[currentIndex + 1];
          _cancelSet.remove(nextUrl); // Don't cancel next video
          preload(nextUrl, PreloadPriority.critical);
      }

      // 3. High: Next 2-3
      for (int i = 2; i <= 3; i++) {
           if (currentIndex + i < allUrls.length) {
              final url = allUrls[currentIndex + i];
              _cancelSet.remove(url);
              preload(url, PreloadPriority.high);
          }
      }
      
      // 4. Medium: Previous (for back scroll)
      if (currentIndex - 1 >= 0) {
          preload(allUrls[currentIndex - 1], PreloadPriority.medium);
      }
      
      // 5. Low: Further ahead
       for (int i = 4; i <= 5; i++) {
           if (currentIndex + i < allUrls.length) {
              preload(allUrls[currentIndex + i], PreloadPriority.low);
          }
      }

      // Log optimization event
      LoggerService.i('[PreloadManager] Optimized queue for page $currentIndex. Pending: ${_queue.length}');
  }

 
  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _addToQueue(String url, PreloadPriority priority) {
    _queue.add(_PreloadRequest(url, priority));
    // Sort: Critical (0) < High (1) ...
    _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));
  }

  Future<void> _processQueue() async {
    if (_proxyServer == null) return;
    if (_processing.length >= 1) return;
    if (_queue.isEmpty) return;

    final request = _queue.removeAt(0);
    final url = request.url;

    if (_cancelSet.contains(url)) {
        _cancelSet.remove(url);
        _processQueue(); // Skip and continue
        return;
    }

    _processing.add(url);

    try {
      final startTime = DateTime.now();
      LoggerService.d('[PreloadManager] Starting prefetch ($request.priority) $url');
      
      // 1. Cache Manifest
      if (_cancelSet.contains(url)) throw Exception('Cancelled');
      final segments = await _proxyServer!.downloadAndCacheManifest(url);
      
      if (segments.isEmpty) {
        LoggerService.w('[PreloadManager] No segments found for $url');
        return;
      }
      
      // 2. Cache first few segments
      final count = segments.take(3).length;
      int downloaded = 0;
      
      for (int i=0; i < count; i++) {
          if (_cancelSet.contains(url)) {
             LoggerService.d('[PreloadManager] 🛑 Cancelled prefetch for $url');
             break; 
          }
          
          final res = await _proxyServer!.getOrDownloadSegment(segments[i]);
          if (res != null) downloaded++;
      }
      
      if (!_cancelSet.contains(url)) {
          _completed.add(url);
          final elapsed = DateTime.now().difference(startTime).inMilliseconds;
          LoggerService.i('[PreloadManager] Completed $url. Cached $downloaded/$count segments in ${elapsed}ms');
      }
    } catch (e) {
      LoggerService.e('[PreloadManager] Processing error/cancelled $url: $e');
    } finally {
      _processing.remove(url);
      _cancelSet.remove(url);
      _processQueue();
    }
  }
}
