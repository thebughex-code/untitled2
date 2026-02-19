import 'package:flutter/material.dart';

import '../core/hls/hls_cache_manager.dart';
import '../core/models/video_data.dart';
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
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      // 1. Spin up local proxy + disk cache
      await HlsCacheManager.instance.init();

      // 2. Pre-load the first 4 videos (manifest + first 5 sec segments)
      final urls = VideoData.videos.map((v) => v.url).toList();
      await HlsCacheManager.instance.preloadManager
          .preloadInitialBatch(urls, count: 4)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              // Don't block forever – the proxy will fetch on demand.
              debugPrint('[Splash] preload timed out, continuing…');
            },
          );
    } catch (e) {
      debugPrint('[Splash] bootstrap error: $e');
    }

    if (!mounted) return;

    // 3. Navigate to the video feed (no back-stack)
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, a, b) => const VideoFeedScreen(),
        transitionsBuilder: (_, animation, c, child) =>
            FadeTransition(opacity: animation, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
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
