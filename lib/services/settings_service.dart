import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_provider.dart';
import 'context_budget.dart';

/// App settings. Gemini API key lives ONLY in secure storage, never in prefs/db/logs.
class SettingsService extends ChangeNotifier {
  static const _kKey = 'gemini_api_key';
  static const _kModel = 'gemini_model';
  static const _kOpenAiKey = 'openai_api_key';
  static const _kProvider = 'ai_provider';
  static const _kOpenAiBase = 'openai_base_url';
  static const _kOpenAiModel = 'openai_model';
  static const _kOpenAiHeaders = 'openai_headers';
  static const _kOpenAiOrg = 'openai_organization';
  static const _kPrivate = 'private_mode';
  static const _kGns3 = 'gns3_endpoint';
  static const _kAutoLearn = 'auto_learn_enabled';
  static const _kAutoSuggest = 'auto_learn_suggest_after_run';
  static const _kAutoTeach = 'auto_learn_auto_teach';
  static const _kGns3User = 'gns3_user';
  static const _kGns3Pass = 'gns3_pass';
  static const _kTarget = 'default_target';
  static const _kLlmFix = 'llm_fix_when_stuck';
  static const _kContext = 'context_budget';
  static const _kRuntimeWindow = 'runtime_window';
  static const _kContextDebug = 'context_debug';
  static const _kLastProject = 'last_project';
  static const _kEngineBase = 'engine_base';
  static const _kOutputDir = 'output_dir';
  static const _kLiveContext = 'live_context';
  static const _kThemeMode = 'theme_mode';
  static const _kTourDone = 'first_run_tour_done';
  static const _kSeenChangelog = 'seen_changelog_version';

  final FlutterSecureStorage _secure;
  SharedPreferences? _prefs;

  // The old default (`gemini-3.8-flash`) is not a model Google serves, so a
  // stock install failed with a 404. This is a current one; the field stays
  // free-text so a future release never needs an app update.
  String _model = AiProviderConfig.defaultGeminiModel;
  String _provider = 'gemini';
  String _openAiBase = 'https://api.groq.com/openai/v1';
  String _openAiModel = 'llama-3.3-70b-versatile';
  String _openAiHeaders = '';
  String _openAiOrg = '';
  bool _privateMode = false;
  bool _llmFix = true;
  /// Auto-learning: with these on, the engine proposes, verifies and settles
  /// corrections on its own after a run with recurring failures - no button
  /// press.  Every promotion still has to pass the verify-before-promote
  /// gate; these only control whether the engine bothers to try.
  bool _autoLearn = true;
  bool _autoSuggest = true;
  bool _autoTeach = true;
  /// Whether the live run summary is included in the prompt. It used to be a
  /// chip on the chat screen; it is a preference, so it lives here.
  bool _liveContext = true;
  /// 'system' | 'light' | 'dark'. A preference rather than a constant: the
  /// app is read for hours, and which theme is comfortable is not something
  /// the operating system should decide for everyone.
  String _themeMode = 'system';
  String _gns3Endpoint = defaultGns3Endpoint();
  String _gns3User = 'admin';
  String _gns3Pass = '';
  String _defaultTarget = 'gns3';
  // The chat's context ceiling. Documented in one place
  // (ContextBudget.defaultContextTokens ~= 256k) and editable in Settings.
  int _contextBudget = ContextBudget.defaultContextTokens;
  /// The runtime's own context window, when the user knows it better than the
  /// probe does. 0 = detect it (the default), which is what makes the chat
  /// work without anyone configuring anything.
  int _runtimeWindow = 0;
  /// Print every assembled request with its token breakdown. Off by default:
  /// this is a development view, not something a user needs.
  bool _contextDebug = false;
  String _lastProject = 'default';
  // First-run tour + changelog tracking. The tour shows once; the changelog
  // card reappears whenever the app version changes.
  bool _tourDone = false;
  String _seenChangelog = '';
  // Where the offline .pkt engine lives. On a desktop that is the local
  // sidecar; on a phone it is the PC running that sidecar (the device has
  // no Python), so this is a real setting rather than a constant.
  String _engineBase = defaultEngineBase();
  // Where generated and fixed .pkt files are written. Empty = the engine's
  // own default (sidecar/pkt_output), so nothing breaks when unset.
  String _outputDir = '';
  bool _loaded = false;

  /// Secure storage, configured so a key written on Android is still there
  /// after the app is closed and reopened.
  ///
  /// `encryptedSharedPreferences` selects the modern Android implementation
  /// rather than the legacy keystore path, and `resetOnError` means a value
  /// that cannot be decrypted (a restored backup that arrived without its
  /// keystore key, a rotated signing key) is cleared instead of throwing
  /// into the boot path - which is what made a saved key look like it had
  /// silently vanished.
  static const FlutterSecureStorage _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
  );

  /// Where the installer's install.json lives, when it is not beside the
  /// executable. Only tests set this.
  final String? _installConfigPathOverride;

  SettingsService({
    FlutterSecureStorage? secure,
    String? installConfigPath,
  }) : _secure = secure ?? _defaultStorage,
       _installConfigPathOverride = installConfigPath;

  /// What the installer recorded for this machine: the folders it created and
  /// the addresses it decided on. Empty when the app was not installed.
  Map<String, dynamic> _installInfo = const {};
  Map<String, dynamic> get installInfo => _installInfo;
  bool get installedWithSetup => _installInfo.isNotEmpty;

  /// True when the stored key exists but could not be decrypted. The settings
  /// screen says so plainly instead of looking like nothing was ever saved.
  bool _keyUnreadable = false;
  bool get keyUnreadable => _keyUnreadable;

  /// Set by tests that need to be a phone.
  ///
  /// Deliberately not `defaultTargetPlatform`: the widget-test binding reports
  /// that as android for every test, which would quietly turn the whole suite
  /// into phone tests. The real platform cannot be changed inside a test
  /// process, so the phone paths need an explicit switch - and they are worth
  /// covering, because the phone is the platform with no engine and no Python.
  @visibleForTesting
  static bool? mobileOverrideForTests;

  /// True when this build is running on a phone or tablet.
  static bool get isMobile {
    final forced = mobileOverrideForTests;
    if (forced != null) return forced;
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  /// True when the platform is Android specifically, which is the only one
  /// where the emulator's host alias applies.
  static bool get isAndroid {
    if (mobileOverrideForTests == true) return true;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// True when this platform can host the .pkt engine itself.
  ///
  /// The engine is a Python sidecar that drives a Packet Tracer window: it
  /// needs a desktop OS and a process the app can start. On a phone it does not
  /// exist, so this is what stops the app from looking for Python it will
  /// never find and reporting the failure as if it were the user's fault.
  static bool get canHostEngine => !isMobile;

  /// Where the offline `.pkt` engine listens, by default.
  ///
  /// On a desktop the sidecar runs beside the app, so loopback is right. On a
  /// phone, `127.0.0.1` is the *phone* - the sidecar lives on a PC - so
  /// defaulting to loopback guaranteed a "Sidecar not running" message no
  /// matter what the user did with the app. That was the whole of the
  /// "does not work on Android" report.
  ///
  /// A phone cannot discover the PC's address on its own, so this is a
  /// starting point the user corrects, not a guess pretending to be a
  /// solution: an Android emulator reaches its host at 10.0.2.2, and a real
  /// phone needs the PC's LAN address entered in Settings.
  static String defaultEngineBase() {
    if (isAndroid) return 'http://10.0.2.2:5005';
    return 'http://127.0.0.1:5005';
  }

  /// The port the engine listens on when the address does not name one.
  static const defaultEnginePort = 5005;

  /// Turn whatever the user (or an installer) typed into a usable base URL.
  ///
  /// One place does this, because getting it wrong in one caller is how
  /// `http://host:5005/` and `host` ended up becoming two different
  /// addresses for the same machine. Whitespace, a missing scheme, a missing
  /// port and a trailing slash are all settled here.
  ///
  /// Returns null for input that cannot be a base URL at all (an empty
  /// string, a scheme http cannot use), so the caller can keep the last good
  /// address instead of saving something that can never answer.
  static String? normalizeEngineBase(String? value) {
    var v = (value ?? '').trim();
    if (v.isEmpty) return null;

    // A scheme, if present, must be one an HTTP client can actually use.
    var scheme = 'http';
    final schemeSplit = v.indexOf('://');
    if (schemeSplit >= 0) {
      scheme = v.substring(0, schemeSplit).toLowerCase();
      if (scheme != 'http' && scheme != 'https') return null;
      v = v.substring(schemeSplit + 3);
    }

    // Only the authority is the engine's base; a path, query or fragment
    // typed by accident is dropped rather than becoming part of every URL.
    for (final stop in const ['/', '?', '#']) {
      final at = v.indexOf(stop);
      if (at >= 0) v = v.substring(0, at);
    }
    v = v.trim();
    if (v.isEmpty) return null;

    // Split the authority into host and port. An IPv6 literal is bracketed,
    // so a colon inside it is not a port separator.
    var host = v;
    var port = '';
    if (v.startsWith('[')) {
      final close = v.indexOf(']');
      if (close < 0) return null;
      host = v.substring(0, close + 1);
      final rest = v.substring(close + 1);
      if (rest.isNotEmpty) {
        if (!rest.startsWith(':')) return null;
        port = rest.substring(1);
      }
    } else {
      final colon = v.lastIndexOf(':');
      if (colon >= 0) {
        host = v.substring(0, colon);
        port = v.substring(colon + 1);
      }
    }
    host = host.trim();
    if (host.isEmpty) return null;
    if (port.isNotEmpty) {
      final parsed = int.tryParse(port);
      if (parsed == null || parsed < 1 || parsed > 65535) return null;
    }
    return '$scheme://$host:${port.isEmpty ? '$defaultEnginePort' : port}';
  }

  /// Same rules, for a call that must produce an address. An unusable
  /// value falls back rather than becoming a dead end.
  static String engineBaseOr(String? value, {String? fallback}) {
    return normalizeEngineBase(value) ??
        normalizeEngineBase(fallback) ??
        defaultEngineBase();
  }

  /// Whether the address names this machine.
  ///
  /// One source of truth, because "may the app start an engine for this?" and
  /// "is this the address I told the user to start one on?" have to agree. An
  /// unparseable address counts as local: a bad value is a settings problem,
  /// and refusing to launch on top of it would hide the real message.
  static bool isLoopbackEngineBase(String base) {
    final host = Uri.tryParse(engineBaseOr(base))?.host.toLowerCase() ?? '';
    if (host.isEmpty) return true;
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '0.0.0.0' ||
        host.endsWith('.localhost');
  }

  /// Same reasoning for GNS3, which is also a desktop service.
  static String defaultGns3Endpoint() {
    if (isAndroid) return 'http://10.0.2.2:3080';
    return 'http://127.0.0.1:3080';
  }

  /// A one-line explanation of what the current default means, shown next to
  /// the field so the emulator alias cannot be mistaken for the phone's own
  /// address.
  static String engineHint(String current) {
    final t = current.trim();
    if (t.contains('10.0.2.2')) {
      return '10.0.2.2 is the Android emulator\'s name for the PC that is '
          'running it. On a real phone, replace it with that PC\'s LAN '
          'address, e.g. http://192.168.1.20:5005.';
    }
    if (t.contains('127.0.0.1') || t.contains('localhost')) {
      return isMobile
          ? '127.0.0.1 means this phone itself, which runs no sidecar. Use '
                'the PC\'s LAN address instead, e.g. http://192.168.1.20:5005.'
          : 'Loopback is right when the sidecar runs on this same machine.';
    }
    return 'The app calls this address for every .pkt job. Tap Test to check '
        'it answers.';
  }

  /// Read the installer's record, if this machine has one.
  ///
  /// Never throws: an unreadable or absent file just means the app falls back
  /// to its own defaults, which is what happens in a dev checkout.
  Future<void> _loadInstallInfo() async {
    final file = _installConfigFile();
    if (file == null) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        _installInfo = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      _installInfo = const {};
    }
  }

  File? _installConfigFile() {
    final override = _installConfigPathOverride;
    if (override != null && override.trim().isNotEmpty) {
      final file = File(override.trim());
      return file.existsSync() ? file : null;
    }
    try {
      final dir = File(Platform.resolvedExecutable).parent.path;
      final found = File(
        '$dir${Platform.pathSeparator}config'
        '${Platform.pathSeparator}install.json',
      );
      if (found.existsSync()) return found;
    } catch (_) {
      // A platform without an executable path has no install record.
    }
    return null;
  }

  bool get loaded => _loaded;
  String get model => _model;
  bool get liveContext => _liveContext;
  Future<void> setLiveContext(bool value) async {
    _liveContext = value;
    await _prefs?.setBool(_kLiveContext, value);
    notifyListeners();
  }
  String get themeMode => _themeMode;
  Future<void> setThemeMode(String value) async {
    _themeMode = const ['system', 'light', 'dark'].contains(value)
        ? value
        : 'system';
    await _prefs?.setString(_kThemeMode, _themeMode);
    notifyListeners();
  }
  String get providerName => _provider;
  bool get usesOpenAi => _provider == 'openai';
  String get openAiBaseUrl => _openAiBase;
  String get openAiModel => _openAiModel;
  String get openAiHeaders => _openAiHeaders;
  String get openAiOrganization => _openAiOrg;

  /// Everything the chat needs to reach the active provider.
  AiProviderConfig get providerConfig => AiProviderConfig(
    kind: usesOpenAi ? AiProviderKind.openai : AiProviderKind.gemini,
    model: usesOpenAi ? _openAiModel : _model,
    baseUrl: _openAiBase,
    organization: _openAiOrg,
    extraHeaders: parseHeaders(_openAiHeaders),
  );

  /// `Header: value` per line - the shape a gateway's docs give you.
  static Map<String, String> parseHeaders(String raw) {
    final out = <String, String>{};
    for (final line in raw.split('\n')) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final k = line.substring(0, i).trim();
      final v = line.substring(i + 1).trim();
      if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
    }
    return out;
  }
  bool get privateMode => _privateMode;
  bool get llmFix => _llmFix;
  bool get autoLearn => _autoLearn;
  bool get autoSuggest => _autoSuggest;
  bool get autoTeach => _autoTeach;
  String get gns3Endpoint => _gns3Endpoint;
  String get gns3User => _gns3User;
  String get gns3Pass => _gns3Pass;
  String get defaultTarget => _defaultTarget;
  int get contextBudget => _contextBudget;
  int get runtimeWindow => _runtimeWindow;
  bool get contextDebug => _contextDebug;
  String get lastProject => _lastProject;
  String get engineBase => _engineBase;
  String get outputDir => _outputDir;

  /// True once the user has seen (or dismissed) the first-run feature tour.
  bool get tourDone => _tourDone;
  Future<void> markTourDone() async {
    _tourDone = true;
    await _prefs?.setBool(_kTourDone, true);
    notifyListeners();
  }

  /// The changelog version the user last saw, so a new version can surface
  /// its changes exactly once.
  String get seenChangelog => _seenChangelog;
  Future<void> markChangelogSeen(String version) async {
    _seenChangelog = version;
    await _prefs?.setString(_kSeenChangelog, version);
    notifyListeners();
  }

  // Updated Sep 2026: 2.x models retired (404). 3.x Flash is current.
  // See https://ai.google.dev/gemini-api/docs/models
  static const supportedModels = [
    'gemini-3.8-flash',
    'gemini-3.6-flash',
    'gemini-2.5-flash',
    'gemini-1.5-flash',
  ];

  static const retiredModels = ['gemini-2.0-flash', 'gemini-1.5-pro'];

  static const supportedTargets = [
    'gns3',
    'cisco-ssh',
    'packet-tracer',
    'aws-vpc',
  ];

  Future<void> load() async {
    _prefs ??= await SharedPreferences.getInstance();
    var saved = _prefs!.getString(_kModel) ?? _model;
    // Only migrate models the provider has actually RETIRED. The old code
    // also rewrote anything missing from the suggestion list - which is why
    // a newer model ("above the suggested ones") was silently replaced by
    // `gemini-3.8-flash`, a name Google does not serve, and every call
    // failed with a 404. A model the user typed is now left alone.
    if (retiredModels.contains(saved)) {
      saved = AiProviderConfig.defaultGeminiModel;
      await _prefs!.setString(_kModel, saved);
    }
    _model = saved;
    _provider = _prefs!.getString(_kProvider) ?? _provider;
    _openAiBase = _prefs!.getString(_kOpenAiBase) ?? _openAiBase;
    _openAiModel = _prefs!.getString(_kOpenAiModel) ?? _openAiModel;
    _openAiHeaders = _prefs!.getString(_kOpenAiHeaders) ?? _openAiHeaders;
    _openAiOrg = _prefs!.getString(_kOpenAiOrg) ?? _openAiOrg;
    _privateMode = _prefs!.getBool(_kPrivate) ?? false;
    _llmFix = _prefs!.getBool(_kLlmFix) ?? true;
    _autoLearn = _prefs!.getBool(_kAutoLearn) ?? true;
    _autoSuggest = _prefs!.getBool(_kAutoSuggest) ?? true;
    _autoTeach = _prefs!.getBool(_kAutoTeach) ?? true;
    _liveContext = _prefs!.getBool(_kLiveContext) ?? true;
    _themeMode = _prefs!.getString(_kThemeMode) ?? _themeMode;
    _gns3Endpoint = _prefs!.getString(_kGns3) ?? _gns3Endpoint;
    // Migrate older plaintext GNS3 credentials into secure storage.
    //
    // Each read stands on its own: secure storage is one dependency with many
    // ways to fail on a device, and a single unreadable value used to throw
    // out of load() and take every OTHER setting with it - which is how a
    // broken keystore could look like the whole configuration was lost.
    final oldUser = _prefs!.getString(_kGns3User);
    final oldPass = _prefs!.getString(_kGns3Pass);
    final secureUser = await _readSecure(_kGns3User);
    final securePass = await _readSecure(_kGns3Pass);
    _gns3User = secureUser ?? oldUser ?? _gns3User;
    _gns3Pass = securePass ?? oldPass ?? _gns3Pass;
    if (oldUser != null) {
      if (secureUser == null) {
        await _writeSecure(_kGns3User, oldUser);
      }
      await _prefs!.remove(_kGns3User);
    }
    if (oldPass != null) {
      if (securePass == null) {
        await _writeSecure(_kGns3Pass, oldPass);
      }
      await _prefs!.remove(_kGns3Pass);
    }
    _defaultTarget = _prefs!.getString(_kTarget) ?? _defaultTarget;
    _contextBudget = _prefs!.getInt(_kContext) ?? _contextBudget;
    _runtimeWindow = _prefs!.getInt(_kRuntimeWindow) ?? 0;
    _contextDebug = _prefs!.getBool(_kContextDebug) ?? false;
    await _loadInstallInfo();
    _lastProject = _prefs!.getString(_kLastProject) ?? _lastProject;
    _tourDone = _prefs!.getBool(_kTourDone) ?? false;
    _seenChangelog = _prefs!.getString(_kSeenChangelog) ?? '';
    // A saved address is normalized on the way in, so a value that predates
    // these rules (or was written by hand) becomes the address the app will
    // actually call.
    _engineBase = engineBaseOr(
      _prefs!.getString(_kEngineBase),
      fallback: _engineBase,
    );
    // A choice the user made always wins; otherwise a fresh install uses the
    // folders the installer created, so the app works without anyone typing a
    // path or editing a file.
    _outputDir = _prefs!.getString(_kOutputDir) ??
        (_installInfo['outputDir'] ?? '').toString().trim();

    if (!_prefs!.containsKey(_kEngineBase)) {
      final installedEngine = (_installInfo['engineBase'] ?? '').toString();
      final fromInstaller = normalizeEngineBase(installedEngine);
      if (fromInstaller != null) _engineBase = fromInstaller;
    }
    _loaded = true;
    notifyListeners();
  }

  /// A secure read that reports rather than throws.
  ///
  /// [loadError] is deliberately a fixed sentence: the exception text from a
  /// platform keystore can carry the key it failed on, and this string is
  /// shown in the settings UI and written into bug reports.
  Future<String?> _readSecure(String key) async {
    try {
      return await _secure.read(key: key);
    } catch (_) {
      _loadError = 'Some saved credentials could not be read from secure '
          'storage on this device. Everything else was loaded; re-enter the '
          'credentials to store them again.';
      return null;
    }
  }

  Future<void> _writeSecure(String key, String value) async {
    try {
      await _secure.write(key: key, value: value);
    } catch (_) {
      _loadError = 'Some credentials could not be written to secure storage '
          'on this device. Everything else was saved.';
    }
  }

  /// Why a load could not be completed in full, in words safe to show. Empty
  /// when everything loaded.
  String get loadError => _loadError;
  String _loadError = '';

  /// The stored Gemini key, or null.
  ///
  /// This must never throw: it runs while the app starts, and an exception
  /// there is exactly what made a saved key appear to have disappeared. An
  /// unreadable value is cleared so the next save can succeed, and the fact
  /// that it happened is remembered for the settings screen to explain.
  Future<String?> getApiKey() async {
    try {
      final value = await _secure.read(key: _kKey);
      _keyUnreadable = false;
      final t = value?.trim() ?? '';
      return t.isEmpty ? null : value;
    } catch (_) {
      _keyUnreadable = true;
      try {
        await _secure.delete(key: _kKey);
      } catch (_) {
        // Nothing further we can do here; the user is asked to re-enter it.
      }
      return null;
    }
  }

  /// Store the Gemini key and confirm it reads back.
  ///
  /// Returns true only when the value survived the round trip, so the UI never
  /// says "saved" about a write that did not stick.
  Future<bool> setApiKey(String v) async {
    final t = v.trim();
    try {
      if (t.isEmpty) {
        await _secure.delete(key: _kKey);
        _keyUnreadable = false;
        notifyListeners();
        return true;
      }
      await _secure.write(key: _kKey, value: t);
      final back = await _secure.read(key: _kKey);
      final ok = back != null && back == t;
      // A write that cannot be read back is not a saved key, whatever the
      // write call reported.
      _keyUnreadable = !ok;
      notifyListeners();
      return ok;
    } catch (_) {
      _keyUnreadable = true;
      notifyListeners();
      return false;
    }
  }

  Future<void> setModel(String v) async {
    _model = v;
    await _prefs?.setString(_kModel, v);
    notifyListeners();
  }

  Future<void> setPrivateMode(bool v) async {
    _privateMode = v;
    await _prefs?.setBool(_kPrivate, v);
    notifyListeners();
  }

  Future<void> setLlmFix(bool v) async {
    _llmFix = v;
    await _prefs?.setBool(_kLlmFix, v);
    notifyListeners();
  }

  /// Master switch for engine-driven learning.  Off means the app never lets
  /// the sidecar propose or verify by itself; the manual buttons still work.
  Future<void> setAutoLearn(bool v) async {
    _autoLearn = v;
    await _prefs?.setBool(_kAutoLearn, v);
    notifyListeners();
  }

  /// Whether a failing run may trigger a suggest pass on its own.
  Future<void> setAutoSuggest(bool v) async {
    _autoSuggest = v;
    await _prefs?.setBool(_kAutoSuggest, v);
    notifyListeners();
  }

  /// Whether a proposed correction may be verified by an automatic teach run.
  Future<void> setAutoTeach(bool v) async {
    _autoTeach = v;
    await _prefs?.setBool(_kAutoTeach, v);
    notifyListeners();
  }

  Future<void> setGns3Endpoint(String v) async {
    _gns3Endpoint = v.trim();
    await _prefs?.setString(_kGns3, _gns3Endpoint);
    notifyListeners();
  }

  Future<void> setGns3Credentials(String user, String pass) async {
    _gns3User = user.trim();
    _gns3Pass = pass.trim();
    await _secure.write(key: _kGns3User, value: _gns3User);
    if (_gns3Pass.isEmpty) {
      await _secure.delete(key: _kGns3Pass);
    } else {
      await _secure.write(key: _kGns3Pass, value: _gns3Pass);
    }
    await _prefs?.remove(_kGns3User);
    await _prefs?.remove(_kGns3Pass);
    notifyListeners();
  }

  /// Move the chat's context ceiling. Clamped to a sane range so a typo
  /// cannot ask for a 2-token or 100-million-token window.
  ///
  /// This is a CEILING, not a promise: the request is fitted to the smaller of
  /// this and the runtime's real window, so setting 1,024k on a runtime that
  /// allocates 4k changes nothing except the number in Settings.
  Future<void> setContextBudget(int v) async {
    _contextBudget = v.clamp(2048, 1048576);
    await _prefs?.setInt(_kContext, _contextBudget);
    notifyListeners();
  }

  /// Pin the runtime's context window instead of probing for it. 0 = detect.
  Future<void> setRuntimeWindow(int v) async {
    _runtimeWindow = v <= 0 ? 0 : v.clamp(512, 1048576);
    await _prefs?.setInt(_kRuntimeWindow, _runtimeWindow);
    notifyListeners();
  }

  Future<void> setContextDebug(bool v) async {
    _contextDebug = v;
    await _prefs?.setBool(_kContextDebug, v);
    notifyListeners();
  }

  /// Point the app at the machine running the offline engine. Accepts
  /// 'host', 'host:port' or a full http(s) URL, and settles whitespace,
  /// scheme, port and trailing slash through the same rules the loader uses.
  ///
  /// An address that could never be called (an ftp:// scheme, a missing
  /// host) is rejected rather than stored: the previous address stays, and
  /// [engineBaseError] says why, because silently keeping a bad value would
  /// make the app look broken at a place the user never typed.
  Future<void> setEngineBase(String value) async {
    final v = normalizeEngineBase(value);
    if (v == null) {
      _engineBaseError = value.trim().isEmpty
          ? 'Enter an engine address, for example 192.168.1.20:5005.'
          : '"${value.trim()}" is not an address the app can call. Use a host '
              'or host:port, optionally with http:// or https://.';
      notifyListeners();
      return;
    }
    _engineBaseError = '';
    _engineBase = v;
    await _prefs?.setString(_kEngineBase, _engineBase);
    notifyListeners();
  }

  /// Why the last [setEngineBase] was refused. Empty when the last one was
  /// accepted.
  String get engineBaseError => _engineBaseError;
  String _engineBaseError = '';

  /// The folder every generated / fixed .pkt is saved to. Empty restores
  /// the engine's default folder.
  Future<void> setOutputDir(String value) async {
    _outputDir = value.trim();
    await _prefs?.setString(_kOutputDir, _outputDir);
    notifyListeners();
  }

  /// Which backend the chat talks to: 'gemini' or 'openai'.
  Future<void> setProviderName(String value) async {
    _provider = value == 'openai' ? 'openai' : 'gemini';
    await _prefs?.setString(_kProvider, _provider);
    notifyListeners();
  }

  Future<void> setOpenAiBaseUrl(String value) async {
    _openAiBase = value.trim();
    await _prefs?.setString(_kOpenAiBase, _openAiBase);
    notifyListeners();
  }

  Future<void> setOpenAiModel(String value) async {
    if (value.trim().isEmpty) return;
    _openAiModel = value.trim();
    await _prefs?.setString(_kOpenAiModel, _openAiModel);
    notifyListeners();
  }

  Future<void> setOpenAiHeaders(String value) async {
    _openAiHeaders = value.trim();
    await _prefs?.setString(_kOpenAiHeaders, _openAiHeaders);
    notifyListeners();
  }

  Future<void> setOpenAiOrganization(String value) async {
    _openAiOrg = value.trim();
    await _prefs?.setString(_kOpenAiOrg, _openAiOrg);
    notifyListeners();
  }

  /// The OpenAI-compatible key, kept apart from the Gemini one.
  Future<String?> getOpenAiKey() async {
    try {
      return await _secure.read(key: _kOpenAiKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> setOpenAiKey(String value) async {
    try {
      await _secure.write(key: _kOpenAiKey, value: value.trim());
      notifyListeners();
    } catch (_) {}
  }

  /// Remember the conversation the user was last in, so the app reopens
  /// where they left off.
  Future<void> setLastProject(String v) async {
    _lastProject = v.trim().isEmpty ? 'default' : v.trim();
    await _prefs?.setString(_kLastProject, _lastProject);
    notifyListeners();
  }

  Future<void> setDefaultTarget(String v) async {
    _defaultTarget = v;
    await _prefs?.setString(_kTarget, v);
    notifyListeners();
  }
}
