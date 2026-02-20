import 'package:get/get.dart';

import '../bindings/home_binding.dart';
import '../mvvm/view/home_screen.dart';
import '../mvvm/view/splash_screen.dart';
import 'app_routes.dart';

class AppPages {
  AppPages._();

  static const INITIAL = Routes.SPLASH;

  static final routes = [
    GetPage(
      name: Routes.SPLASH,
      page: () => const SplashScreen(),
    ),
    GetPage(
      name: Routes.HOME,
      page: () => HomeScreen(),
      binding: HomeBinding(),
    ),
  ];
}
