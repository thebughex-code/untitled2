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
  int _concurrencyLimit = 2; // Default for Mobile
  
  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  final List<_PreloadRequest> _queue = [];
  final Set<String> _processing = {};
  final Set<String> _completed = {};

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Updates concurrency limit based on network type.
  /// Call this when connectivity changes.
  void updateNetworkStatus(String status) {
    // Simplified logic. Real app would use `connectivity_plus` enum.
    if (status == 'wifi') {
      _concurrencyLimit = 3;
    } else if (status == 'mobile') {
      _concurrencyLimit = 2;
    } else {
      _concurrencyLimit = 1; // Poor / Other
    }
    _processQueue();
  }

  /// Requests preloading for a video with a specific priority.
  void preload(String url, PreloadPriority priority) {
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

  /// Process page changes with debounce and queue clearing.
  void onPageChanged(int currentIndex, List<String> allUrls) {
      if (allUrls.isEmpty) return;

      // 1. CLEAR previous queue to stop stale requests (LIGHTWEIGHT optimization)
      _queue.clear();
      
      // 2. Critical: Immediate Next
      if (currentIndex + 1 < allUrls.length) {
          preload(allUrls[currentIndex + 1], PreloadPriority.critical);
      }

      // 3. High: Next 2-3
      for (int i = 2; i <= 3; i++) {
           if (currentIndex + i < allUrls.length) {
              preload(allUrls[currentIndex + i], PreloadPriority.high);
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
    if (_processing.length >= _concurrencyLimit) return;
    if (_queue.isEmpty) return;

    final request = _queue.removeAt(0);
    final url = request.url;

    _processing.add(url);

    try {
      final startTime = DateTime.now();
      LoggerService.d('[PreloadManager] Starting prefetch ($request.priority) $url');
      
      // 1. Cache Manifest
      final segments = await _proxyServer!.downloadAndCacheManifest(url);
      
      if (segments.isEmpty) {
        LoggerService.w('[PreloadManager] No segments found for $url');
        return;
      }
      
      // 2. Cache first few segments (e.g. 1)
      // Limit to 1 segment for lightweight behavior
      final count = segments.take(1).length;
      int downloaded = 0;
      for (int i=0; i < count; i++) {
          final res = await _proxyServer!.getOrDownloadSegment(segments[i]);
          if (res != null) downloaded++;
      }
      
      _completed.add(url);
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      LoggerService.i('[PreloadManager] Completed $url. Cached $downloaded/$count segments in ${elapsed}ms');
    } catch (e) {
      LoggerService.e('[PreloadManager] Failed $url: $e');
    } finally {
      _processing.remove(url);
      // Process next
      _processQueue();
    }
  }
}
