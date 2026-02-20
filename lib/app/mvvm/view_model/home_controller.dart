import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../model/video_model.dart';
import '../../repository/video_repository.dart';
import '../../services/video_preload_manager.dart';
import '../../services/video_controller_pool.dart';

class HomeController extends GetxController {
  final VideoRepository _repository = VideoRepository();

  var videos = <VideoModel>[].obs;
  var isLoading = false.obs;
  var currentIndex = 0.obs;

  DateTime? _lastPageChange;

  @override
  void onInit() {
    super.onInit();
    fetchVideos();
  }

  void fetchVideos() {
    // We only show the full-screen loader if we have NO cached videos.
    if (videos.isEmpty) {
      isLoading(true);
    }

    _repository.fetchVideosStream().listen(
      (emittedVideos) {
        if (emittedVideos.isNotEmpty) {
          final wasEmpty = videos.isEmpty;
          
          // Silently update the array behind the scenes
          videos.assignAll(emittedVideos);
          isLoading(false);
          
          // If this is the FIRST emission (either Cache or Network), 
          // we must kickstart the native preloading engine
          if (wasEmpty) {
            onPageChanged(0);
          }
        }
      },
      onError: (e) {
        debugPrint('[HomeController] Error fetching videos: $e');
        isLoading(false);
      },
      onDone: () {
        isLoading(false);
      },
    );
  }

  void onPageChanged(int index) {
    if (videos.isEmpty) return;

    final now = DateTime.now();
    final msSinceLast = _lastPageChange == null
        ? 9999
        : now.difference(_lastPageChange!).inMilliseconds;
    _lastPageChange = now;
    
    // Increase default window size! Since `concurrencyLimit=1` strictly prevents network starvation,
    // we can safely queue +2 videos into the preload queue even when the user is watching slowly.
    final windowSize = msSinceLast < 600 ? 4
                     : msSinceLast < 2000 ? 3
                     : 2;

    final currentUrl = videos[index].url;
    VideoControllerPool.instance.setCurrentUrl(currentUrl);

    final nextUrl = index + 1 < videos.length ? videos[index + 1].url : null;
    VideoControllerPool.instance.setNextUrl(nextUrl);

    currentIndex.value = index;

    VideoPreloadManager.instance.onPageChanged(
      index,
      videos.map((v) => v.url).toList(),
      windowSize: windowSize,
    );

    // Proactively pre-warm controllers for next 1 video (saving decoders)
    for (int i = 1; i <= 1; i++) {
        final nextIdx = index + i;
        if (nextIdx < videos.length) {
            VideoControllerPool.instance
                .getControllerFor(videos[nextIdx].url)
                .ignore();
        }
    }

    debugPrint('[HomeController] 📄 Page $index — window=$windowSize (${msSinceLast}ms since last swipe)');
  }
}
