import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/hls/hls_cache_manager.dart';
import '../core/video/video_controller_pool.dart';

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

class _VideoPlayerWidgetState extends State<VideoPlayerWidget> with AutomaticKeepAliveClientMixin {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _showPlayIcon = false;
  bool _isBuffering = false;
  Timer? _iconTimer;

  @override
  bool get wantKeepAlive => true;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _tryInitialize();
  }

  void _tryInitialize() {
    // Lazy Init: Only initialize if we are within range.
    // VideoControllerPool handles memory, so we can be slightly more aggressive (distance 2),
    // but sticking to 1 is safer for CPU (decoders).
    final distance = (widget.index - widget.currentIndex).abs();
    
    // If out of range, release reference to controller so the Pool can recycle it
    // and we don't hold onto a potentially disposed object (if evicted).
    if (distance > 1) {
        if (_controller != null) {
            setState(() {
              _controller = null;
              _initialized = false;
            });
        }
        return;
    }

    _initPlayer();
  }

  Future<void> _initPlayer() async {
    if (_initialized || _controller != null) return; 
    
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
      });

      // Listen for buffering changes
      _controller!.addListener(_onControllerUpdate);

      if (widget.shouldPlay) {
        await _safePlay();
      }
    } catch (e) {
      debugPrint('[VideoPlayer] init failed for $targetUrl: $e');
    }
  }

  void _onControllerUpdate() {
      if (!mounted) return;
      final isBuffering = _controller?.value.isBuffering ?? false;
      if (isBuffering != _isBuffering) {
          setState(() => _isBuffering = isBuffering);
      }
  }

  /// iOS Fix: Seek to current position before playing to force texture refresh.
  Future<void> _safePlay() async {
    if (_controller == null) return;
    
    // Force a seek to refresh texture (especially on iOS)
    final pos = _controller!.value.position;
    if (pos > Duration.zero) {
        await _controller!.seekTo(pos);
    }
    await _controller!.play();
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

  @override
  void dispose() {
    _iconTimer?.cancel();
    _controller?.removeListener(_onControllerUpdate);
    // Do NOT call _controller.dispose().
    // Instead, release it back to the pool management (or just let it sit in LRU).
    // The pool handles disposal when it gets full.
    super.dispose();
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
            else
              // Placeholder while initializing (prevents black flash)
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
