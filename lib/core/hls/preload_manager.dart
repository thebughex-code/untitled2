import 'dart:async';

import 'package:flutter/foundation.dart';

import 'proxy_server.dart';

/// Pre-loads HLS manifests and the first N segments for upcoming videos so
/// that playback starts instantly with zero visible buffering.
///
/// Uses a **sliding-window** approach: as the user scrolls through the feed,
/// videos within ±[slidingWindowSize] pages of the current index are
/// pre-loaded.
class PreloadManager {
  // ---------------------------------------------------------------------------
  // Dependencies & config
  // ---------------------------------------------------------------------------
  final ProxyServer proxyServer;

  /// Number of initial segments to pre-fetch per video.
  final int preloadSegmentCount;

  /// How many videos ahead/behind the current index to keep warm.
  final int slidingWindowSize;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Videos whose manifests have already been fully pre-loaded.
  final Set<String> _preloadedManifests = {};

  /// Segment URL lists keyed by video URL.
  final Map<String, List<String>> _videoSegments = {};

  /// Currently-running preload futures (prevents duplicate work).
  final Map<String, Future<void>> _preloadingTasks = {};

  PreloadManager({
    required this.proxyServer,
    this.preloadSegmentCount = 5,
    this.slidingWindowSize = 2,
  });

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Pre-load manifest + first [preloadSegmentCount] segments for [url].
  ///
  /// Safe to call multiple times – duplicate / in-flight requests are ignored.
  Future<void> preloadVideo(String url) async {
    if (_preloadedManifests.contains(url)) return;

    // Reuse in-flight task if one already exists.
    if (_preloadingTasks.containsKey(url)) {
      await _preloadingTasks[url];
      return;
    }

    final task = _doPreload(url);
    _preloadingTasks[url] = task;

    try {
      await task;
    } finally {
      _preloadingTasks.remove(url);
    }
  }

  /// Pre-load the first [count] videos from [urls] in parallel.
  ///
  /// Intended to be called during the splash screen so the first few videos
  /// are ready before the feed is shown.
  Future<void> preloadInitialBatch(List<String> urls, {int count = 3}) async {
    final batch = urls.take(count).toList();
    // Sequential preload to avoid hitting upstream rate limits (503s)
    for (final url in batch) {
      await preloadVideo(url);
    }
  }

  /// Called when the visible page changes.  Pre-loads videos in the sliding
  /// window around [currentIndex].
  void onPageChanged(int currentIndex, List<String> allUrls) {
    if (allUrls.isEmpty) return;

    // 1. Prioritize next 2 videos for instant scroll
    final next1 = currentIndex + 1;
    if (next1 < allUrls.length) preloadVideo(allUrls[next1]);

    final next2 = currentIndex + 2;
    if (next2 < allUrls.length) preloadVideo(allUrls[next2]);

    // 2. Then fill the rest of the window (previous, etc.)
    final start = (currentIndex - slidingWindowSize).clamp(0, allUrls.length);
    final end =
        (currentIndex + slidingWindowSize + 1).clamp(0, allUrls.length);

    for (int i = start; i < end; i++) {
        if (i != next1 && i != next2 && i != currentIndex) {
             preloadVideo(allUrls[i]);
        }
    }
  }

  /// Returns the segment URLs known for [videoUrl] (empty if not yet parsed).
  List<String> segmentsFor(String videoUrl) =>
      _videoSegments[videoUrl] ?? const [];

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<void> _doPreload(String url) async {
    try {
      // 1. Download & cache the manifest (recursively for master playlists).
      final segmentUrls =
          await proxyServer.downloadAndCacheManifest(url);
      _videoSegments[url] = segmentUrls;
      _preloadedManifests.add(url);

      // 2. Pre-fetch the first N segments.
      final count = segmentUrls.length < preloadSegmentCount
          ? segmentUrls.length
          : preloadSegmentCount;

      for (int i = 0; i < count; i++) {
        await proxyServer.getOrDownloadSegment(segmentUrls[i]);
      }

      debugPrint(
          '[PreloadManager] ✓ preloaded $count segments for $url');
    } catch (e) {
      debugPrint('[PreloadManager] preload failed for $url: $e');
    }
  }
}
