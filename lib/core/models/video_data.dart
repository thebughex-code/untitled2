/// Model representing a video with its HLS manifest URL and display title.
class VideoData {
  final String url;
  final String title;

  const VideoData({required this.url, required this.title});

  /// 10 public HLS test streams that work on ExoPlayer/iOS (2026).
  static const List<VideoData> videos = [
    VideoData(
      url: 'http://sample.vodobox.net/skate_phantom_flex_4k/skate_phantom_flex_4k.m3u8',
      title: 'Skate Phantom 4K',
    ),
    VideoData(
      url: 'http://playertest.longtailvideo.com/adaptive/wowzaid3/playlist.m3u8',
      title: 'Wowza ID3',
    ),

    VideoData(
      url: 'https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8',
      title: 'Tears of Steel',
    ),
  ];
}
