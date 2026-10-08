import 'dart:io';

/// Whether Cisco Packet Tracer exists on this machine.
///
/// The chat hands a built `.pkt` to the operating system and the `.pkt` file
/// association routes it - but on a machine with no Packet Tracer, `start`
/// pops a "how do you want to open this?" dialog (or quietly does nothing),
/// which reads as the app being broken. Detecting the app is what lets the
/// chat route the click honestly: Packet Tracer when it is there, the
/// built-in topology viewer when it is not.
///
/// Detection runs three checks, cheapest first, and any one counts:
///
/// 1. the Windows **App Paths** registry key Packet Tracer registers
///    (`HKLM`, then `HKCU` for per-user installs);
/// 2. a `PacketTracer.exe` under `C:\Program Files*\Cisco Packet Tracer *\`
///    - the layout every recent installer uses;
/// 3. a **`.pkt` file association** (`assoc .pkt`), which is what the OS
///    open actually relies on: if the machine opens `.pkt` with something,
///    handing it the file will work.
///
/// macOS and Linux fall back to well-known install locations and `which`.
class PacketTracerLocator {
  /// Injected for tests: stands in for [Process.run].
  final Future<ProcessResult> Function(String executable, List<String> args)?
  runProcess;

  /// Injected for tests: forces which platform branch runs regardless of
  /// the real one. Null means use [Platform].
  final String? forcePlatform;

  /// Injected for tests: lists a directory's entries (the program-files
  /// glob and macOS Applications check).
  final List<FileSystemEntity> Function(String path)? listDir;

  /// Injected for tests: whether a path exists.
  final bool Function(String path)? exists;

  PacketTracerLocator({
    this.runProcess,
    this.forcePlatform,
    this.listDir,
    this.exists,
  });

  static final PacketTracerLocator instance = PacketTracerLocator();

  bool? _cached;

  /// True when Packet Tracer (or at least a working `.pkt` association) was
  /// found. Computed once per process and remembered: the answer does not
  /// change while the app is open, and a registry probe per click would be
  /// waste.
  Future<bool> isInstalled() async {
    if (_cached != null) return _cached!;
    _cached = await _detect();
    return _cached!;
  }

  /// The test seam: forget the cached answer (call between scenarios).
  void resetForTest() => _cached = null;

  Future<bool> _detect() async {
    final platform = forcePlatform ?? _platformName();
    switch (platform) {
      case 'windows':
        return _detectWindows();
      case 'macos':
        return _detectMacos();
      case 'linux':
        return _detectLinux();
    }
    // Phones and web: there is no Packet Tracer to find.
    return false;
  }

  String _platformName() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'other';
  }

  Future<bool> _detectWindows() async {
    // App Paths is what "open with" resolves through for registered apps.
    for (final hive in ['HKLM', 'HKCU']) {
      final r = await _run('reg', [
        'query',
        '$hive\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\'
            'PacketTracer.exe',
        '/ve',
      ]);
      if (r != null && r.exitCode == 0) return true;
    }
    // The installer's directory layout: C:\Program Files\Cisco Packet
    // Tracer 8.2.2\bin\PacketTracer.exe (and the x86 variant).
    if (_globProgramFiles()) return true;
    // Last signal: does the OS itself know what a .pkt is? If an
    // association exists, `start file.pkt` opens whatever claims it.
    final assoc = await _run('cmd', ['/c', 'assoc', '.pkt']);
    if (assoc != null &&
        assoc.exitCode == 0 &&
        assoc.stdout.toString().trim().isNotEmpty) {
      return true;
    }
    return false;
  }

  bool _globProgramFiles() {
    final isThere = exists ?? defaultExists;
    final entries = listDir;
    for (final root in const [r'C:\Program Files', r'C:\Program Files (x86)']) {
      if (!isThere(root)) continue;
      try {
        final dirs = entries != null
            ? entries(root)
            : Directory(root).listSync();
        for (final d in dirs) {
          if (d is! Directory) continue;
          final name = d.path.split(Platform.pathSeparator).last;
          if (!name.toLowerCase().startsWith('cisco packet tracer')) continue;
          final exe =
              '${d.path}${Platform.pathSeparator}bin'
              '${Platform.pathSeparator}PacketTracer.exe';
          if (isThere(exe)) return true;
        }
      } catch (_) {
        // An unreadable Program Files is not evidence of anything.
      }
    }
    return false;
  }

  Future<bool> _detectMacos() async {
    final isThere = exists ?? defaultExists;
    final list = listDir;
    const apps = '/Applications';
    try {
      final dirs = list != null ? list(apps) : Directory(apps).listSync();
      for (final d in dirs) {
        final name = d.path.split('/').last.toLowerCase();
        if (name.startsWith('packet tracer')) return true;
      }
    } catch (_) {}
    return isThere('$apps/Packet Tracer.app');
  }

  Future<bool> _detectLinux() async {
    final r = await _run('which', ['packettracer']);
    if (r != null && r.exitCode == 0) return true;
    return (exists ?? defaultExists)('/opt/pt/PacketTracer');
  }

  /// The default existence check, injected out of the way in tests.
  static bool defaultExists(String path) => FileSystemEntity.typeSync(path) !=
      FileSystemEntityType.notFound;

  /// One subprocess, never throwing: a missing `reg` or a shell that will
  /// not start is "not found", not a crash.
  Future<ProcessResult?> _run(String executable, List<String> args) async {
    try {
      final run = runProcess ?? Process.run;
      return await run(executable, args);
    } catch (_) {
      return null;
    }
  }
}
