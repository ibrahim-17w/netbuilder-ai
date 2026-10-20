import 'package:package_info_plus/package_info_plus.dart';

/// The app's own version, read from the package metadata at startup.
///
/// `pubspec.yaml` is the build-time source of truth: Flutter stamps its
/// version into the Windows resource, the Android manifest and the installer.
/// [package_info_plus] reads those same stamped values at runtime, so the UI
/// never carries a second hard-coded release number that can drift.
class AppVersion {
  AppVersion._();

  /// Fallbacks for tests and for a client built without Flutter's build-name
  /// defines. They match the current pubspec and are replaced by
  /// [PackageInfo] on a real launch.
  static String version = const String.fromEnvironment(
    'FLUTTER_BUILD_NAME',
    defaultValue: '1.0.0',
  );
  static String buildNumber = const String.fromEnvironment(
    'FLUTTER_BUILD_NUMBER',
    defaultValue: '1',
  );

  /// `1.0.0+1` when a build number exists, otherwise just `1.0.0`.
  static String get full =>
      buildNumber.trim().isEmpty ? version : '$version+$buildNumber';

  /// Major version for the engine compatibility handshake. Returns 0 when
  /// the value is not a conventional numeric version.
  static int get major => _majorOf(version);

  static int _majorOf(String value) {
    final match = RegExp(r'^\s*(\d+)').firstMatch(value.trim());
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  /// A human-readable warning when [other] names a different major version.
  /// Null means "no comparison possible" or "compatible".
  static String? majorMismatch(String other) {
    final theirs = _majorOf(other);
    final ours = major;
    if (ours == 0 || theirs == 0 || ours == theirs) return null;
    return 'App v$version and engine v$other have different major versions. '
        'Update both before relying on this engine.';
  }

  /// Load the versions stamped into this build. Never throws: a missing
  /// plugin (tests, a headless build) keeps the compile-time fallbacks.
  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final name = info.version.trim();
      if (name.isNotEmpty) version = name;
      buildNumber = info.buildNumber.trim();
    } catch (_) {
      // Keep the build-time fallbacks.
    }
  }

  /// Tests that exercise the handshake set a deterministic version and put
  /// the real values back in a tearDown.
  static void overrideForTests({String? version, String? buildNumber}) {
    if (version != null) AppVersion.version = version;
    if (buildNumber != null) AppVersion.buildNumber = buildNumber;
  }

  static void resetForTests() {
    version = const String.fromEnvironment(
      'FLUTTER_BUILD_NAME',
      defaultValue: '1.0.0',
    );
    buildNumber = const String.fromEnvironment(
      'FLUTTER_BUILD_NUMBER',
      defaultValue: '1',
    );
  }
}
