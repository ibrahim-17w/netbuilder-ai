import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App settings. Gemini API key lives ONLY in secure storage, never in prefs/db/logs.
class SettingsService extends ChangeNotifier {
  static const _kKey = 'gemini_api_key';
  static const _kModel = 'gemini_model';
  static const _kPrivate = 'private_mode';
  static const _kGns3 = 'gns3_endpoint';
  static const _kGns3User = 'gns3_user';
  static const _kGns3Pass = 'gns3_pass';
  static const _kTarget = 'default_target';
  static const _kLlmFix = 'llm_fix_when_stuck';

  final FlutterSecureStorage _secure;
  SharedPreferences? _prefs;

  String _model = 'gemini-3.8-flash';
  bool _privateMode = false;
  bool _llmFix = true;
  String _gns3Endpoint = 'http://127.0.0.1:3080';
  String _gns3User = 'admin';
  String _gns3Pass = '';
  String _defaultTarget = 'gns3';
  bool _loaded = false;

  SettingsService({FlutterSecureStorage? secure})
    : _secure = secure ?? const FlutterSecureStorage();

  bool get loaded => _loaded;
  String get model => _model;
  bool get privateMode => _privateMode;
  bool get llmFix => _llmFix;
  String get gns3Endpoint => _gns3Endpoint;
  String get gns3User => _gns3User;
  String get gns3Pass => _gns3Pass;
  String get defaultTarget => _defaultTarget;

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
    // Auto-migrate retired models saved by older app versions.
    if (retiredModels.contains(saved) || !supportedModels.contains(saved)) {
      saved = 'gemini-3.8-flash';
      await _prefs!.setString(_kModel, saved);
    }
    _model = saved;
    _privateMode = _prefs!.getBool(_kPrivate) ?? false;
    _llmFix = _prefs!.getBool(_kLlmFix) ?? true;
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
    _loaded = true;
    notifyListeners();
  }

  Future<String?> getApiKey() => _secure.read(key: _kKey);

  Future<void> setApiKey(String v) async {
    final t = v.trim();
    if (t.isEmpty) {
      await _secure.delete(key: _kKey);
    } else {
      await _secure.write(key: _kKey, value: t);
    }
    notifyListeners();
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

  Future<void> setDefaultTarget(String v) async {
    _defaultTarget = v;
    await _prefs?.setString(_kTarget, v);
    notifyListeners();
  }
}
