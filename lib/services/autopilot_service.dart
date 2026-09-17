import 'dart:convert';
import 'package:http/http.dart' as http;

/// Talks to the local PT Autopilot sidecar (sidecar/pt_autopilot.py).
/// Sidecar runs on http://127.0.0.1:5005 and drives the PT window.
/// Flutter never clicks the OS directly; the sidecar does (Windows-only).
///
/// If the sidecar is not running you get a friendly SocketException hint,
/// NOT a raw ClientException dump.
class AutopilotService {
  final String base;
  final http.Client _client;
  AutopilotService({this.base = 'http://127.0.0.1:5005', http.Client? c})
    : _client = c ?? http.Client();

  static const startHint =
      'Sidecar not running on 127.0.0.1:5005.\n'
      '1) pip install -r sidecar/requirements.txt (once)\n'
      '2) python sidecar/pt_autopilot.py  (leave it running)\n'
      '3) Keep Packet Tracer open, maximized, focused, then retry.\n'
      'Or double-click sidecar/start_sidecar.bat';

  Future<bool> get healthy async {
    try {
      final j = await healthDetails();
      return j['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> healthDetails() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) {
        throw Exception('sidecar HTTP ${r.statusCode}: ${r.body}');
      }
      return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<String> start(Map<String, dynamic> plan) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/start'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(plan),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 409) {
        var activity = 'a job';
        var stopRequested = false;
        try {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          final rawActivity = body['activity'];
          if (rawActivity is Map) {
            final kind = rawActivity['kind'];
            if (kind != null && kind.toString().trim().isNotEmpty) {
              activity = kind.toString();
            }
            stopRequested = rawActivity['stopRequested'] == true;
          } else if (rawActivity != null &&
              rawActivity.toString().trim().isNotEmpty) {
            activity = rawActivity.toString();
          }
        } catch (_) {
          // Keep the useful generic message if an older sidecar returned
          // non-JSON for the conflict response.
        }
        throw Exception(
          'Sidecar busy: $activity is still active.'
          '${stopRequested ? ' Stop was already requested; wait for it to release.' : ' Press Stop and wait for the live status to become idle.'}',
        );
      }
      if (r.statusCode != 200) {
        throw Exception('Sidecar HTTP ${r.statusCode}: ${r.body}');
      }
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Visible mouse square over PT. If the user sees no movement,
  /// the problem is focus/permissions, not the plan.
  Future<String> prove() async {
    try {
      final r = await _client
          .post(Uri.parse('$base/prove'))
          .timeout(const Duration(seconds: 20));
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<Map<String, dynamic>> calGet() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/cal_get'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('cal ${r.statusCode}: ${r.body}');
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return Map<String, dynamic>.from(
        (j['cal'] as Map? ?? {}).map((k, v) => MapEntry(k.toString(), v)),
      );
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<String> calSet(Map<String, double> patch) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/cal_set'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(patch),
          )
          .timeout(const Duration(seconds: 10));
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Teach a CAL position: sidecar captures mouse after 3s.
  /// User hovers the exact PT icon, app polls Logs for result.
  Future<String> teach(String key) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/teach'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'key': key}),
          )
          .timeout(const Duration(seconds: 10));
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<Map<String, dynamic>> devicesGet(String project) async {
    try {
      final r = await _client
          .get(
            Uri.parse(
              '$base/devices_get?project=${Uri.encodeComponent(project)}',
            ),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('devices ${r.statusCode}: ${r.body}');
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return Map<String, dynamic>.from(
        (j['devices'] as Map? ?? {}).map((k, v) => MapEntry(k.toString(), v)),
      );
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<String> devicesClear(String project) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/devices_clear'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'project': project}),
          )
          .timeout(const Duration(seconds: 10));
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<String> inspect() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/inspect'))
          .timeout(const Duration(seconds: 25));
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<String> clickTest(String name) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/click_test'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'name': name}),
          )
          .timeout(const Duration(seconds: 20));
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<String> stop() async {
    try {
      final r = await _client
          .post(Uri.parse('$base/stop'))
          .timeout(const Duration(seconds: 10));
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Ask the active run to hold at the next safe boundary. Progress is
  /// kept; Stop remains the destructive action. F9 does the same globally.
  Future<Map<String, dynamic>> pause() async {
    return _pauseOperation('/pause');
  }

  /// Continue a paused run exactly where it stopped.
  Future<Map<String, dynamic>> resume() async {
    return _pauseOperation('/resume');
  }

  /// Flip pause state; returns {ok, state, pause{...}}.
  Future<Map<String, dynamic>> pauseToggle() async {
    return _pauseOperation('/pause_toggle');
  }

  Future<Map<String, dynamic>> _pauseOperation(String endpoint) async {
    try {
      final r = await _client
          .post(Uri.parse('$base$endpoint'))
          .timeout(const Duration(seconds: 10));
      final decoded = jsonDecode(r.body);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return {'ok': false, 'raw': r.body};
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Create a redacted, opt-in tester diagnostics archive locally.
  Future<Map<String, dynamic>> exportDiagnostics({
    bool includeScreenshots = false,
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/diagnostics/export'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'includeScreenshots': includeScreenshots}),
          )
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        throw Exception('diagnostics ${r.statusCode}: ${r.body}');
      }
      return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<String> status() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/status'))
          .timeout(const Duration(seconds: 10));
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Structured live activity state. Unlike the log text, this is the
  /// authoritative answer to whether the sidecar still owns Packet Tracer.
  Future<Map<String, dynamic>> statusDetails() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/status'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('status ${r.statusCode}: ${r.body}');
      }
      final decoded = jsonDecode(r.body);
      if (decoded is! Map) {
        throw Exception('status response was not an object');
      }
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Per-run counters from the last autopilot run (devices done/skipped,
  /// errors recovered/unrecovered, red links, admin heals, ...).
  Future<Map<String, dynamic>> runSummary() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/run_summary'))
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return Map<String, dynamic>.from(
        (j['summary'] as Map? ?? {}).map((k, v) => MapEntry(k.toString(), v)),
      );
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Hand the app's Gemini credential to the sidecar for this run only.
  /// The sidecar keeps it in memory: it is never written to disk or logged.
  Future<Map<String, dynamic>> pushLlmConfig({
    required String apiKey,
    required String model,
    required bool enabled,
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/llm_config'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'apiKey': apiKey,
              'model': model,
              'enabled': enabled,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('llm_config ${r.statusCode}: ${r.body}');
      }
      final decoded = jsonDecode(r.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Whether the sidecar currently holds a usable Gemini credential.
  /// Returns no key material, only the counters and flags.
  Future<Map<String, dynamic>> llmStatus() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/llm_status'))
          .timeout(const Duration(seconds: 10));
      final decoded = jsonDecode(r.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Latest live Packet Tracer inventory captured before the last run.
  Future<Map<String, dynamic>> inventory() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/inventory'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('inventory ${r.statusCode}: ${r.body}');
      }
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Structured sidecar experiences: failed actions plus successful
  /// recoveries that can be reused on future runs.
  Future<List<Map<String, dynamic>>> learningExperiences() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/learning'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('learning ${r.statusCode}: ${r.body}');
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return (j['experiences'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Live session learning plus safe persistent strategies. The sidecar
  /// updates this while a build is running, so the Memory screen can show
  /// corrections without waiting for the next session.
  Future<Map<String, dynamic>> learningMemory() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/learning'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('learning ${r.statusCode}: ${r.body}');
      }
      return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Aggregated failure journal across ALL runs: per-kind and
  /// per-signature hit/miss counts. This is the cross-run pattern layer.
  Future<Map<String, dynamic>> stats() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/stats'))
          .timeout(const Duration(seconds: 10));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Concrete rule suggestions distilled from recurring failure patterns
  /// (e.g. 'model click missed N runs in a row').
  Future<List<String>> suggestions() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/suggest'))
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return (j['suggestions'] as List? ?? [])
          .map((s) => s.toString())
          .toList();
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Raw journal tail (newest last).
  Future<List<Map<String, dynamic>>> events({int limit = 60}) async {
    try {
      final r = await _client
          .get(Uri.parse('$base/events?limit=$limit'))
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return (j['events'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<String> eventsClear() async {
    try {
      final r = await _client
          .post(Uri.parse('$base/events_clear'))
          .timeout(const Duration(seconds: 10));
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Kick off a network audit (read-only analysis of the already-built
  /// topology). Poll [auditReport] until running == false.
  Future<String> auditStart(String project) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/audit'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'project': project}),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 409) {
        throw Exception('Sidecar busy. Stop the current job first.');
      }
      if (r.statusCode != 200) {
        throw Exception('Audit HTTP ${r.statusCode}: ${r.body}');
      }
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Audit result: {running, report:{devices, red_dots, reachability, note...}}.
  Future<Map<String, dynamic>> auditReport() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/audit_report'))
          .timeout(const Duration(seconds: 10));
      return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Read a .pkt without modifying it. The sidecar returns file metadata,
  /// an optional NetBuilder companion manifest, and any matching live
  /// inventory. Packet Tracer remains authoritative for the opaque binary.
  Future<Map<String, dynamic>> pktRead(
    String path, {
    String project = 'default',
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/pkt/read'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'path': path, 'project': project}),
          )
          .timeout(const Duration(seconds: 15));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 || j['ok'] != true) {
        throw Exception(j['error'] ?? 'PKT read failed');
      }
      return Map<String, dynamic>.from((j['report'] as Map?) ?? const {});
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Open a .pkt after the sidecar makes a recoverable backup.
  Future<String> pktOpen(String path) async {
    return _pktOperation('/pkt/open', {'path': path});
  }

  /// Save the currently open Packet Tracer topology to a new .pkt. The
  /// destination must not already exist; this prevents accidental overwrite.
  Future<String> pktSaveAs(
    String path, {
    Map<String, dynamic>? manifest,
  }) async {
    return _pktOperation('/pkt/save_as', {
      'path': path,
      ...?(manifest == null ? null : {'manifest': manifest}),
    });
  }

  /// Reopen a saved .pkt without making another backup and verify that
  /// Packet Tracer becomes available. A live Analyze pass is still required
  /// to prove the loaded topology contents.
  Future<String> pktVerify(String path) async {
    return _pktOperation('/pkt/verify', {'path': path});
  }

  /// Save the live topology as a .pkt together with a companion manifest that
  /// records the plan and a planned-vs-recorded comparison, optionally
  /// reopening the file to prove Packet Tracer can load it. A green build run
  /// does this on its own; this is the manual equivalent. It runs in the
  /// background, so poll pktStatus() for the outcome and pktReport() for the
  /// artifact and its comparison.
  Future<String> pktSaveVerified({
    String project = 'default',
    String outDir = '',
    bool force = false,
    bool reopen = false,
  }) async {
    return _pktOperation('/pkt/save_verified', {
      'project': project,
      ...?(outDir.trim().isEmpty ? null : {'outDir': outDir}),
      'force': force,
      'reopen': reopen,
    });
  }

  /// The last saved artifact: its path, companion manifest and the
  /// planned-vs-recorded comparison. Null when nothing has been saved yet.
  Future<Map<String, dynamic>?> pktReport() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/pkt/report'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final report = j['report'];
      return report is Map ? Map<String, dynamic>.from(report) : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> pktStatus() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/pkt/status'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('PKT status ${r.statusCode}: ${r.body}');
      }
      return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  Future<String> _pktOperation(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base$endpoint'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 || j['ok'] != true) {
        throw Exception(j['error'] ?? 'Packet Tracer file operation failed');
      }
      return r.body;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') ||
        s.contains('Connection refused') ||
        s.contains('refused the network connection') ||
        s.contains('ClientException')) {
      return startHint;
    }
    return s;
  }
}
