import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/video/video_controller_pool.dart';
import '../core/services/logger_service.dart';
import 'widgets/video_overlay_ui.dart';

enum PlayerState {
  loading,
  ready,
  error,
}

/// Plays a single HLS video via the local caching proxy.
///
/// - Uses [PlayerState] for clear lifecycle management instead of nested booleans.
/// - Delegates all UI to [VideoOverlayUI].
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
  PlayerState _state = PlayerState.loading;
  
  bool _showPlayIcon = false;
  bool _isBuffering = false;
  bool _widgetDisposed = false;
  
  /// True if the controller was just restored from a saved position.
  /// Triggers a one-time seekTo in _safePlay to refresh iOS rendering.
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
    VideoControllerPool.instance.globalVolume.addListener(_onVolumeChanged);
    _tryInitialize();
  }

  void _onVolumeChanged() {
    if (mounted && _state == PlayerState.ready && _controller != null) {
      _controller!.setVolume(VideoControllerPool.instance.globalVolume.value);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _state == PlayerState.ready && widget.shouldPlay) {
      _isRestored = true; 
      _safePlay();
    }
  }

  void _tryInitialize() {
    final distance = (widget.index - widget.currentIndex).abs();

    // ── Distance guard: too far away, evict ────────────────────────────────
    if (distance > 2) {
      if (_controller != null) {
        setState(() {
          _controller = null;
          _state = PlayerState.loading;
        });
      }
      return;
    }

    // ── ✅ Fast-path: already initialized ──────────────────────────────────
    if (_state == PlayerState.ready && _controller != null) {
      try {
        if (_controller!.value.isInitialized) {
          if (widget.index == widget.currentIndex) {
            VideoControllerPool.instance.setCurrentUrl(widget.videoUrl);
          }
          if (widget.shouldPlay) _safePlay();
          return;
        }
      } catch (_) {
        _clearController();
      }
    }

    // ── Sync path: controller already in pool ─────────────────────────────
    final existing = VideoControllerPool.instance.getControllerNow(widget.videoUrl);
    if (existing != null && existing.value.isInitialized) {
      debugPrint('[VideoPlayer] ⚡️ Instant sync init for ${widget.index}');
      _attachController(existing);
      return;
    }

    // ── Async path: get from pool / initialise ────────────────────────────
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    if (_state == PlayerState.ready && _controller != null) return;
    
    final targetUrl = widget.videoUrl;

    if (widget.index == widget.currentIndex) {
        VideoControllerPool.instance.setCurrentUrl(targetUrl);
    }

    try {
      final controller = await VideoControllerPool.instance.getControllerFor(targetUrl);

      // Race condition checks
      if (!mounted || widget.videoUrl != targetUrl) return; 

      final distance = (widget.index - widget.currentIndex).abs();
      if (distance > 1) return; // Too far away now

      _attachController(controller);
    } catch (e) {
      debugPrint('[VideoPlayer] init failed for $targetUrl: $e');
      if (mounted && !_widgetDisposed) {
        setState(() => _state = PlayerState.error);
      }
    }
  }

  void _attachController(VideoPlayerController c) {
    _controller?.removeListener(_onControllerUpdate);
    
    setState(() {
      _controller = c;
      _state = PlayerState.ready;
      _isRestored = true;
    });

    _controller!.setLooping(true);
    _controller!.addListener(_onControllerUpdate);
    _controller!.setVolume(VideoControllerPool.instance.globalVolume.value);

    // iOS Metal Render Hack
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });

    if (widget.index == widget.currentIndex) {
      VideoControllerPool.instance.setCurrentUrl(widget.videoUrl);
    }
    
    if (widget.shouldPlay) {
      _safePlay();
    }
  }

  void _onControllerUpdate() {
      if (!mounted || _widgetDisposed || _controller == null) return;
      
      try {
        final isBuffering = _controller!.value.isBuffering;
        if (isBuffering != _isBuffering) {
            setState(() => _isBuffering = isBuffering);
        }
      } catch (_) {
        _clearController();
      }
  }

  void _clearController() {
    try { _controller?.removeListener(_onControllerUpdate); } catch (_) {}
    if (mounted && !_widgetDisposed) {
      setState(() {
        _controller = null;
        _state = PlayerState.loading;
        _isBuffering = false;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VideoControllerPool.instance.globalVolume.removeListener(_onVolumeChanged);
    _iconTimer?.cancel();
    _widgetDisposed = true;
    _controller?.removeListener(_onControllerUpdate);
    super.dispose();
  }

  Future<void> _safePlay() async {
    if (_controller == null || _widgetDisposed) return;

    try {
      if (_isRestored) {
        final pos = _controller!.value.position;
        if (pos > const Duration(seconds: 1)) {
          LoggerService.d('[VideoPlayer] 🔄 Seek restoring ${pos.inSeconds}s');
          await _controller!.seekTo(pos);
        }
        _isRestored = false;
      }

      if (!_widgetDisposed && _controller != null) {
        await _controller!.play();
      }
    } catch (e) {
      debugPrint('[VideoPlayer] _safePlay error: $e');
      _clearController();
    }
  }

  @override
  void didUpdateWidget(covariant VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    if (widget.currentIndex != oldWidget.currentIndex) {
      if (widget.index == widget.currentIndex) {
           VideoControllerPool.instance.setCurrentUrl(widget.videoUrl);
      }
      _tryInitialize();
    }

    if (widget.shouldPlay != oldWidget.shouldPlay && _state == PlayerState.ready) {
      widget.shouldPlay ? _safePlay() : _controller?.pause();
    }
  }

  void _togglePlayPause() {
    if (_controller == null || _state != PlayerState.ready) return;

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
    super.build(context);
    return GestureDetector(
      onTap: _togglePlayPause,
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video surface ------------------------------------------------
            if (_state == PlayerState.ready && _controller != null)
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
            else if (_state == PlayerState.error)
              _buildErrorOverlay()
            else
              _buildLoadingOverlay(),

            // Buffering ----------------------------------------------------
            if (_state == PlayerState.ready && _isBuffering)
              const Center(
                child: SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                ),
              ),

             // Extracted UI Overlay ----------------------------------------
             VideoOverlayUI(index: widget.index, title: widget.title),

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

            // Progress bar -------------------------------------------------
            if (_state == PlayerState.ready && _controller != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: VideoProgressIndicator(
                  _controller!,
                  allowScrubbing: true,
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

  Widget _buildLoadingOverlay() {
    return Container(
      color: Colors.grey[900],
      child: const Center(
        child: SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
        ),
      ),
    );
  }

  Widget _buildErrorOverlay() {
    return Center(
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
              setState(() => _state = PlayerState.loading);
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
    );
  }
}

