import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

/// Simple printer for iOS that outputs plain text without ANSI codes.
/// Xcode console doesn't support ANSI escape sequences.
class SimplePrinter extends LogPrinter {
  @override
  List<String> log(LogEvent event) {
    final dateTime = DateTime.now();
    final formattedTime = DateFormat('HH:mm:ss.SSS').format(dateTime);
    final levelName = event.level.name.toUpperCase().padRight(5);
    final emoji = _getEmoji(event.level);
    final message = event.message;
    
    final List<String> lines = ['$emoji [$formattedTime] [$levelName] $message'];
    
    if (event.error != null) {
      lines.add('  ERROR: ${event.error}');
    }
    if (event.stackTrace != null) {
      lines.add('  STACK: ${event.stackTrace.toString().split('\n').take(5).join('\n  ')}');
    }
    
    return lines;
  }
  
  String _getEmoji(Level level) {
    switch (level) {
      case Level.trace: return '💜';
      case Level.debug: return '🌀';
      case Level.info: return '🩵';
      case Level.warning: return '⚠️';
      case Level.error: return '⛔';
      default: return '🔥';
    }
  }
}

class CustomPrinter extends LogPrinter {
  final PrettyPrinter _prettyPrinter;

  CustomPrinter()
      : _prettyPrinter = PrettyPrinter(
          methodCount: 0, // Reduced method count for cleaner logs
          errorMethodCount: 8,
          lineLength: 120,
          colors: true,
          printEmojis: true,
          excludeBox: const {},
          noBoxingByDefault: false,
          excludePaths: const [],
          levelColors: {
            Level.trace: AnsiColor.fg(93), 
            Level.debug: AnsiColor.fg(200), 
            Level.info: AnsiColor.fg(200), 
            Level.warning: AnsiColor.fg(214), 
            Level.error: AnsiColor.fg(197), 
            Level.fatal: AnsiColor.fg(200), 
          },
          levelEmojis: {
            Level.trace: '💜 ',
            Level.debug: '🌀 ',
            Level.info: '🩵 ',
            Level.warning: '⚡ ',
            Level.error: '⛔ ',
            Level.fatal: '🔥 ',
          },
        );

  @override
  List<String> log(LogEvent event) {
    // PrettyPrinter adds boxing, we just want the inner content often, 
    // but the user requested this specific implementation.
    // However, the user's mapped output: `return output.map(...)`.
    // PrettyPrinter returns a list of lines.
    final output = _prettyPrinter.log(event);
    final dateTime = DateTime.now();
    final formattedTime = DateFormat('dd-MM-yyyy hh:mm:ss a').format(dateTime);
    final levelName = event.level.name.toUpperCase();
    
    // We prepend timestamp to each line, or just the first?
    // User code: `return output.map((line) => ...).toList();`
    // This prepends it to EVERY line of the box which might look weird but we follow instructions.
    return output
        .map((line) => '[📅 $formattedTime] [$levelName] $line')
        .toList();
  }
}

class LoggerService {
  LoggerService._();

  /// Use SimplePrinter on iOS (Xcode doesn't support ANSI colors).
  /// Use CustomPrinter with colors on Android/other platforms.
  static final Logger _logger = Logger(
    filter: ProductionFilter(), // Log everything in release mode too if needed, or use DevelopmentFilter
    printer: Platform.isIOS ? SimplePrinter() : CustomPrinter(),
    level: kDebugMode ? Level.trace : Level.warning,
  );

  static Logger get instance => _logger;

  static void d(dynamic message, {Object? error, StackTrace? stackTrace}) {
    if (kDebugMode) _logger.d(message, error: error, stackTrace: stackTrace);
  }

  static void i(dynamic message, {Object? error, StackTrace? stackTrace}) {
    if (kDebugMode) _logger.i(message, error: error, stackTrace: stackTrace);
  }

  static void w(dynamic message, {Object? error, StackTrace? stackTrace}) {
    if (kDebugMode) _logger.w(message, error: error, stackTrace: stackTrace);
  }

  static void e(dynamic message, {Object? error, StackTrace? stackTrace}) {
    if (kDebugMode) _logger.e(message, error: error, stackTrace: stackTrace);
    
    // Log to Crashlytics
    try {
      if (Firebase.apps.isNotEmpty) {
        FirebaseCrashlytics.instance.recordError(
          error ?? Exception(message.toString()), 
          stackTrace, 
          reason: message.toString(), 
          fatal: false
        );
      }
    } catch (_) {}
  }

  static void v(dynamic message, {Object? error, StackTrace? stackTrace}) {
    if (kDebugMode) _logger.t(message, error: error, stackTrace: stackTrace); // v -> trace
  }

  static void wtf(dynamic message, {Object? error, StackTrace? stackTrace}) {
    if (kDebugMode) _logger.f(message, error: error, stackTrace: stackTrace); // wtf -> fatal

    // Log fatal to Crashlytics
    try {
      if (Firebase.apps.isNotEmpty) {
        FirebaseCrashlytics.instance.recordError(
          error ?? Exception(message.toString()), 
          stackTrace, 
          reason: message.toString(), 
          fatal: true
        );
      }
    } catch (_) {}
  }
}
