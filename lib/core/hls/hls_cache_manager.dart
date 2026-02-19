import 'package:flutter/foundation.dart';

import 'preload_manager.dart';
import 'video_preload_manager.dart';
import 'proxy_server.dart';
import 'segment_cache.dart';

/// Top-level singleton that owns the cache, proxy server, and preload manager.
///
/// Call [init] once (e.g. from the splash screen) before using any other
/// method.
class HlsCacheManager {
  // ---------------------------------------------------------------------------
  // Singleton
  // ---------------------------------------------------------------------------
  static final HlsCacheManager _instance = HlsCacheManager._internal();
  static HlsCacheManager get instance => _instance;
  HlsCacheManager._internal();

  // ---------------------------------------------------------------------------
  // Components
  // ---------------------------------------------------------------------------
  late final SegmentCache cache;
  late final ProxyServer proxyServer;
  late final PreloadManager preloadManager;

  bool _initialized = false;
  bool get isInitialized => _initialized;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Initialise the cache directory, start the local proxy, and create the
  /// preload manager.  Safe to call multiple times (no-op after first init).
  Future<void> init() async {
    if (_initialized) return;

    cache = SegmentCache();
    await cache.init();

    proxyServer = ProxyServer(cache: cache);
    await proxyServer.start();
    
    // Relative URLs in ManifestParser now handle port changes, so we persist cache.
    // await cache.clear(); 

    preloadManager = PreloadManager(
      proxyServer: proxyServer,
      preloadSegmentCount: 1,
      slidingWindowSize: 2,
    );

    // Initialize the advanced VideoPreloadManager
    VideoPreloadManager.instance.setProxy(proxyServer);

    _initialized = true;
    debugPrint('[HlsCacheManager] initialised – proxy on ${proxyServer.baseUrl}');
  }

  /// Build the URL the video player should load for a given original HLS
  /// manifest URL.
  String getProxiedUrl(String originalUrl) {
    return proxyServer.getProxiedManifestUrl(originalUrl);
  }

  /// Tear everything down.
  Future<void> dispose() async {
    await proxyServer.stop();
    _initialized = false;
  }
}
