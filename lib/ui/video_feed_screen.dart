import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/hls/hls_cache_manager.dart';
import '../core/hls/video_preload_manager.dart';
import '../core/models/video_data.dart';
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

class _VideoFeedScreenState extends State<VideoFeedScreen> {
  final PageController _pageController = PageController();
  int _currentIndex = 0;

  List<VideoData> get _videos => VideoData.videos;

  @override
  void initState() {
    super.initState();
    // Keep screen on while watching videos
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);

    // Kick off sliding-window preloading for nearby videos.
    // Kick off sliding-window preloading for nearby videos.
    VideoPreloadManager.instance.onPageChanged(
      index,
      _videos.map((v) => v.url).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        onPageChanged: _onPageChanged,
        itemCount: _videos.length,
        itemBuilder: (context, index) {
          return VideoPlayerWidget(
            key: ValueKey(_videos[index].url),
            videoUrl: _videos[index].url,
            title: _videos[index].title,
            shouldPlay: index == _currentIndex,
            index: index,
            currentIndex: _currentIndex, // Pass current index for lazy init logic
            total: _videos.length,
          );
        },
      ),
    );
  }
}
