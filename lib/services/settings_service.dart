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
  static const _kGns3User = 'gns3_user';
  static const _kGns3Pass = 'gns3_pass';
  static const _kTarget = 'default_target';
  static const _kLlmFix = 'llm_fix_when_stuck';
  static const _kContext = 'context_budget';
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

  /// True when this build is running on a phone or tablet.
  ///
  /// Guarded because a unit test can run without a real platform underneath.
  static bool get isMobile {
    try {
      return Platform.isAndroid || Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  /// True when the platform is Android specifically, which is the only one
  /// where the emulator's host alias applies.
  static bool get isAndroid {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

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
  String get gns3Endpoint => _gns3Endpoint;
  String get gns3User => _gns3User;
  String get gns3Pass => _gns3Pass;
  String get defaultTarget => _defaultTarget;
  int get contextBudget => _contextBudget;
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
    _liveContext = _prefs!.getBool(_kLiveContext) ?? true;
    _themeMode = _prefs!.getString(_kThemeMode) ?? _themeMode;
    _gns3Endpoint = _prefs!.getString(_kGns3) ?? _gns3Endpoint;
    // Migrate older plaintext GNS3 credentials into secure storage.
    final oldUser = _prefs!.getString(_kGns3User);
    final oldPass = _prefs!.getString(_kGns3Pass);
    final secureUser = await _secure.read(key: _kGns3User);
    final securePass = await _secure.read(key: _kGns3Pass);
    _gns3User = secureUser ?? oldUser ?? _gns3User;
    _gns3Pass = securePass ?? oldPass ?? _gns3Pass;
    if (oldUser != null) {
      if (secureUser == null) {
        await _secure.write(key: _kGns3User, value: oldUser);
      }
      await _prefs!.remove(_kGns3User);
    }
    if (oldPass != null) {
      if (securePass == null) {
        await _secure.write(key: _kGns3Pass, value: oldPass);
      }
      await _prefs!.remove(_kGns3Pass);
    }
    _defaultTarget = _prefs!.getString(_kTarget) ?? _defaultTarget;
    _contextBudget = _prefs!.getInt(_kContext) ?? _contextBudget;
    await _loadInstallInfo();
    _lastProject = _prefs!.getString(_kLastProject) ?? _lastProject;
    _tourDone = _prefs!.getBool(_kTourDone) ?? false;
    _seenChangelog = _prefs!.getString(_kSeenChangelog) ?? '';
    _engineBase = _prefs!.getString(_kEngineBase) ?? _engineBase;
    // A choice the user made always wins; otherwise a fresh install uses the
    // folders the installer created, so the app works without anyone typing a
    // path or editing a file.
    _outputDir = _prefs!.getString(_kOutputDir) ??
        (_installInfo['outputDir'] ?? '').toString().trim();

    final installedEngine =
        (_installInfo['engineBase'] ?? '').toString().trim();
    if (installedEngine.isNotEmpty && !_prefs!.containsKey(_kEngineBase)) {
      _engineBase = installedEngine;
    }
    _loaded = true;
    notifyListeners();
  }

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
  Future<void> setContextBudget(int v) async {
    _contextBudget = v.clamp(8192, 1048576);
    await _prefs?.setInt(_kContext, _contextBudget);
    notifyListeners();
  }

  /// Point the app at the machine running the offline engine. Accepts
  /// 'host', 'host:port' or a full http(s) URL.
  Future<void> setEngineBase(String value) async {
    var v = value.trim();
    if (v.isEmpty) return;
    if (!v.contains('://')) {
      v = 'http://$v';
    }
    if (!RegExp(r':\d+$').hasMatch(v)) {
      v = '$v:5005';
    }
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    _engineBase = v;
    await _prefs?.setString(_kEngineBase, _engineBase);
    notifyListeners();
  }

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
