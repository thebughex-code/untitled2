import 'package:get/get.dart';

import '../repository/video_repository.dart';

class InitialBinding extends Bindings {
  @override
  void dependencies() {
    // Inject the VideoRepository here so it is available app-wide
    // and easily swappable for testing.
    Get.put<VideoRepository>(VideoRepository(), permanent: true);
  }
}
