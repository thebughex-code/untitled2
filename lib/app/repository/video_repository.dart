import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../mvvm/model/video_model.dart';
import '../services/logger_service.dart';

class VideoRepository {
  static const String _cacheKey = 'cached_video_feed';

  // ── Cache versioning ─────────────────────────────────────────────────────
  // Bump this number whenever the URL list changes. The next boot will detect
  // the mismatch, discard the stale SharedPreferences cache, and write fresh data.
  static const int _cacheVersion = 2;
  static const String _cacheVersionKey = 'cached_video_feed_version';

  // ── Production feed URLs ─────────────────────────────────────────────────
  static const List<Map<String, String>> _productionFeed = [
    {'url': 'https://fu.fuzzin.com/posts/f9038185-5c96-4580-bbfc-3acfb24b00b6/master.m3u8', 'title': 'Fuzzin #1'},
    {'url': 'https://fu.fuzzin.com/posts/079334c2-81eb-4470-b57b-682b29635737/master.m3u8', 'title': 'Fuzzin #2'},
    {'url': 'https://fu.fuzzin.com/posts/4f17bf0c-d14c-40fd-8782-327e319e5bde/master.m3u8', 'title': 'Fuzzin #3'},
    {'url': 'https://fu.fuzzin.com/posts/cc2f9c9c-1b10-4f61-a222-e3a225afa215/master.m3u8', 'title': 'Fuzzin #4'},
    {'url': 'https://fu.fuzzin.com/posts/cc0b5cd0-a8be-4342-adf1-d00f1fa20386/master.m3u8', 'title': 'Fuzzin #5'},
    {'url': 'https://fu.fuzzin.com/posts/84bd0a0e-a83e-4a58-9462-8ca34648cd15/master.m3u8', 'title': 'Fuzzin #6'},
    {'url': 'https://fu.fuzzin.com/posts/d63f2bda-f6df-41c1-a2ac-ccbbf52e4e8a/master.m3u8', 'title': 'Fuzzin #7'},
    {'url': 'https://fu.fuzzin.com/posts/348ab1a2-8766-44a8-a7ba-e84ab87c12ab/master.m3u8', 'title': 'Fuzzin #8'},
    {'url': 'https://fu.fuzzin.com/posts/8932d96d-cc25-4d1a-a0eb-102af32157ac/master.m3u8', 'title': 'Fuzzin #9'},
    {'url': 'https://fu.fuzzin.com/posts/fb40a3ab-3147-49e1-8f4e-2d5999191e59/master.m3u8', 'title': 'Fuzzin #10'},
    {'url': 'https://fu.fuzzin.com/posts/29d07ed1-f8fc-4861-9173-2817f121828c/master.m3u8', 'title': 'Fuzzin #11'},
    {'url': 'https://fu.fuzzin.com/posts/d8f47161-358d-4ccd-a942-de5737bf38d3/master.m3u8', 'title': 'Fuzzin #12'},
    {'url': 'https://fu.fuzzin.com/posts/7846480e-c255-44d8-a003-4ee8acffd55c/master.m3u8', 'title': 'Fuzzin #13'},
    {'url': 'https://fu.fuzzin.com/posts/0e2e159c-9709-4893-a145-5658a7110c8d/master.m3u8', 'title': 'Fuzzin #14'},
    {'url': 'https://fu.fuzzin.com/posts/1ae9a260-504f-40f0-9780-5cf4aa4f5831/master.m3u8', 'title': 'Fuzzin #15'},
    {'url': 'https://fu.fuzzin.com/posts/f67a10e7-61ec-4f63-8f3f-49f63ebaf74a/master.m3u8', 'title': 'Fuzzin #16'},
    {'url': 'https://fu.fuzzin.com/posts/0f8d7134-3ea9-42de-bec3-f6ef8ef4902c/master.m3u8', 'title': 'Fuzzin #17'},
    {'url': 'https://fu.fuzzin.com/posts/07d2c369-e3d9-4911-a8e9-c0ceaa7f7209/master.m3u8', 'title': 'Fuzzin #18'},
    {'url': 'https://fu.fuzzin.com/posts/811c96b1-3cfe-4a35-abdd-9b6053c8e27c/master.m3u8', 'title': 'Fuzzin #19'},
    {'url': 'https://fu.fuzzin.com/posts/3eed84a1-5ce3-4f82-9be2-a68260d5fa5a/master.m3u8', 'title': 'Fuzzin #20'},
  ];

  /// Yields a stream of videos.
  /// Pass 1 (0ms):     Emits the cached feed from SharedPreferences instantly.
  /// Pass 2 (network): Emits the fresh production feed and caches it.
  Stream<List<VideoModel>> fetchVideosStream() async* {
    final prefs = await SharedPreferences.getInstance();

    // ── Cache version check ───────────────────────────────────────────────────
    // If the version stored on disk doesn't match the current version, wipe the
    // stale cache so the user isn't stuck with old/incompatible URLs.
    final storedVersion = prefs.getInt(_cacheVersionKey) ?? 0;
    if (storedVersion != _cacheVersion) {
      LoggerService.i('[VideoRepository] 🔄 Cache version mismatch ($storedVersion→$_cacheVersion). Flushing stale cache.');
      await prefs.remove(_cacheKey);
      await prefs.setInt(_cacheVersionKey, _cacheVersion);
    }

    // 1. Instant Offline Pass: Read Cache
    final cachedString = prefs.getString(_cacheKey);
    if (cachedString != null) {
      try {
        final List<dynamic> jsonList = jsonDecode(cachedString);
        final cachedVideos = jsonList.map((j) => VideoModel.fromJson(j)).toList();
        if (cachedVideos.isNotEmpty) {
          LoggerService.i('[VideoRepository] ⚡️ Yielded ${cachedVideos.length} CACHED videos instantly (0ms)');
          yield cachedVideos;
        }
      } catch (e) {
        LoggerService.w('[VideoRepository] Failed to decode cache: $e');
      }
    } else {
      LoggerService.d('[VideoRepository] No cache found. Loading production feed.');
    }

    // 2. Production Feed (background network pass)
    // In a real app, replace this with your actual Dio API call.
    // For now, the production URLs are baked in.
    final freshVideos = _productionFeed
        .map((entry) => VideoModel(url: entry['url']!, title: entry['title']!))
        .toList();

    // 3. Save fresh data to cache for the next boot
    try {
      final jsonList = freshVideos.map((v) => v.toJson()).toList();
      await prefs.setString(_cacheKey, jsonEncode(jsonList));
      await prefs.setInt(_cacheVersionKey, _cacheVersion);
      LoggerService.i('[VideoRepository] 🌐 Yielded ${freshVideos.length} production videos and updated cache');
    } catch (e) {
      LoggerService.e('[VideoRepository] Failed to encode cache: $e');
    }

    yield freshVideos;
  }
}
