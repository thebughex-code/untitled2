import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../mvvm/model/video_model.dart';
import '../services/logger_service.dart';

class VideoRepository {
  static const String _cacheKey = 'cached_video_feed';

  /// Yields a stream of videos. 
  /// Pass 1 (0ms): Emits the cached feed from SharedPreferences instantly.
  /// Pass 2 (Network ms): Emits the fresh feed from the API and caches it.
  Stream<List<VideoModel>> fetchVideosStream() async* {
    final prefs = await SharedPreferences.getInstance();

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
        LoggerService.d('[VideoRepository] No cache found. Waiting for network...');
    }

    // 2. Network Pass (Background): Fetch fresh data
    // In a real app, this is where your Dio network call goes.
    await Future.delayed(const Duration(milliseconds: 600));

    final freshVideos = [
      VideoModel(
        url: 'http://sample.vodobox.net/skate_phantom_flex_4k/skate_phantom_flex_4k.m3u8',
        title: 'Skate Phantom 4K',
      ),
      VideoModel(
        url: 'http://playertest.longtailvideo.com/adaptive/wowzaid3/playlist.m3u8',
        title: 'Wowza ID3',
      ),
      VideoModel(
        url: 'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8',
        title: 'Tears of Steel',
      ),
    ];

    // 3. Save fresh network data back to Cache for the next app boot
    try {
      final jsonList = freshVideos.map((v) => v.toJson()).toList();
      await prefs.setString(_cacheKey, jsonEncode(jsonList));
      LoggerService.i('[VideoRepository] 🌐 Yielded ${freshVideos.length} NETWORK videos and updated cache');
    } catch (e) {
      LoggerService.e('[VideoRepository] Failed to encode cache: $e');
    }

    yield freshVideos;
  }
}
