import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release Android manifest does not allow cleartext traffic', () {
    final main = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      main,
      contains('android:usesCleartextTraffic="false"'),
      reason: 'release builds must not allow cleartext HTTP',
    );
    expect(
      main,
      isNot(contains('android:usesCleartextTraffic="true"')),
      reason: 'cleartext is a debug-only override',
    );
  });

  test('debug Android manifest opts in to cleartext for local development', () {
    final debug = File(
      'android/app/src/debug/AndroidManifest.xml',
    ).readAsStringSync();
    expect(debug, contains('android:usesCleartextTraffic="true"'));
    expect(
      debug,
      contains('tools:replace="android:usesCleartextTraffic"'),
      reason: 'the debug value must override the release value, not collide',
    );
  });
}
