import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/hls/video_preload_manager.dart';
import '../core/models/video_data.dart';
import '../core/video/video_controller_pool.dart';
import 'video_player_widget.dart';

/// Full-screen vertical-swipe feed (TikTok / Instagram Reels style).
///
/// Each page is a [VideoPlayerWidget].  The sliding-window preloader is
/// notified on every page change so upcoming videos are cached in advance.
class VideoFeedScreen extends StatefulWidget {
  const VideoFeedScreen({super.key});

  @override
  State<VideoFeedScreen> createState() => _VideoFeedScreenState();
}

class _VideoFeedScreenState extends State<VideoFeedScreen>
    with WidgetsBindingObserver {
  final PageController _pageController = PageController();
  int _currentIndex = 0;

  /// Tracks when the last page change fired — used to infer scroll speed.
  DateTime? _lastPageChange;

  List<VideoData> get _videos => VideoData.videos;

  @override
  void initState() {
    super.initState();
    // Keep screen on while watching videos
    WakelockPlus.enable();
    // Register for app lifecycle events so we can pause/resume correctly.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // App is going to background: save positions FIRST, then pause.
        // Saving before pausing ensures the position captured is accurate
        // (some platforms reset position after pause).
        VideoControllerPool.instance.saveAllPositions();
        VideoControllerPool.instance.pauseCurrentVideo();
        debugPrint('[Feed] 📴 App backgrounded — video paused & positions saved');
        break;

      case AppLifecycleState.resumed:
        // App returned to foreground: resume the current video immediately.
        VideoControllerPool.instance.resumeCurrentVideo();
        debugPrint('[Feed] ▶️ App foregrounded — video resumed');
        break;

      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // No-op: inactive is a transient state before paused/resumed;
        // detached means the engine is shutting down.
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    // 1. Compute scroll speed → dynamic preload window size.
    //    fast  (< 600 ms/swipe)  → 3 videos ahead
    //    normal (600 ms – 2 s)   → 2 videos ahead (default)
    //    slow   (> 2 s)          → 1 video ahead (saves bandwidth)
    final now = DateTime.now();
    final msSinceLast = _lastPageChange == null
        ? 9999
        : now.difference(_lastPageChange!).inMilliseconds;
    _lastPageChange = now;
    final windowSize = msSinceLast < 600 ? 3
                     : msSinceLast < 2000 ? 2
                     : 1;

    // 2. Lock current URL into pool before any rebuild.
    final currentUrl = _videos[index].url;
    VideoControllerPool.instance.setCurrentUrl(currentUrl);

    // 3. Protect next URL so its pre-warmed controller isn't evicted.
    final nextUrl = index + 1 < _videos.length ? _videos[index + 1].url : null;
    VideoControllerPool.instance.setNextUrl(nextUrl);

    setState(() => _currentIndex = index);

    // 4. Sliding-window segment preloading (window driven by scroll speed).
    VideoPreloadManager.instance.onPageChanged(
      index,
      _videos.map((v) => v.url).toList(),
      windowSize: windowSize,
    );

    // 5. 🔥 Proactively pre-warm controllers for next 1 video (saving decoders).
    for (int i = 1; i <= 1; i++) {
        final nextIdx = index + i;
        if (nextIdx < _videos.length) {
            VideoControllerPool.instance
                .getControllerFor(_videos[nextIdx].url)
                .ignore();
        }
    }

    debugPrint('[Feed] 📄 Page $index — window=$windowSize (${msSinceLast}ms since last swipe)');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        allowImplicitScrolling: true, // Crucial for pre-building next page
        onPageChanged: _onPageChanged,
        itemCount: _videos.length,
        itemBuilder: (context, index) {
          return VideoPlayerWidget(
            key: ValueKey(_videos[index].url),
            videoUrl: _videos[index].url,
            title: _videos[index].title,
            shouldPlay: index == _currentIndex,
            index: index,
            currentIndex: _currentIndex,
            total: _videos.length,
          );
        },
      ),
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
          items: [
            const BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'Home'),
            const BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Discover'),
            BottomNavigationBarItem(
              icon: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.add, color: Colors.black, size: 20),
              ),
              label: '',
            ),
            const BottomNavigationBarItem(icon: Icon(Icons.message_outlined), label: 'Inbox'),
            const BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: 'Profile'),
          ],
        ),
      ),
    );
  }
}
