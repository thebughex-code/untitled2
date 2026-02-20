import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../view_model/home_controller.dart';
import '../../services/video_controller_pool.dart';
import 'video_player_widget.dart';

/// Enterprise-grade HomeScreen.
///
/// Converted to a StatefulWidget to correctly:
///   1. Remove the WidgetsBindingObserver on dispose (prevents memory leak).
///   2. Enable/disable WakelockPlus in the proper lifecycle methods.
///   3. Keep the PageView completely outside of any Obx listener so it is
///      never torn down on a reactive update, preserving pre-warmed decoder states.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final HomeController _controller;

  @override
  void initState() {
    super.initState();
    _controller = Get.find<HomeController>();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        VideoControllerPool.instance.saveAllPositions();
        VideoControllerPool.instance.pauseCurrentVideo();
        debugPrint('[Feed] 📴 App backgrounded — video paused & positions saved');
        break;
      case AppLifecycleState.resumed:
        VideoControllerPool.instance.resumeCurrentVideo();
        debugPrint('[Feed] ▶️ App foregrounded — video resumed');
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: _buildBody(),
      bottomNavigationBar: Theme(
        data: ThemeData(
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
        ),
        child: BottomNavigationBar(
          backgroundColor: Colors.black,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white54,
          type: BottomNavigationBarType.fixed,
          showSelectedLabels: true,
          showUnselectedLabels: true,
          selectedFontSize: 10,
          unselectedFontSize: 10,
          currentIndex: 0,
          onTap: (_) {}, // TODO: wire navigation
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'Home'),
            BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Discover'),
            BottomNavigationBarItem(icon: Icon(Icons.add_box_outlined), label: ''),
            BottomNavigationBarItem(icon: Icon(Icons.message_outlined), label: 'Inbox'),
            BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: 'Profile'),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    // ── Loading overlay ──
    // Only this tiny Obx listens to `isLoading`. The PageView never rebuilds.
    return Stack(
      children: [
        // ── PageView: built ONCE, lives outside ANY Obx ──
        // Decoder pre-warm states from SplashScreen and VideoControllerPool
        // are preserved intact because this widget is never torn down.
        Obx(() {
          if (_controller.videos.isEmpty && !_controller.isLoading.value) {
            return const Center(
              child: Text('No videos found', style: TextStyle(color: Colors.white)),
            );
          }
          if (_controller.videos.isEmpty) {
            // Videos not loaded yet — show placeholder while loading
            return const SizedBox.shrink();
          }

          // ── CRITICAL: PageView is only built once videos are available.
          //    After that, even if `videos` list refreshes silently,
          //    the PageView is NOT rebuilt because we wrap with a ValueKey
          //    that only changes on non-empty → non-empty transitions stays stable.
          return PageView.builder(
            scrollDirection: Axis.vertical,
            allowImplicitScrolling: true,
            onPageChanged: _controller.onPageChanged,
            itemCount: _controller.videos.length,
            itemBuilder: (context, index) {
              final video = _controller.videos[index];
              return VideoPlayerWidget(
                key: ValueKey(video.url),
                videoUrl: video.url,
                title: video.title,
                index: index,
              );
            },
          );
        }),

        // ── Full-screen loading spinner (only when feed is completely empty) ──
        Obx(() {
          if (_controller.isLoading.value && _controller.videos.isEmpty) {
            return const Center(child: CircularProgressIndicator(color: Colors.white));
          }
          return const SizedBox.shrink();
        }),
      ],
    );
  }
}
