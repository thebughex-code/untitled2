// dart:async no longer needed — TimeoutException removed with the .timeout() anti-pattern
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/hls_cache_manager.dart';
import '../../services/logger_service.dart';
import '../../services/video_controller_pool.dart';
import '../../routes/app_routes.dart';

/// Branded splash screen shown while the HLS cache system boots up and the
/// first batch of videos is pre-loaded.
///
/// Once ready the splash navigates to [HomeScreen].
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
    LoggerService.d('[Splash] 🚀 Navigating to HomeScreen');
    
    Get.offNamed(Routes.HOME);
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

      // Step 2: Stealth Hardware Decoder Pre-Warming (The TikTok trick)
      // While the user is staring at the Splash Screen logo for 1.5 seconds,
      // the CPU is completely idle. We crack open SharedPreferences, grab the 
      // URL of the FIRST video from the previous session, and instantly spin up 
      // the iOS/Android hardware MediaCodec natively in the background. 
      // This totally hides the 500ms physical hardware boot delay.
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedString = prefs.getString('cached_video_feed');
        if (cachedString != null) {
          final List<dynamic> jsonList = jsonDecode(cachedString);
          if (jsonList.isNotEmpty) {
            final firstUrl = jsonList.first['url'] as String?;
            if (firstUrl != null && firstUrl.isNotEmpty) {
              LoggerService.d('[Splash] 🔥 Fire-and-forget pre-warm for: $firstUrl');

              // ── Expert approach: NEVER use .timeout() here. ──
              //
              // The old code used .await + .timeout(1000ms). When the timeout
              // fired, it threw a TimeoutException while the underlying
              // controller.initialize() kept running inside _pendingCreations.
              // That errored future was left as a "ghost" — the next caller
              // (VideoPlayerWidget) would receive the same stale error and
              // show the Retry button even when fully online and cached.
              //
              // The correct approach: fire-and-forget (unawaited).
              //   - The controller initializes concurrently in the background.
              //   - The 1500ms branding delay in _start() governs navigation.
              //   - If init finishes before navigation → pool hit, 0ms load.
              //   - If init is still running when HomeScreen loads → 
              //     VideoPlayerWidget calls getControllerFor(), which finds the 
              //     same future in _pendingCreations and naturally piggybacks 
              //     on the in-progress init with zero retries needed.
              //   - There is no timeout, no ghost, no error.
              VideoControllerPool.instance
                  .getControllerFor(firstUrl)
                  .then((_) {
                    LoggerService.i('[Splash] ✅ Pre-warm complete (ran in background)');
                  })
                  .onError((e, _) {
                    // Errors are silently swallowed — VideoPlayerWidget's own
                    // 3-attempt retry loop handles recovery on the HomeScreen.
                    LoggerService.w('[Splash] ⚠️ Pre-warm failed (retry will handle): $e');
                  });
            }
          }
        }
      } catch (e) {
        LoggerService.w('[Splash] ⚠️ Pre-warm setup skipped: $e');
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

