import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/video/video_controller_pool.dart';
import '../core/services/logger_service.dart';

/// Plays a single HLS video via the local caching proxy.
///
/// - No loading spinner: shows a black screen until the first frame is ready,
///   then cross-fades in.
/// - Tap to pause / resume with a brief overlay icon.
/// - Loops automatically.
class VideoPlayerWidget extends StatefulWidget {
  final String videoUrl;
  final String title;
  final bool shouldPlay;
  final int index;
  final int currentIndex;
  final int total;

  const VideoPlayerWidget({
    super.key,
    required this.videoUrl,
    required this.title,
    required this.shouldPlay,
    required this.index,
    required this.currentIndex,
    required this.total,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _showPlayIcon = false;
  bool _isBuffering = false;
  bool _widgetDisposed = false; // guard against post-dispose callbacks
  bool _hasError = false;       // true after init failure — shows retry UI
  /// True if the controller was just restored from a saved position
  /// (e.g. from pool eviction, or app backgrounding).
  /// Triggers a one-time seekTo in _safePlay.
  bool _isRestored = false;
  Timer? _iconTimer;

  @override
  bool get wantKeepAlive => true;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tryInitialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _initialized && widget.shouldPlay) {
      // On resume, we force a seek to current position.
      // This is the FIX for the iOS black screen / frozen texture issue.
      _isRestored = true; 
      _safePlay();
    }
  }

  void _tryInitialize() {
    final distance = (widget.index - widget.currentIndex).abs();

    // ── Distance guard: too far away, release reference so pool can evict ──
    if (distance > 2) {
      if (_controller != null) {
        setState(() {
          _controller = null;
          _initialized = false;
        });
      }
      return;
    }

    // ── ✅ Fast-path: widget already has a healthy controller ──────────────
    if (_initialized && _controller != null) {
      try {
        if (_controller!.value.isInitialized) {
          if (widget.index == widget.currentIndex) {
            VideoControllerPool.instance.setCurrentUrl(widget.videoUrl);
          }
          if (widget.shouldPlay) _safePlay();
          return;
        }
      } catch (_) {
        _controller?.removeListener(_onControllerUpdate);
        _controller = null;
        _initialized = false;
      }
    }

    // ── Sync path: controller already in pool ─────────────────────────────
    final existing = VideoControllerPool.instance.getControllerNow(widget.videoUrl);
    if (existing != null && existing.value.isInitialized) {
      debugPrint('[VideoPlayer] ⚡️ Instant synchronous init for ${widget.index}');

      _controller?.removeListener(_onControllerUpdate);

      _controller = existing;
      _initialized = true;
      _isRestored = true; // Mark for seek restoration
      existing.setLooping(true);
      _controller!.addListener(_onControllerUpdate);

      if (widget.index == widget.currentIndex) {
        VideoControllerPool.instance.setCurrentUrl(widget.videoUrl);
      }
      if (widget.shouldPlay) _safePlay();
      return;
    }

    // ── Async path: controller not yet in pool — initialise it ────────────
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    if (_initialized && _controller != null) return;
    
    // Capture the target URL at the START of the async operation.
    final targetUrl = widget.videoUrl;

    // Set current video in pool to prevent eviction
    if (widget.index == widget.currentIndex) {
        VideoControllerPool.instance.setCurrentUrl(targetUrl);
    }

    try {
      // Get from Pool (async)
      final controller = await VideoControllerPool.instance.getControllerFor(targetUrl);

      // -----------------------------------------------------------------------
      // CRITICAL RACE CHECK:
      // If the widget was disposed, or reused for a DIFFERENT videoUrl,
      // or moved out of range while we were waiting, ABORT.
      // -----------------------------------------------------------------------
      if (!mounted) return;
      if (widget.videoUrl != targetUrl) return; 

      final distance = (widget.index - widget.currentIndex).abs();
      if (distance > 1) {
          // We are too far away now. Don't attach.
          return;
      }

      setState(() {
        _controller = controller;
        _initialized = true;
        _isRestored = true; // Mark for seek restoration
      });

      // Listen for buffering changes
      _controller!.addListener(_onControllerUpdate);

      if (widget.shouldPlay) {
        debugPrint('[VideoPlayer] 🎬 Starting playback for ${widget.index}');
        await _safePlay();
      }
    } catch (e) {
      debugPrint('[VideoPlayer] init failed for $targetUrl: $e');
      if (mounted && !_widgetDisposed) {
        setState(() => _hasError = true);
      }
    }
  }

  void _onControllerUpdate() {
      if (!mounted || _widgetDisposed) return;
      final ctrl = _controller;
      if (ctrl == null) return;
      // Guard: controller may have been disposed by pool eviction
      try {
        final isBuffering = ctrl.value.isBuffering;
        if (isBuffering != _isBuffering) {
            debugPrint('[VideoPlayer] ⏳ Buffering changed for ${widget.index}: $isBuffering');
            setState(() => _isBuffering = isBuffering);
        }
      } catch (_) {
        // Controller was disposed externally — detach and clear
        _clearDisposedController();
      }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _iconTimer?.cancel();
    _widgetDisposed = true;
    _controller?.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _clearDisposedController() {
    try { _controller?.removeListener(_onControllerUpdate); } catch (_) {}
    if (mounted && !_widgetDisposed) {
      setState(() {
        _controller = null;
        _initialized = false;
        _isBuffering = false;
      });
    }
  }

  /// Safe play with targeted iOS texture-refresh seek.
  ///
  /// Restore position ONLY if we just attached or app resumed.
  /// This is the "Loader-Free" optimization: by skipping seekTo on normal
  /// back-scroll, we avoid hitting ExoPlayer's buffer state, making playback
  /// resume instantly.
  Future<void> _safePlay() async {
    if (_controller == null || _widgetDisposed) return;

    try {
      // Restore position ONLY if we just attached or app resumed.
      // Skipping this on normal back-scroll fixes the loader flash.
      if (_isRestored) {
        final pos = _controller!.value.position;
        if (pos > const Duration(seconds: 1)) {
          LoggerService.d('[VideoPlayer] 🔄 Restoring position to ${pos.inSeconds}s (Seek)');
          await _controller!.seekTo(pos);
        }
        _isRestored = false;
      }

      if (!_widgetDisposed && _controller != null) {
        await _controller!.play();
      }
    } catch (e) {
      debugPrint('[VideoPlayer] _safePlay error (disposed?): $e');
      _clearDisposedController();
    }
  }

  @override
  void didUpdateWidget(covariant VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (widget.currentIndex != oldWidget.currentIndex) {
      // Update protection against eviction
      if (widget.index == widget.currentIndex) {
           VideoControllerPool.instance.setCurrentUrl(widget.videoUrl);
      }
      _tryInitialize();
    }

    if (widget.shouldPlay != oldWidget.shouldPlay && _initialized) {
      widget.shouldPlay ? _safePlay() : _controller?.pause();
    }
  }

  // -------------------------------------------------------------------------
  // Tap to toggle play / pause
  // -------------------------------------------------------------------------

  void _togglePlayPause() {
    if (_controller == null || !_initialized) return;

    final playing = _controller!.value.isPlaying;
    playing ? _controller!.pause() : _controller!.play();

    setState(() => _showPlayIcon = true);
    _iconTimer?.cancel();
    _iconTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _showPlayIcon = false);
    });
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return GestureDetector(
      onTap: _togglePlayPause,
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video surface ------------------------------------------------
            if (_initialized && _controller != null)
              AnimatedOpacity(
                opacity: 1.0,
                duration: const Duration(milliseconds: 300),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio == 0
                        ? 16 / 9
                        : _controller!.value.aspectRatio,
                    child: VideoPlayer(_controller!),
                  ),
                ),
              )
            else if (_hasError)
              // Error state — shown when init fails (network error / offline)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_off_rounded, color: Colors.white54, size: 48),
                    const SizedBox(height: 12),
                    const Text(
                      'Could not load video',
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _hasError = false);
                        _initPlayer();
                      },
                      icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
                      label: const Text('Retry', style: TextStyle(color: Colors.white70)),
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.white12,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              // Placeholder while initializing
              Container(
                color: Colors.grey[900],
                child: const Center(
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
                  ),
                ),
              ),

             // Mid-stream Buffering Indicator ------------------------------
            if (_initialized && _isBuffering)
              const Center(
                child: SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                ),
              ),

            // Bottom gradient overlay -------------------------------------
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 200,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withAlpha(180),
                    ],
                  ),
                ),
              ),
            ),

            // Title + index label -----------------------------------------
            Positioned(
              left: 16,
              right: 80,
              bottom: 48,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      shadows: [
                        Shadow(blurRadius: 6, color: Colors.black87),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.index + 1} / ${widget.total}',
                    style: TextStyle(
                      color: Colors.white.withAlpha(180),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            // Play / pause icon -------------------------------------------
            if (_showPlayIcon)
              Center(
                child: Icon(
                  _controller?.value.isPlaying == true
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 80,
                  color: Colors.white70,
                ),
              ),

            // Thin progress bar at the very bottom -------------------------
            if (_initialized && _controller != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: VideoProgressIndicator(
                  _controller!,
                  allowScrubbing: false,
                  padding: EdgeInsets.zero,
                  colors: const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white24,
                    backgroundColor: Colors.transparent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
