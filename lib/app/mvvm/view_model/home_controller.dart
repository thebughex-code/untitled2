import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../model/video_model.dart';
import '../../repository/video_repository.dart';
import '../../services/video_preload_manager.dart';
import '../../services/video_controller_pool.dart';
import '../../services/hls_cache_manager.dart';

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

    // ── Proactive controller pre-warm: next +4 videos ──────────────────────
    // Fire-and-forget initialization for the next 4 videos.
    // VideoPreloadManager ALSO fires pre-warms post-segment-caching, so
    // between these two sources every forward video is warmed well before
    // the user gets there — eliminating the black screen after index 6.
    for (int i = 1; i <= 4; i++) {
        final nextIdx = index + i;
        if (nextIdx < videos.length) {
            VideoControllerPool.instance
                .getControllerFor(videos[nextIdx].url)
                .ignore();
        }
    }

    // ── Backward pre-warm: previous 2 videos ────────────────────────────────
    // Ensures reverse-scrolling is also instant via the suspend pool.
    for (int i = 1; i <= 2; i++) {
        final prevIdx = index - i;
        if (prevIdx >= 0) {
            VideoControllerPool.instance
                .getControllerFor(videos[prevIdx].url)
                .ignore();
        }
    }

    _manageResources(index);

    debugPrint('[HomeController] 📄 Page $index — window=$windowSize (${msSinceLast}ms since last swipe)');
  }

  void _manageResources(int currentIndex) {
    if (currentIndex > 0 && currentIndex % 10 == 0) {
      final keepUrls = <String>{};
      // Keep current, 4 ahead, 2 behind
      for (int i = -2; i <= 4; i++) {
        final idx = currentIndex + i;
        if (idx >= 0 && idx < videos.length) {
          keepUrls.add(videos[idx].url);
        }
      }

      // Fire and forget
      VideoControllerPool.instance.trimCache(keepUrls).ignore();
      if (HlsCacheManager.instance.isInitialized) {
        HlsCacheManager.instance.cache.trimMemoryStaggered().ignore();
      }
    }
  }
}
