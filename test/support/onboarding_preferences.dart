import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ignore: must_be_immutable
class DraftPreferences extends Fake implements SharedPreferencesAsync {
  final values = <String, String>{};
  bool failWrite = false;
  Completer<void>? writeGate;

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    await writeGate?.future;
    if (failWrite) throw StateError('Storage unavailable');
    values[key] = value;
  }
}
