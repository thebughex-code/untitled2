class VideoModel {
  final String url;
  final String title;

  VideoModel({
    required this.url,
    required this.title,
  });

  factory VideoModel.fromJson(Map<String, dynamic> json) {
    return VideoModel(
      url: json['url'] ?? '',
      title: json['title'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'title': title,
    };
  }
}
