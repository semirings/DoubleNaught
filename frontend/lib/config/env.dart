import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Checks [dotenv] environment first, falls back to [String.fromEnvironment],
/// then [Platform.environment], and finally returns [defaultValue].
String getEnvVar(String key, {String defaultValue = ''}) {
  try {
    final value = dotenv.env[key];
    if (value != null && value.isNotEmpty) {
      return value;
    }
  } catch (_) {}

  try {
    final value = String.fromEnvironment(key);
    if (value.isNotEmpty) {
      return value;
    }
  } catch (_) {}

  if (!kIsWeb) {
    try {
      final value = Platform.environment[key];
      if (value != null && value.isNotEmpty) {
        return value;
      }
    } catch (_) {}
  }
  return defaultValue;
}
