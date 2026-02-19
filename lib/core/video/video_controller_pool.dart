import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../../core/hls/hls_cache_manager.dart';
import '../services/logger_service.dart';

/// Manages a pool of [VideoPlayerController]s to limit memory usage and
/// provide instant playback for recent videos.
///
/// - **LRU Eviction**: Keeps a maximum of [maxSize] controllers.
/// - **State Preservation**: Saves playback position when a controller is evicted,
///   so it can be restored if the user scrolls back.
class VideoControllerPool {
  static final VideoControllerPool instance = VideoControllerPool._();
  VideoControllerPool._();

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------
  
  /// Maximum number of controllers to keep in memory.
  /// Reduced to 2 to strictly limit heavy hardware decoder usage on Android.
  /// This prevents "tucking"/freezing when scrolling.
  int maxSize = 2;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// LRU Cache: Keys are video URLs.
  /// Using LinkedHashMap to maintain insertion order (LRU).
  final LinkedHashMap<String, VideoPlayerController> _controllers =
      LinkedHashMap();

  /// Saved playback positions for evicted videos.
  final Map<String, Duration> _savedPositions = {};

  /// The currently active video URL (to prevent evicting the playing video).
  String? _currentUrl;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Sets the currently active video. This video will NOT be evicted.
  void setCurrentUrl(String url) {
    _currentUrl = url;
  }

  /// Returns an existing controller for [url] or creates a new one.
  ///
  /// If created, it tries to restore the last known position.
  /// Tracks in-flight controller creations to prevent race conditions.
  final Map<String, Future<VideoPlayerController>> _pendingCreations = {};

  /// Returns an existing controller for [url] or creates a new one.
  ///
  /// If created, it tries to restore the last known position.
  Future<VideoPlayerController> getControllerFor(String url) async {
    // 1. Check if we already have it
    if (_controllers.containsKey(url)) {
      // Move to end (most recently used)
      final controller = _controllers.remove(url)!;
      _controllers[url] = controller;
      return controller;
    }

    // 2. Check if it's already being created (Deduplication)
    if (_pendingCreations.containsKey(url)) {
      return _pendingCreations[url]!;
    }

    // 3. Create new controller (wrapped in a future to allow deduplication)
    final future = _createController(url);
    _pendingCreations[url] = future;

    try {
      final controller = await future;
      
      // 4. Add to pool (and evict if necessary)
      _controllers[url] = controller;
      _enforceMaxSize();
      
      return controller;
    } catch (e) {
      rethrow;
    } finally {
      // 5. Clean up pending map
      _pendingCreations.remove(url);
    }
  }

  /// Synchronous check: returns controller if already in pool and ready.
  /// Used to avoid async gap (1-frame loader) in the UI.
  VideoPlayerController? getControllerNow(String url) {
    if (_controllers.containsKey(url)) {
      // Move to MRU
      final controller = _controllers.remove(url)!;
      _controllers[url] = controller;
      return controller;
    }
    return null;
  }

  Future<VideoPlayerController> _createController(String url) async {
    // 1. Try Proxy URL (Caching)
    try {
      final proxyUrl = HlsCacheManager.instance.getProxiedUrl(url);
      LoggerService.d('[VideoPool] 🟢 Initializing via Proxy: $proxyUrl');

      final controller = VideoPlayerController.networkUrl(
        Uri.parse(proxyUrl),
        httpHeaders: const {'Connection': 'keep-alive'},
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true, allowBackgroundPlayback: false),
      );
      
      await controller.initialize();
      controller.setLooping(true);
      _restorePosition(url, controller);
      return controller;
    } catch (e) {
      LoggerService.w('[VideoPool] Proxy init failed for $url: $e. Falling back to NETWORK.');
      
      // 2. Fallback to Network URL (Direct)
      try {
        final controller = VideoPlayerController.networkUrl(
          Uri.parse(url), // Original URL
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true, allowBackgroundPlayback: false),
        );
        await controller.initialize();
        controller.setLooping(true);
        _restorePosition(url, controller);
        return controller;
      } catch (e2) {
         throw Exception('Failed to init controller (both proxy and network) for $url: $e2');
      }
    }
  }

  void _restorePosition(String url, VideoPlayerController controller) {
      final savedPos = _savedPositions[url];
      if (savedPos != null) {
         controller.seekTo(savedPos);
      }
  }

  /// Stop and dispose a specific controller (e.g., on error).
  void removeController(String url) {
    final controller = _controllers.remove(url);
    if (controller != null) {
      _savePosition(url, controller);
      controller.dispose();
    }
  }

  /// Clears all controllers (e.g., on low memory).
  void clear() {
    for (var url in _controllers.keys) {
      final controller = _controllers[url];
      if (controller != null) {
        _savePosition(url, controller);
        controller.dispose();
      }
    }
    _controllers.clear();
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _enforceMaxSize() {
    while (_controllers.length > maxSize) {
      // Evict the least recently used (first key),
      // BUT skip the current URL if it happens to be the LRU (unlikely with map logic, but safe).
      String? evictKey;
      for (var key in _controllers.keys) {
        if (key != _currentUrl) {
          evictKey = key;
          break;
        }
      }

      if (evictKey != null) {
        final controller = _controllers.remove(evictKey);
        if (controller != null) {
          _savePosition(evictKey, controller);
          controller.dispose();
          LoggerService.d('[VideoPool] Evicted $evictKey. Pool size: ${_controllers.length}');
        }
      } else {
        // If we only have the current URL (and size > max?), break.
        // Should not happen if maxSize >= 1.
        break;
      }
    }
  }

  void _savePosition(String url, VideoPlayerController controller) {
    final pos = controller.value.position;
    if (pos > Duration.zero) {
      _savedPositions[url] = pos;
    }
  }
}
