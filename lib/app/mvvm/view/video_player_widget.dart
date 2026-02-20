import 'dart:async';

import 'package:get/get.dart';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../view_model/home_controller.dart';
import '../../services/video_controller_pool.dart';
import '../../services/logger_service.dart';
import '../../widgets/video_overlay_ui.dart';

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
  final int index;

  const VideoPlayerWidget({
    super.key,
    required this.videoUrl,
    required this.title,
    required this.index,
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

  bool get _isCurrentVideo => Get.find<HomeController>().currentIndex.value == widget.index;

  late final Worker _indexListener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    VideoControllerPool.instance.globalVolume.addListener(_onVolumeChanged);
    _tryInitialize();

    // The single most important optimization:
    // This widget never rebuilds. It simply listens to the global index 
    // and tells its internal native video player to start/stop.
    _indexListener = ever(Get.find<HomeController>().currentIndex, (int newIndex) {
      if (newIndex == widget.index) {
        if (_state == PlayerState.ready) {
           VideoControllerPool.instance.setCurrentUrl(widget.videoUrl);
          _safePlay();
        } else {
           _tryInitialize();
        }
      } else {
        _controller?.pause();
      }
    });
  }

  void _onVolumeChanged() {
    if (mounted && _state == PlayerState.ready && _controller != null) {
      _controller!.setVolume(VideoControllerPool.instance.globalVolume.value);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _state == PlayerState.ready && _isCurrentVideo) {
      _isRestored = true; 
      _safePlay();
    }
  }

  void _tryInitialize() {
    final distance = (widget.index - Get.find<HomeController>().currentIndex.value).abs();

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
          if (_isCurrentVideo) {
            VideoControllerPool.instance.setCurrentUrl(widget.videoUrl);
            _safePlay();
          }
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

  /// Initializes the video player controller.
  ///
  /// Uses exponential backoff auto-retry (up to [_maxRetries]) before
  /// ever showing the error UI. This handles:
  ///   • Transient network blips during `controller.initialize()`
  ///   • Proxy cold-start latency on the first request
  ///   • Ghost controller edge cases from the splash pre-warm timeout
  static const int _maxRetries = 3;

  Future<void> _initPlayer() async {
    if (_state == PlayerState.ready && _controller != null) return;

    final targetUrl = widget.videoUrl;

    if (_isCurrentVideo) {
      VideoControllerPool.instance.setCurrentUrl(targetUrl);
    }

    int attempt = 0;
    const delays = [500, 1000, 2000]; // ms: 0.5s → 1s → 2s

    while (attempt < _maxRetries) {
      // Abort immediately if the widget was disposed or scrolled away.
      if (!mounted || _widgetDisposed || widget.videoUrl != targetUrl) return;
      final distance =
          (widget.index - Get.find<HomeController>().currentIndex.value).abs();
      if (distance > 2) return; // Too far away — don't waste bandwidth

      try {
        final controller =
            await VideoControllerPool.instance.getControllerFor(targetUrl);

        // Re-check after the async await gap
        if (!mounted || _widgetDisposed || widget.videoUrl != targetUrl) return;
        if ((widget.index -
                Get.find<HomeController>().currentIndex.value)
            .abs() > 1) return;

        _attachController(controller);
        return; // ✅ Success — exit the retry loop
      } catch (e) {
        attempt++;
        debugPrint(
          '[VideoPlayer] ⚠️ init attempt $attempt/$_maxRetries failed for '
          '${targetUrl.substring(targetUrl.length > 40 ? targetUrl.length - 40 : 0)}: $e',
        );

        if (attempt >= _maxRetries) {
          // All retries exhausted — show error UI
          if (mounted && !_widgetDisposed) {
            setState(() => _state = PlayerState.error);
          }
          return;
        }

        // Exponential backoff — wait before next attempt
        await Future.delayed(Duration(milliseconds: delays[attempt - 1]));
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

    if (_isCurrentVideo) {
      VideoControllerPool.instance.setCurrentUrl(widget.videoUrl);
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
    _indexListener.dispose();
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
    // Widgets never physically update based on scroll index anymore, 
    // so this is largely unused for playback logic.
    if (widget.videoUrl != oldWidget.videoUrl) {
      _clearController();
      _tryInitialize();
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
              Center(
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio == 0
                      ? 16 / 9
                      : _controller!.value.aspectRatio,
                  child: VideoPlayer(_controller!),
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

