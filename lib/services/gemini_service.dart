import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/network_intent.dart';

/// Minimal Gemini REST client (BYOK). No SDK download needed beyond `http`.
/// Docs: https://ai.google.dev/gemini-api/docs
/// Sep 2026: 2.x models retired. Use gemini-3.8-flash / gemini-3.6-flash.
/// Gemini 3 disallows temperature/top_p/top_k -> do not send them.
class GeminiService {
  final http.Client _client;
  GeminiService({http.Client? client}) : _client = client ?? http.Client();

  /// Stable hash of (instruction + target): the planner cache key. Identical
  /// asks reuse the stored plan instead of re-hitting the API. FNV-1a is
  /// enough here - the value stored under it is the plan itself, not a secret.
  static String briefKey(String instruction, String target) {
    var h = 0x811c9dc5;
    for (final unit in utf8.encode('$target\n\n$instruction')) {
      h ^= unit;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  static String _cacheKey(String instruction, String target) =>
      'planner_cache_${briefKey(instruction, target)}';

  /// Cached plan for a brief (null on miss). Set by [generateIntent] after a
  /// successful API call; cleared by [invalidateCachedPlan] when a build
  /// fails so the next attempt re-plans.
  static Future<NetworkIntent?> cachedPlan(
    String instruction,
    String target,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey(instruction, target));
      if (raw == null || raw.isEmpty) return null;
      final intent = NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      return intent.copyWith(planningSource: 'gemini-cache');
    } catch (_) {
      return null; // corrupt cache entries behave like a miss
    }
  }

  static Future<void> invalidateCachedPlan(
    String instruction,
    String target,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey(instruction, target));
    } catch (_) {}
  }

  static Future<void> _storeCachedPlan(
    String instruction,
    String target,
    NetworkIntent intent,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey(instruction, target),
        jsonEncode(intent.toJson(includeSecrets: false)),
      );
    } catch (_) {}
  }

  String _url(String model) =>
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';

  Map<String, String> _headers(String apiKey) => {
    'Content-Type': 'application/json',
    'x-goog-api-key': apiKey,
  };

  /// Returns null on success, error string otherwise. Never throws for bad key.
  Future<String?> testKey({
    required String apiKey,
    required String model,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) return 'Empty key. Paste one from aistudio.google.com.';
    try {
      final r = await _client
          .post(
            Uri.parse(_url(model)),
            headers: _headers(key),
            body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': 'Reply with the word OK.'},
                  ],
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) return null;
      return _friendlyError(r.statusCode, r.body, model);
    } catch (e) {
      return e.toString();
    }
  }

  /// List available models for this key (used for diagnostics).
  Future<List<String>> listModels(String apiKey) async {
    final r = await _client
        .get(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models'),
          headers: _headers(apiKey.trim()),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) {
      throw Exception(_friendlyError(r.statusCode, r.body, ''));
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final models = (j['models'] as List? ?? [])
        .map((m) => (m['name'] as String? ?? '').replaceFirst('models/', ''))
        .where((n) => n.isNotEmpty)
        .toList();
    return models;
  }

  /// Interpret plain English into the canonical network plan.
  /// Gemini is deliberately not allowed to generate executable CLI here.
  /// Deterministic adapters compile the returned plan for each target.
  Future<NetworkIntent> generateIntent({
    required String apiKey,
    required String model,
    required String instruction,
    required String contextBlock,
    required String target,
    required Map<String, dynamic> offlineCandidate,
  }) async {
    final safeInstruction = instruction.replaceAll(
      RegExp(
        r'((?:password|passwd|pass|pre[- ]shared key|secret)\s*[:=]?\s*)[^\s,.]+',
        caseSensitive: false,
      ),
      r'\1[REDACTED]',
    );
    final prompt =
        '''
You are NetBuilder's network-planning component, not its execution component.
Target: $target
User instruction: $safeInstruction

Use the offline candidate as a starting point, but correct it when the user's
request clearly requires something different:
${jsonEncode(offlineCandidate)}

Local knowledge (rules and prior outcomes - guidance only):
$contextBlock

Device types you may use (these are Packet Tracer device names, not ideas):
router, switch, pc, server, laptop, printer, firewall (ASA), wireless
(access point), wireless-router, wlc, phone (IP phone), tablet, smartphone,
tv, cloud, modem, iot.
Server roles for a "server" node: dhcp, dhcpv6, dns, http, ftp, email, aaa,
ntp, tftp, syslog, iot, snmp, vm.
Hard rules:
- a router-to-router WAN is Serial0/0/0 on both ends with "cable":"serial"
  and exactly ONE clocking end ("dce":"a", or the DCE device's name);
- wireless-only clients (tablet, smartphone, tv) are never given a cable;
- a firewall sits between the LAN and the internet/cloud; the app generates
  its ASA base config (inside/outside, inspection, routes) automatically, so
  place it and cable it - but never describe ASA syntax as IOS;
- only router and switch nodes get IOS CLI configuration;
- address router LAN interfaces with the first usable host (.1), put
  wired end devices at .10 onward of the same subnet, and never overlap
  subnets between links;
- EVERY pc, server, laptop and printer node MUST have exactly one
  addressing entry: the first endpoint on a LAN is .10 (never skip it),
  the next .11, and so on; the gateway for those devices is the router
  .1 on the same LAN (never .2, never 0.0.0.0);
- use the cable kind the interfaces demand: copper for LAN links,
  "copper-cross" for like-device links, "serial" where Serial ports
  carry the link, "fiber" only on fiber ports.

Return ONLY JSON with this shape:
{
  "projectName": "string",
  "nodes": [{"name":"R1","type":"router","model":"2911","services":[]}],
  "links": [{"a":"R1","aIf":"s0/0/0","b":"R2","bIf":"s0/0/0","cable":"serial","dce":"a"}],
  "addressing": [{"node":"R1","iface":"g0/0","ipCidr":"192.168.1.1/24"}],
  "vlans": [10],
  "routing": "static|ospf|eigrp|bgp|none",
  "notes": ["short implementation notes"],
  "assumptions": ["every choice not explicitly stated by the user"],
  "questions": ["only questions whose answer would materially change the plan"],
  "security": {
    "portSecurity": false,
    "dhcpSnooping": false,
    "dhcpTrustedInterface": "f0/1",
    "aaa": false,
    "aaaProtocol": "tacacs+",
    "aaaServer": "AAA1",
    "aaaRouter": "R1",
    "aaaUsername": "only when supplied",
    "aaaPassword": "only when supplied",
    "telnet": false,
    "managerIp": "only when supplied",
    "officeHours": "only when supplied",
    "extendedAcl": false,
    "branchNetwork": "CIDR",
    "protectedServerIp": "only when supplied",
    "allowedWebServerIp": "only when supplied",
    "ipsecVpn": false,
    "vpnPeerA": "IP",
    "vpnPeerB": "IP",
    "vpnEncryption": "aes",
    "vpnHash": "sha",
    "vpnPreSharedKey": "only when supplied",
    "vpnLocalNetwork": "CIDR",
    "vpnRemoteNetwork": "CIDR",
    "tests": ["plain-English checks the app must run after execution"]
  },
  "confidence": 0.0
}
Never invent credentials. Keep questions short. If the request is ambiguous,
make the safest reasonable plan and disclose the ambiguity in assumptions or
questions. The app will validate this plan before anything is executed.
''';
    final r = await _client
        .post(
          Uri.parse(_url(model)),
          headers: _headers(apiKey.trim()),
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': prompt},
                ],
              },
            ],
            'generationConfig': {'responseMimeType': 'application/json'},
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (r.statusCode != 200) {
      throw Exception(_friendlyError(r.statusCode, r.body, model));
    }
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    final cands = j['candidates'] as List?;
    if (cands == null || cands.isEmpty) {
      throw Exception('Gemini returned no candidates');
    }
    final content = cands.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      throw Exception('Gemini returned no parts');
    }
    final raw = (parts.first['text'] as String? ?? '').trim();
    if (raw.isEmpty) throw Exception('Gemini returned an empty network plan');
    try {
      final cleaned = raw
          .replaceFirst(RegExp(r'^```json\s*'), '')
          .replaceFirst(RegExp(r'^```\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '')
          .trim();
      final data = jsonDecode(cleaned) as Map<String, dynamic>;
      final candidateProject =
          (offlineCandidate['projectName'] as String?)?.trim() ?? 'net1';
      final modelProject = (data['projectName'] as String?)?.trim();
      final intent = NetworkIntent.fromJson(data);
      if (intent.nodes.isEmpty) {
        throw Exception('Gemini plan contains no devices');
      }
      final planned = intent.copyWith(
        projectName: modelProject == null || modelProject.isEmpty
            ? candidateProject
            : modelProject,
        planningSource: 'gemini',
      );
      // cache the successful plan: identical asks skip the API next time
      await _storeCachedPlan(instruction, target, planned);
      return planned;
    } on FormatException catch (e) {
      throw Exception('Gemini returned invalid plan JSON: ${e.message}');
    }
  }

  String _friendlyError(int code, String body, String model) {
    final short = _short(body);
    if (code == 404 && model.isNotEmpty) {
      return 'HTTP 404: model "$model" not available for this key. '
          'Pick gemini-3.8-flash (or gemini-3.6-flash) in Settings. Server: $short';
    }
    if (code == 400 && short.contains('API key not valid')) {
      return 'HTTP 400: API key not valid. Create a new one at aistudio.google.com -> Get API key. Server: $short';
    }
    if (code == 403) {
      return 'HTTP 403: key forbidden / billing not enabled. Check AI Studio project. Server: $short';
    }
    return 'HTTP $code: $short';
  }

  String _short(String s) => s.length > 500 ? '${s.substring(0, 500)}...' : s;
}
