import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/app_version.dart';
import 'package:net_builder/widgets/whats_new.dart';

/// `pubspec.yaml` is the one version a release build is stamped from: Flutter
/// writes it into the Windows resource (which the installer carries), the
/// Android manifest, and package_info_plus. The changelog and the resource
/// fallback must not drift into a second opinion.
void main() {
  test('pubspec, changelog, and Windows installer resource agree', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([^\s#]+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no version: line');
    final pubVersion = match!.group(1)!;
    final release = pubVersion.split('+').first;

    expect(
      kChangelogEntries,
      isNotEmpty,
      reason: 'the in-app changelog must name the current release',
    );
    expect(
      kChangelogEntries.first.version,
      release,
      reason: 'whats_new.dart latest entry must equal pubspec version',
    );

    final runner = File('windows/runner/Runner.rc').readAsStringSync();
    final rc = RegExp(
      r'#define\s+VERSION_AS_STRING\s+"([^"]+)"',
    ).firstMatch(runner);
    expect(rc, isNotNull, reason: 'Runner.rc has no VERSION_AS_STRING');
    expect(
      rc!.group(1),
      release,
      reason: 'the Windows resource fallback must equal pubspec version',
    );

    // The runtime display comes from package_info_plus. The compile-time
    // fallback (used by tests and headless builds) has to point at the same
    // release or a mismatch would only show up after packaging.
    expect(AppVersion.version, release);
    expect(pubspec, contains('package_info_plus:'));
  });
}
