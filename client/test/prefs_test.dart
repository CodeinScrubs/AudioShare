import 'dart:io';

import 'package:audioshare/utils/prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory storage;

  setUp(() {
    storage = Directory.systemTemp.createTempSync('audioshare-prefs-test-');
    Prefs.useStorageDirectoryForTesting(storage);
  });

  tearDown(() {
    Prefs.useStorageDirectoryForTesting(null);
    if (storage.existsSync()) storage.deleteSync(recursive: true);
  });

  test('persists preferences and reloads them', () {
    Prefs.setString('device', 'phone-1');
    Prefs.setBool('auto', true);

    Prefs.useStorageDirectoryForTesting(storage);
    Prefs.load();

    expect(Prefs.getString('device'), 'phone-1');
    expect(Prefs.getBool('auto'), isTrue);
    expect(Prefs.lastError, isNull);
  });

  test('recovers the previous generation when the primary file is corrupt', () {
    Prefs.setString('device', 'phone-1');
    Prefs.setString('device', 'phone-2');

    File(
      '${storage.path}${Platform.pathSeparator}prefs.json',
    ).writeAsStringSync('{broken');
    Prefs.useStorageDirectoryForTesting(storage);
    Prefs.load();

    expect(Prefs.getString('device'), 'phone-1');
    expect(Prefs.lastError, contains('Recovered AudioShare preferences'));

    Prefs.useStorageDirectoryForTesting(storage);
    Prefs.load();
    expect(Prefs.getString('device'), 'phone-1');
  });

  test('clears stale in-memory values when both generations are invalid', () {
    Prefs.setString('device', 'phone-1');
    Prefs.setString('device', 'phone-2');
    File(
      '${storage.path}${Platform.pathSeparator}prefs.json',
    ).writeAsStringSync('[]');
    File(
      '${storage.path}${Platform.pathSeparator}prefs.json.bak',
    ).writeAsStringSync('{broken');

    Prefs.load();

    expect(Prefs.getString('device'), isEmpty);
    expect(Prefs.lastError, contains('Could not load AudioShare preferences'));
  });
}
