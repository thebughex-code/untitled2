import 'package:flutter/material.dart';

import '../core/hls/hls_cache_manager.dart';
import '../core/hls/video_preload_manager.dart';
import '../core/models/video_data.dart';
import '../core/services/logger_service.dart';
import '../core/video/video_controller_pool.dart';
import 'video_feed_screen.dart';

/// Branded splash screen shown while the HLS cache system boots up and the
/// first batch of videos is pre-loaded.
///
/// Once ready the splash navigates to [VideoFeedScreen].
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _start();
  }

  /// Runs bootstrap work and a minimum branding delay in parallel,
  /// then navigates when both are done.
  Future<void> _start() async {
    await Future.wait([
      _bootstrap(),
      // Guarantee the logo is visible for at least 1.5 s on fast devices.
      Future.delayed(const Duration(milliseconds: 1500)),
    ]);
    if (!mounted) return;
    LoggerService.d('[Splash] 🚀 Navigating to VideoFeedScreen');
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, a, b) => const VideoFeedScreen(),
        transitionsBuilder: (_, animation, c, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  /// Initialises the HLS cache and preloads the first 3 videos.
  /// Navigation is handled by [_start] so this method purely does work.
  Future<void> _bootstrap() async {
    final bootstrapStart = DateTime.now();
    LoggerService.i('[Splash] ▶️ Bootstrap started');

    try {
      // Step 1: HLS proxy + disk cache
      LoggerService.d('[Splash] 1/3 Initialising HlsCacheManager…');
      final hlsStart = DateTime.now();
      await HlsCacheManager.instance.init();
      LoggerService.i(
        '[Splash] ✅ HlsCacheManager ready '
        '(${DateTime.now().difference(hlsStart).inMilliseconds} ms)',
      );

      final urls = VideoData.videos.map((v) => v.url).toList();
      if (urls.isEmpty) return;

      // Steps 2 & 3: segment preload + controller warm-up run concurrently.
      LoggerService.d('[Splash] 2+3 Parallel: preload 3 videos + warm-up controllers 0 & 1…');
      final parallelStart = DateTime.now();

      bool timedOut = false;
      await Future.wait([
        // Task A – cache manifests + leading segments for first 3 videos.
        VideoPreloadManager.instance
            .preloadInitialBatch(urls, count: 3)
            .timeout(
          const Duration(seconds: 4), // hard cap — matches splash duration
          onTimeout: () {
            timedOut = true;
            LoggerService.w('[Splash] ⏱ Segment preload timed out after 4 s');
          },
        ),

        // Task B – warm up controllers for videos 0 AND 1 in parallel.
        Future(() async {
          try {
            LoggerService.d('[Splash] 🔥 Warming up controllers for videos 0 & 1…');
            final ctrlStart = DateTime.now();
            final warmUrls = urls.take(2).toList();
            await Future.wait(
              warmUrls.map((u) => VideoControllerPool.instance.getControllerFor(u)),
            );
            LoggerService.i(
              '[Splash] ✅ Controllers (${warmUrls.length}) ready '
              '(${DateTime.now().difference(ctrlStart).inMilliseconds} ms)',
            );
          } catch (e) {
            LoggerService.w('[Splash] ⚠️ Controller warm-up failed: $e');
          }
        }),
      ]);

      if (!timedOut) {
        LoggerService.i(
          '[Splash] ✅ Parallel phase complete '
          '(${DateTime.now().difference(parallelStart).inMilliseconds} ms)',
        );
      }
    } catch (e) {
      LoggerService.e('[Splash] ❌ Bootstrap error: $e');
    }

    LoggerService.i(
      '[Splash] 🏁 Bootstrap done '
      '(${DateTime.now().difference(bootstrapStart).inMilliseconds} ms)',
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: FadeTransition(
          opacity: _pulse.drive(Tween(begin: 0.4, end: 1.0)),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.play_circle_filled_rounded,
                  size: 100, color: Colors.white),
              SizedBox(height: 20),
              Text(
                'Reels',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
