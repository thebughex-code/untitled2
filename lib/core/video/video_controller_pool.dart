import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import '../../core/hls/hls_cache_manager.dart';
import '../services/logger_service.dart';
import '../../main.dart'; // To access the global proxy

/// Manages a pool of VideoPlayerControllers to optimize resources and memory.
///
/// Ensures we never have more than [maxSize] concurrent native video decoders
/// active, which prevents Android `pipelineFull` crashes on heavy-scroll apps.
/// - **State Preservation**: Saves playback position when a controller is evicted,
///   so it can be restored if the user scrolls back.
class VideoControllerPool {
  static final VideoControllerPool instance = VideoControllerPool._();
  VideoControllerPool._();

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------
  
  /// Maximum number of controllers to keep in memory.
  /// 3 = current + 1 forward + 1 backward.
  /// This prevents the "loader on back-scroll" bug while staying within
  /// Android decoder limits (3 simultaneous decoders is safe on all devices ≥2020).
  /// Maximum number of controllers to keep in memory.
  /// 3 = current + 1 forward + 1 backward.
  /// This prevents decoder limits (pipelineFull) while keeping minimum smooth scrolling.
  int maxSize = 3;

  /// Global volume state. 0.0 means muted, 1.0 means full volume.
  /// Videos should listen to this notifier to sync mute state instantly.
  final ValueNotifier<double> globalVolume = ValueNotifier<double>(1.0);

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

  /// The previously active video URL – protected to enable instant back-scroll.
  String? _prevUrl;

  /// The next video URL – protected so the pre-warmed controller isn't evicted
  /// before the user swipes to it.
  String? _nextUrl;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Sets the currently active video. This video will NOT be evicted.
  /// The previous URL is kept for one transition to enable instant back-scroll.
  void setCurrentUrl(String url) {
    if (_currentUrl != url) {
      _prevUrl = _currentUrl; // protect the video we just came from
    }
    _currentUrl = url;
  }

  /// Sets the upcoming (next) video URL so it is protected from LRU eviction
  /// while the pre-warmed controller waits for the swipe.
  void setNextUrl(String? url) {
    _nextUrl = url;
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
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true, allowBackgroundPlayback: true),
      );
      
      await controller.initialize();
      controller.setLooping(true);
      controller.setVolume(globalVolume.value);
      _restorePosition(url, controller);
      return controller;
    } catch (e) {
      LoggerService.w('[VideoPool] Proxy init failed for $url: $e. Falling back to NETWORK.');
      
      // 2. Fallback to Network URL (Direct)
      try {
        final controller = VideoPlayerController.networkUrl(
          Uri.parse(url), // Original URL
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true, allowBackgroundPlayback: true),
        );
        await controller.initialize();
        controller.setLooping(true);
        controller.setVolume(globalVolume.value);
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

  // ---------------------------------------------------------------------------
  // Lifecycle helpers (called by VideoFeedScreen's WidgetsBindingObserver)
  // ---------------------------------------------------------------------------

  /// Save positions of ALL live controllers.
  /// Called when the app is about to be backgrounded so that if the OS
  /// kills a controller, we can restore from the saved position on resume.
  void saveAllPositions() {
    for (final entry in _controllers.entries) {
      _savePosition(entry.key, entry.value);
    }
    LoggerService.d(
      '[VideoPool] 💾 Saved positions for ${_controllers.length} controller(s)',
    );
  }

  /// Pause the currently active controller (called on app background).
  void pauseCurrentVideo() {
    final url = _currentUrl;
    if (url == null) return;
    final ctrl = _controllers[url];
    if (ctrl != null && ctrl.value.isInitialized) {
      ctrl.pause();
      LoggerService.d('[VideoPool] ⏸ Paused controller for $url');
    }
  }

  /// Resume the currently active controller (called on app foreground).
  /// Only calls play() — never re-creates the controller.
  void resumeCurrentVideo() {
    final url = _currentUrl;
    if (url == null) return;
    final ctrl = _controllers[url];
    if (ctrl != null && ctrl.value.isInitialized) {
      ctrl.play();
      LoggerService.i('[VideoPool] ▶️ Resuming controller for $url');
    } else {
      LoggerService.w('[VideoPool] ⚠️ Resume requested but no live controller for $url');
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
      // Evict LRU, but protect _currentUrl and _prevUrl.
      String? evictKey;
      for (final key in _controllers.keys) {
        if (key != _currentUrl && key != _prevUrl && key != _nextUrl) {
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
        // All remaining controllers are protected — can't evict.
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
