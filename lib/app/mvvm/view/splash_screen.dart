import 'dart:async';
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
              LoggerService.d('[Splash] 2/2 🔥 Stealth Pre-Warming Hardware Decoder for: $firstUrl');
              final warmStart = DateTime.now();
              
              // We do not wait for the video to fully download, we just force the 
              // hardware decoder to allocate memory and init the Extractor.
              await VideoControllerPool.instance
                  .getControllerFor(firstUrl)
                  .timeout(const Duration(milliseconds: 1000));
                  
              LoggerService.i(
                '[Splash] ✅ Hardware Decoder Warmed Up '
                '(${DateTime.now().difference(warmStart).inMilliseconds} ms)',
              );
            }
          }
        }
      } catch (e) {
        // If the stealth prewarm fails (slow internet, corrupted cache, etc),
        // we silently swallow it so the app still boots successfully.
        if (e is TimeoutException) {
          LoggerService.w('[Splash] ⏱ Pre-warm hardware timeout (Skipping gracefully).');
        } else {
          LoggerService.w('[Splash] ⚠️ Pre-warm hardware skipped: $e');
        }
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

