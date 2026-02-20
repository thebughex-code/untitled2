import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'hls_cache_manager.dart';
import 'logger_service.dart';

// ---------------------------------------------------------------------------
// Concurrency semaphore
// ---------------------------------------------------------------------------
/// Limits concurrent async operations to [maxCount].
/// Queues excess callers as Dart Futures — they resume when a slot opens.
class _Semaphore {
  final int maxCount;
  int _occupied = 0;
  final List<Completer<void>> _waiters = [];

  _Semaphore(this.maxCount);

  Future<void> acquire() {
    if (_occupied < maxCount) {
      _occupied++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(); // hand slot to next waiter
    } else {
      _occupied--;
    }
  }
}

/// TikTok-grade video controller pool with a two-tier architecture:
///
/// ──────────────────────────────────────────────────────────────────────────
/// Tier 1 — Active Pool  (maxSize = 5)
///   Fully initialized, currently playing or paused. Hold GPU texture slots.
///   High CPU/memory cost. LRU-evicted → move to Suspend Pool.
///
/// Tier 2 — Suspend Pool  (maxSuspendedSize = 5)
///   Paused, volume=0, invisible — but hardware decoders STILL ALLOCATED.
///   Resume cost = 0ms (just .play()). No spinner, no init delay.
///   LRU-evicted → actually disposed (hardware decoder released).
/// ──────────────────────────────────────────────────────────────────────────
///
/// Result: scrolling back to any of the last 10 visited videos is instant.
/// The "loader on every back-scroll" bug is eliminated.
class VideoControllerPool {
  static final VideoControllerPool instance = VideoControllerPool._();
  VideoControllerPool._();

  // ---------------------------------------------------------------------------
  // Configuration
  // ---------------------------------------------------------------------------

  /// Active pool size: current + 3 forward + 2 backward + 1 safety.
  /// Must stay ≥ HomeController's max windowSize + pre-warm depth (4+1=5).
  int maxSize = 7;

  /// Suspend pool: warm but silent decoders for instant back-scroll.
  /// 10 entries = covers 17-video scroll history (7 active + 10 suspended).
  /// Scrolling backward through up to 17 videos is always instant.
  int maxSuspendedSize = 10;

  /// Global volume state. Videos listen to this to sync mute state instantly.
  final ValueNotifier<double> globalVolume = ValueNotifier<double>(1.0);

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Tier 1 — Active pool (LRU LinkedHashMap).
  final LinkedHashMap<String, VideoPlayerController> _controllers =
      LinkedHashMap();

  /// Tier 2 — Suspend pool (LRU LinkedHashMap).
  ///
  /// Controllers here are paused with volume=0. They hold their GPU texture
  /// and hardware decoder allocations, making resume instant.
  final LinkedHashMap<String, VideoPlayerController> _suspended =
      LinkedHashMap();

  /// Saved playback positions (LRU, capped at 50).
  final LinkedHashMap<String, Duration> _savedPositions =
      LinkedHashMap<String, Duration>();
  static const int _maxSavedPositions = 50;

  /// De-duplication map for in-flight controller creations.
  final Map<String, Future<VideoPlayerController>> _pendingCreations = {};

  String? _currentUrl;
  String? _prevUrl;
  String? _nextUrl;

  // ---------------------------------------------------------------------------
  // Fast-scroll protection
  // ---------------------------------------------------------------------------

  /// Limits concurrent `controller.initialize()` calls.
  ///
  /// On fast scroll, HomeController fires many pre-warm calls in rapid
  /// succession. Without a cap, Android/iOS codecs can be overwhelmed by
  /// simultaneous decoder allocations — causing crashes on low-end devices.
  ///
  /// Value of 2: enough to warm next 2 videos in parallel without stressing
  /// the codec pool. Pool/suspend hits bypass this entirely and stay instant.
  final _Semaphore _initSemaphore = _Semaphore(2);

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  void setCurrentUrl(String url) {
    if (_currentUrl != url) {
      _prevUrl = _currentUrl;
    }
    _currentUrl = url;
  }

  void setNextUrl(String? url) {
    _nextUrl = url;
  }

  /// Returns a controller for [url] using the following priority:
  ///   1. Active pool hit   → instant (already playing/ready)
  ///   2. Suspend pool hit  → instant resume (0ms, no decoder init)
  ///   3. Pending creation  → await in-flight init (deduplication)
  ///   4. Fresh creation    → init new controller (200-600ms first time)
  Future<VideoPlayerController> getControllerFor(String url) async {
    // 1. Active pool hit
    if (_controllers.containsKey(url)) {
      final controller = _controllers.remove(url)!;
      _controllers[url] = controller; // Move to MRU end
      return controller;
    }

    // 2. ✨ Suspend pool hit — THE KEY FIX
    //    Move the suspended controller back to the active pool.
    //    No initialize(), no hardware spin-up, no spinner. Pure instant.
    if (_suspended.containsKey(url)) {
      LoggerService.i('[VideoPool] ⚡ Instant resume from SUSPEND pool: ...${_shortUrl(url)}');
      final controller = _suspended.remove(url)!;
      controller.setVolume(globalVolume.value); // Un-mute
      _controllers[url] = controller;
      _enforceMaxSize(); // Active pool might need to evict someone to suspended
      return controller;
    }

    // 3. Deduplication: piggyback on an in-flight creation
    if (_pendingCreations.containsKey(url)) {
      return _pendingCreations[url]!;
    }

    // 4. Fresh creation
    final future = _createController(url);
    _pendingCreations[url] = future;

    try {
      final controller = await future;
      _controllers[url] = controller;
      _enforceMaxSize();
      return controller;
    } catch (e) {
      // Remove stale errored future so the next retry starts fresh.
      _pendingCreations.remove(url);
      rethrow;
    } finally {
      _pendingCreations.remove(url);
    }
  }

  /// Synchronous check: returns controller if in the active pool and ready.
  /// Used by VideoPlayerWidget to avoid the 1-frame async gap on scroll.
  VideoPlayerController? getControllerNow(String url) {
    // 1. Active pool
    if (_controllers.containsKey(url)) {
      final controller = _controllers.remove(url)!;
      _controllers[url] = controller;
      return controller;
    }
    // 2. Suspend pool — re-activate instantly
    if (_suspended.containsKey(url)) {
      LoggerService.i('[VideoPool] ⚡ Sync resume from SUSPEND pool: ...${_shortUrl(url)}');
      final controller = _suspended.remove(url)!;
      controller.setVolume(globalVolume.value);
      _controllers[url] = controller;
      _enforceMaxSize();
      return controller;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle helpers
  // ---------------------------------------------------------------------------

  void saveAllPositions() {
    for (final entry in _controllers.entries) {
      _savePosition(entry.key, entry.value);
    }
    for (final entry in _suspended.entries) {
      _savePosition(entry.key, entry.value);
    }
    LoggerService.d('[VideoPool] 💾 Saved positions for '
        '${_controllers.length} active + ${_suspended.length} suspended');
  }

  void pauseCurrentVideo() {
    final url = _currentUrl;
    if (url == null) return;
    final ctrl = _controllers[url];
    if (ctrl != null && ctrl.value.isInitialized) {
      ctrl.pause();
    }
  }

  void resumeCurrentVideo() {
    final url = _currentUrl;
    if (url == null) return;
    final ctrl = _controllers[url];
    if (ctrl != null && ctrl.value.isInitialized) {
      ctrl.play();
    }
  }

  void removeController(String url) {
    final active = _controllers.remove(url);
    if (active != null) {
      _savePosition(url, active);
      active.dispose();
      return;
    }
    final susp = _suspended.remove(url);
    if (susp != null) {
      _savePosition(url, susp);
      susp.dispose();
    }
  }

  /// Flush everything — called on extreme low memory.
  void clear() {
    for (final entry in [..._controllers.entries, ..._suspended.entries]) {
      _savePosition(entry.key, entry.value);
      entry.value.dispose();
    }
    _controllers.clear();
    _suspended.clear();
    LoggerService.i('[VideoPool] 🧹 All controllers cleared');
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<VideoPlayerController> _createController(String url) async {
    // Acquire a slot — prevents codec pool overflow on fast scroll.
    // Pool/suspend hits never call _createController so they bypass this.
    await _initSemaphore.acquire();
    try {
      // 1. Proxy path (cached HLS)
      try {
        final proxyUrl = HlsCacheManager.instance.getProxiedUrl(url);
        LoggerService.d('[VideoPool] 🟢 Initializing via proxy: ...${_shortUrl(url)}');

        final controller = VideoPlayerController.networkUrl(
          Uri.parse(proxyUrl),
          httpHeaders: const {'Connection': 'keep-alive'},
          videoPlayerOptions:
              VideoPlayerOptions(mixWithOthers: true, allowBackgroundPlayback: true),
        );
        await controller.initialize();
        controller.setLooping(true);
        controller.setVolume(globalVolume.value);
        _restorePosition(url, controller);
        return controller;
      } catch (e) {
        LoggerService.w('[VideoPool] Proxy init failed for ...${_shortUrl(url)}: $e. Falling back to direct.');

        // 2. Direct network fallback
        try {
          final controller = VideoPlayerController.networkUrl(
            Uri.parse(url),
            videoPlayerOptions:
                VideoPlayerOptions(mixWithOthers: true, allowBackgroundPlayback: true),
          );
          await controller.initialize();
          controller.setLooping(true);
          controller.setVolume(globalVolume.value);
          _restorePosition(url, controller);
          return controller;
        } catch (e2) {
          throw Exception('Both proxy and direct init failed for ...${_shortUrl(url)}: $e2');
        }
      }
    } finally {
      _initSemaphore.release(); // Always release the slot
    }
  }

  /// Active pool LRU eviction → moves to Suspend Pool (pause-not-dispose).
  void _enforceMaxSize() {
    while (_controllers.length > maxSize) {
      String? evictKey;
      for (final key in _controllers.keys) {
        if (key != _currentUrl && key != _prevUrl && key != _nextUrl) {
          evictKey = key;
          break;
        }
      }

      if (evictKey != null) {
        final controller = _controllers.remove(evictKey)!;
        _savePosition(evictKey, controller);

        // ── PAUSE NOT DISPOSE ─────────────────────────────────────────────
        // Move to the Suspend Pool. The hardware decoder stays allocated.
        // If the user scrolls back, resume is instant. Only the truly-LRU
        // entries in the Suspend Pool are actually disposed.
        controller.pause();
        controller.setVolume(0); // Silence — not playing, not audible
        _putSuspended(evictKey, controller);

        LoggerService.d('[VideoPool] 💤 Suspended (not disposed): ...${_shortUrl(evictKey)} '
            '| active=${_controllers.length} suspended=${_suspended.length}');
      } else {
        break; // All remaining are protected
      }
    }
  }

  /// LRU-insert into the Suspend Pool.
  /// When the suspend pool overflows, the oldest entry is TRULY disposed.
  void _putSuspended(String url, VideoPlayerController controller) {
    _suspended.remove(url); // Re-insert at MRU end if already present
    if (_suspended.length >= maxSuspendedSize) {
      final lruKey = _suspended.keys.first;
      final lruCtrl = _suspended.remove(lruKey)!;
      _savePosition(lruKey, lruCtrl);
      lruCtrl.dispose();
      LoggerService.d('[VideoPool] 🗑 Actually disposed LRU from suspend pool: ...${_shortUrl(lruKey)}');
    }
    _suspended[url] = controller;
  }

  void _restorePosition(String url, VideoPlayerController controller) {
    final savedPos = _savedPositions[url];
    if (savedPos != null) {
      controller.seekTo(savedPos);
    }
  }

  void _savePosition(String url, VideoPlayerController controller) {
    final pos = controller.value.position;
    if (pos > Duration.zero) {
      if (_savedPositions.length >= _maxSavedPositions) {
        _savedPositions.remove(_savedPositions.keys.first);
      }
      _savedPositions[url] = pos;
    }
  }

  String _shortUrl(String url) =>
      url.length > 40 ? '…${url.substring(url.length - 40)}' : url;

  // ---------------------------------------------------------------------------
  // Resource Management
  // ---------------------------------------------------------------------------

  /// Releases controllers not in the [keepUrls] set.
  /// Runs async with deliberate 150ms pauses between disposals so we do
  /// not block the main isolate and drop frames while scrolling.
  Future<void> trimCache(Set<String> keepUrls) async {
    final toDisposeUrls = <String>{};

    for (final url in _controllers.keys) {
      if (!keepUrls.contains(url)) {
        toDisposeUrls.add(url);
      }
    }
    for (final url in _suspended.keys) {
      if (!keepUrls.contains(url)) {
        toDisposeUrls.add(url);
      }
    }

    if (toDisposeUrls.isEmpty) return;

    LoggerService.i(
      '[VideoPool] 🧹 Trimming ${toDisposeUrls.length} stale controllers (staggered)...'
    );

    for (final url in toDisposeUrls) {
      final active = _controllers.remove(url);
      if (active != null) {
        _savePosition(url, active);
        active.dispose();
      }

      final susp = _suspended.remove(url);
      if (susp != null) {
        _savePosition(url, susp);
        susp.dispose();
      }

      // Deliberate sleep: gives the UI thread a breather.
      // This "splits" the heavy hardware decoder release across multiple frames.
      // 150ms guarantees no stuttering / loaders while preserving app CPU
      await Future.delayed(const Duration(milliseconds: 150));
    }

    LoggerService.i(
      '[VideoPool] ✅ Trim complete. Active=${_controllers.length} Suspended=${_suspended.length}'
    );
  }
}
