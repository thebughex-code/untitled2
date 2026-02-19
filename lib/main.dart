import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'ui/splash_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to portrait and use light status-bar icons over the dark background.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  ));
  runApp(const ReelsApp());
}

class ReelsApp extends StatelessWidget {
  const ReelsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Reels',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const SplashScreen(),
    );
  }
}
