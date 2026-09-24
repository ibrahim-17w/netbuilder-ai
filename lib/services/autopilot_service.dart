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

  /// Shown when nothing answers. The app starts the engine itself, so this
  /// is the fallback for the case where it could not (no Python, wrong
  /// address, or the engine is on another machine).
  static const startHint =
      'Sidecar not running on 127.0.0.1:5005.\n'
      'The app starts it automatically when it can; if that failed:\n'
      '1) install Python 3 from python.org (tick "Add python.exe to PATH")\n'
      '2) pip install -r sidecar/requirements.txt (once)\n'
      '3) python sidecar/pt_autopilot.py  (leave it running)\n'
      '4) Keep Packet Tracer open, maximized, focused, then retry.\n'
      'Or double-click sidecar/start_sidecar.bat';

  /// How long a health check may take. Loopback answers in milliseconds, so
  /// a long wait here only ever means "the engine is not there" - and that
  /// must not be paid for on every screen that shows engine state.
  static const healthTimeout = Duration(milliseconds: 1800);

  Future<bool> get healthy async {
    try {
      final j = await healthDetails();
      return j['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> healthDetails({
    Duration timeout = healthTimeout,
  }) async {
    try {
      final r = await _client
          .get(Uri.parse('$base/health'))
          .timeout(timeout);
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

  /// Deep offline audit of a saved .pkt: services, VLANs, AAA + findings.
  Future<Map<String, dynamic>> pktDeepAudit(
    String path, {
    String project = '',
  }) async {
    return _pktPost('/pkt/deep_audit', {'path': path, 'project': project});
  }

  /// Diff two saved .pkt files.
  Future<Map<String, dynamic>> pktDiff(String pathA, String pathB) async {
    return _pktPost('/pkt/diff', {'pathA': pathA, 'pathB': pathB});
  }

  /// Grade a saved .pkt against a target plan.
  Future<Map<String, dynamic>> pktGrade(
    String path,
    Map<String, dynamic> plan,
  ) async {
    return _pktPost('/pkt/grade', {'path': path, 'plan': plan});
  }

  Future<Map<String, dynamic>> _pktPost(
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));
      final j = jsonDecode(r.body);
      if (j is! Map || j['ok'] != true) {
        throw Exception(
          (j is Map ? j['error'] as String? : null) ??
              '$path ${r.statusCode}: ${r.body}',
        );
      }
      return Map<String, dynamic>.from(j['report'] as Map);
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// What WOULD be tested for this plan (offline; no Packet Tracer).
  Future<List<Map<String, dynamic>>> verifyDerive(
    Map<String, dynamic> plan,
  ) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/verify/derive'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'plan': plan}),
          )
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body);
      if (j is! Map || j['ok'] != true) {
        throw Exception('verify/derive ${r.statusCode}: ${r.body}');
      }
      return ((j['tests'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Kick off LIVE post-build verification in Packet Tracer. Poll
  /// [verifyReport] until `running` is false.
  Future<void> verifyRun(Map<String, dynamic> plan) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/verify/run'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'plan': plan}),
          )
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body);
      if (j is! Map || j['ok'] != true) {
        throw Exception(
          (j['error'] as String?) ?? 'verify/run ${r.statusCode}: ${r.body}',
        );
      }
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Latest verification report (null while nothing has run yet).
  Future<Map<String, dynamic>?> verifyReport() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/verify/report'))
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body);
      if (j is! Map) return null;
      final rep = j['report'];
      return rep is Map ? Map<String, dynamic>.from(rep) : null;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Offline dry-run: walk the plan against PT constraints without touching
  /// the UI. Instant, no focus steal - returns actions + warnings + summary.
  Future<Map<String, dynamic>> dryRun(Map<String, dynamic> plan) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/dry_run'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'plan': plan}),
          )
          .timeout(const Duration(seconds: 30));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 || j['ok'] != true) {
        throw Exception(j['error'] ?? 'dry run failed');
      }
      return Map<String, dynamic>.from(j);
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

  /// Ask the sidecar to run one AI suggest+evaluate pass: Gemini proposes
  /// fixes for the journal's recurring failures and a second Gemini call
  /// judges each proposal. Runs outside any build - nothing is typed and
  /// nothing is promoted; accepted label/skip proposals only become
  /// `proposed` corrections a teach run must still verify on screen.
  Future<Map<String, dynamic>> aiSuggest({String project = ''}) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/ai_suggest'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'project': project}),
          )
          .timeout(const Duration(seconds: 10));
      final decoded = jsonDecode(r.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Poll the suggest pass: `running` while in flight, `last.proposals`
  /// with per-proposal `score`/`concern`/`correctionId` once finished.
  Future<Map<String, dynamic>> aiSuggestStatus() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/ai_suggest'))
          .timeout(const Duration(seconds: 10));
      final decoded = jsonDecode(r.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Start ONE bounded teach run for a proposed correction (the sidecar's
  /// POST /teach). The run re-attempts the step with the correction armed
  /// as a one-shot override and promotes it only if the screen verifies it.
  Future<Map<String, dynamic>> teachCorrection({
    required String correctionId,
    required String store,
    required String key,
    required List<Map<String, dynamic>> steps,
    String? project,
    String mode = 'fixes',
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/teach'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'correctionId': correctionId,
              'store': store,
              'key': key,
              'mode': mode,
              if (project != null && project.isNotEmpty)
                'project': project,
              'steps': steps,
            }),
          )
          .timeout(const Duration(seconds: 10));
      final decoded = jsonDecode(r.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// The teaching loop's read side: pending, stale and thrash corrections
  /// plus the taxonomy the UI uses to decide what is correctable.
  Future<Map<String, dynamic>> corrections() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/corrections'))
          .timeout(const Duration(seconds: 10));
      final decoded = jsonDecode(r.body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Un-teach a correction: removes the entry it promoted (when it is still
  /// taught) and marks the row reverted. The way back out of a stale fix.
  Future<Map<String, dynamic>> revertCorrection(String correctionId) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/corrections/revert'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'id': correctionId}),
          )
          .timeout(const Duration(seconds: 10));
      final decoded = jsonDecode(r.body);
      if (decoded is! Map || decoded['ok'] != true) {
        throw Exception(
          decoded is Map && decoded['error'] != null
              ? decoded['error']
              : 'revert HTTP ${r.statusCode}',
        );
      }
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// Teaching-loop corrections, shaped for the UI.  `stale` rows are
  /// user-taught entries that stopped verifying (reported, never dropped);
  /// `rejected` are hypotheses a teach run disproved.  A sidecar that is
  /// offline or older than the teaching loop degrades to empty lists - the
  /// badges just stay hidden, never an error dialog.
  Future<CorrectionSnapshot> correctionSnapshot() async {
    try {
      final j = await corrections();
      return CorrectionSnapshot.fromJson(j);
    } catch (_) {
      return const CorrectionSnapshot.empty();
    }
  }

  /// The last teach run's verdicts: promoted / rejected / pending per
  /// correction id.  This is what lets a proposal badge say "verified",
  /// "rejected: ?why?" or "awaiting teach run" instead of a bare dot.
  Future<TeachRunSnapshot> teachRunSnapshot() async {
    try {
      final j = await statusDetails();
      return TeachRunSnapshot.fromJson(j);
    } catch (_) {
      return const TeachRunSnapshot.empty();
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

  /// Recurring UNRECOVERED failure signatures from the sidecar's journal,
  /// plus this project's repeat offenders from its run ledger.
  ///
  /// This is the planner's failure signal. Before it existed the only
  /// cross-run input was the last ten attempt summaries ordered by recency,
  /// so a step that had already failed forty runs straight looked exactly
  /// like a fresh one - which is why the same prompt kept getting stuck at
  /// the same point.
  Future<Map<String, dynamic>> knownBlockers({String project = ''}) async {
    final query = project.trim().isEmpty
        ? ''
        : '?project=${Uri.encodeQueryComponent(project.trim())}';
    try {
      final r = await _client
          .get(Uri.parse('$base/suggest$query'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('suggest ${r.statusCode}: ${r.body}');
      }
      return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// [knownBlockers] rendered as prompt-ready one-liners. Best-effort: an
  /// unreachable sidecar yields an empty list rather than blocking a plan.
  Future<List<String>> blockerLines({String project = ''}) async {
    try {
      final body = await knownBlockers(project: project);
      return (body['blockerLines'] as List? ?? [])
          .map((e) => e.toString())
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Feature families Packet Tracer has actually proven it cannot do.
  /// Best-effort, like [blockerLines].
  Future<List<String>> provenUnsupported() async {
    try {
      final body = await knownBlockers();
      return (body['capabilities'] as List? ?? [])
          .whereType<Map>()
          .map((row) {
            final family = row['family']?.toString() ?? '';
            final model = row['model']?.toString() ?? 'any';
            final reason = row['reason']?.toString() ?? '';
            if (family.isEmpty) return '';
            return '- $family on $model'
                '${reason.isEmpty ? '' : ' ($reason)'}';
          })
          .where((line) => line.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Evidence screenshots the runs have already written, newest first.
  /// These are what the chat attaches to look at the real pixels.
  ///
  /// `/shots` has always returned a plain list of names; it now also carries
  /// `details` with size and time. An older sidecar is still readable, so the
  /// name list is the fallback rather than an error.
  Future<List<Map<String, dynamic>>> shots() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/shots'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        throw Exception('shots ${r.statusCode}: ${r.body}');
      }
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      final details = (j['details'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (details.isNotEmpty) return details;
      return (j['shots'] as List? ?? [])
          .map((e) => <String, dynamic>{'name': e.toString()})
          .toList();
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// One screenshot as base64 PNG. Read-only; '' when it is not available.
  Future<Map<String, dynamic>> shot(String name) async {
    if (name.trim().isEmpty) return const {};
    try {
      final r = await _client
          .get(
            Uri.parse(
              '$base/shot?name=${Uri.encodeQueryComponent(name.trim())}',
            ),
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return const {};
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return j['ok'] == true
          ? Map<String, dynamic>.from(j)
          : const <String, dynamic>{};
    } catch (_) {
      return const {};
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

  /// Build a .pkt straight from a plan - no Packet Tracer, no GUI run.
  /// The sidecar compiles the same plan the executor drives the screen with
  /// into a save file via its offline generator. Poll pktStatus() for the
  /// long-running UI operations; this returns the finished report directly.
  Future<Map<String, dynamic>> pktGenerate(
    Map<String, dynamic> plan, {
    String project = '',
    String filename = '',
    bool replace = false,
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/pkt/generate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'plan': plan,
              ...?(project.trim().isEmpty ? null : {'project': project}),
              ...?(filename.trim().isEmpty ? null : {'filename': filename}),
              'replace': replace,
            }),
          )
          .timeout(const Duration(seconds: 60));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 || j['ok'] != true) {
        throw Exception(j['error'] ?? 'PKT generate failed');
      }
      return Map<String, dynamic>.from((j['report'] as Map?) ?? const {});
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// OFFLINE audit of a saved .pkt: the sidecar reads the file directly -
  /// no Packet Tracer, no windows, no clicks. Findings are advice only;
  /// service panels, pings and canvas indicators are runtime state and are
  /// not visible to it.
  Future<Map<String, dynamic>> pktAudit(
    String path, {
    String project = 'default',
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/pkt/audit'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'path': path, 'project': project}),
          )
          .timeout(const Duration(seconds: 30));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 || j['ok'] != true) {
        throw Exception(j['error'] ?? 'PKT audit failed');
      }
      return Map<String, dynamic>.from((j['report'] as Map?) ?? const {});
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// POST helper for the offline .pkt endpoints: JSON in, JSON out, and a
  /// sidecar `ok: false` becomes a readable exception rather than a crash.
  /// Ask the engine whether an approved fix actually cleared its finding
  /// (spec §9). Read-only: it compares two audits and changes nothing.
  Future<Map<String, dynamic>> verifyRepair({
    required Map<String, dynamic> before,
    required Map<String, dynamic> after,
    required List<Map<String, dynamic>> fixes,
  }) async {
    final res = await _postJson(
      '/tools/call',
      {
        'name': 'verify_repair',
        'args': {'before': before, 'after': after, 'fixes': fixes},
      },
      timeoutSeconds: 60,
    );
    final result = res['result'];
    return result is Map
        ? Map<String, dynamic>.from(result)
        : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    int timeoutSeconds = 60,
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base$path'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(Duration(seconds: timeoutSeconds));
      final decoded = jsonDecode(r.body);
      if (decoded is! Map) {
        throw Exception('$path returned something that is not JSON');
      }
      final map = Map<String, dynamic>.from(decoded);
      if (map['ok'] != true) {
        throw Exception(
          (map['error'] ?? 'the sidecar refused that request').toString(),
        );
      }
      return map;
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// What IS this file? Asked before auditing so a wrong format gets a
  /// plain explanation instead of a decode failure.
  Future<Map<String, dynamic>> pktIdentify(String path) =>
      _postJson('/pkt/identify', {'path': path}, timeoutSeconds: 20);

  /// Apply ONLY the approved fixes to a .pkt and encrypt a valid save again.
  /// The source file is never modified, and Packet Tracer is not involved.
  Future<Map<String, dynamic>> pktApplyFixes(
    Map<String, dynamic> request,
  ) => _postJson('/pkt/apply_fixes', request, timeoutSeconds: 120);

  /// Record a rejection - the approval gate's audit trail. Nothing is
  /// written, exported or changed by this call.
  Future<Map<String, dynamic>> pktReject(
    Map<String, dynamic> fix, {
    String capture = '',
  }) => _postJson('/pkt/reject', {
    'fix': fix,
    'decision': 'rejected',
    'capture': capture,
  });

  /// Undo an applied change: restores the save from before that change.
  Future<Map<String, dynamic>> pktUndo({String entryId = ''}) =>
      _postJson('/pkt/undo', {'entryId': entryId});

  /// The audit ledger: every capture, decision, applied change and export.
  Future<Map<String, dynamic>> pktLedger({int limit = 200}) async {
    final r = await _postJson('/pkt/ledger', {'limit': limit});
    return Map<String, dynamic>.from((r['report'] as Map?) ?? const {});
  }

  /// Extend the sidecar's template library with every model found in local
  /// .pkt files (Packet Tracer's own sample saves by default).
  ///
  /// This is what makes a plan's requested model real instead of a
  /// nearest-match substitution: a machine that has never saved a 2911 or an
  /// ASA picks those blocks up from the samples PT ships with.
  Future<Map<String, dynamic>> pktTemplatesHarvest({
    List<String> roots = const [],
    bool samples = true,
    String outDir = '',
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/pkt/templates/harvest'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'roots': roots,
              'samples': samples,
              ...?(outDir.trim().isEmpty ? null : {'outDir': outDir}),
            }),
          )
          .timeout(const Duration(seconds: 600));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 || j['ok'] != true) {
        throw Exception(j['error'] ?? 'Model harvest failed');
      }
      return Map<String, dynamic>.from((j['report'] as Map?) ?? const {});
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// (Re)build the sidecar's machine-local template library from the user's
  /// own .pkt files. Returns the extraction manifest.
  Future<Map<String, dynamic>> pktTemplatesBuild(
    List<String> paths, {
    String outDir = '',
  }) async {
    try {
      final r = await _client
          .post(
            Uri.parse('$base/pkt/templates/build'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'paths': paths,
              ...?(outDir.trim().isEmpty ? null : {'outDir': outDir}),
            }),
          )
          .timeout(const Duration(seconds: 300));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 || j['ok'] != true) {
        throw Exception(j['error'] ?? 'Template build failed');
      }
      return Map<String, dynamic>.from((j['report'] as Map?) ?? const {});
    } catch (e) {
      throw Exception(_friendly(e));
    }
  }

  /// What the offline generator can build with today: device models and
  /// cable kinds the machine-local template library covers.
  Future<Map<String, dynamic>> pktTemplatesStatus() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/pkt/templates/status'))
          .timeout(const Duration(seconds: 10));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200 || j['ok'] != true) {
        throw Exception(j['error'] ?? 'Template status failed');
      }
      return Map<String, dynamic>.from((j['report'] as Map?) ?? const {});
    } catch (e) {
      throw Exception(_friendly(e));
    }
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

/// One correction row from the sidecar's teaching loop, with only the
/// fields the UI renders.  Any field the sidecar does not send (or sends as
/// the wrong type) degrades to its default - an old or new sidecar can
/// never crash the corrections card.
class CorrectionRow {
  final String id;
  final String status; // proposed | verified | rejected | reverted
  final String failureKind;
  final String project;
  final String device;
  final String dtype;
  final bool stale; // user-taught but stopped verifying
  final int thrash; // how many prior corrections for the same element
  final int hits;
  final int misses;
  final String rejectReason;
  final String ts;

  const CorrectionRow({
    this.id = '',
    this.status = '',
    this.failureKind = '',
    this.project = '',
    this.device = '',
    this.dtype = '',
    this.stale = false,
    this.thrash = 0,
    this.hits = 0,
    this.misses = 0,
    this.rejectReason = '',
    this.ts = '',
  });

  factory CorrectionRow.fromJson(dynamic raw) {
    if (raw is! Map) return const CorrectionRow();
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return CorrectionRow(
      id: raw['id']?.toString() ?? '',
      status: raw['status']?.toString() ?? '',
      failureKind: raw['failureKind']?.toString() ?? '',
      project: raw['project']?.toString() ?? '',
      device: raw['device']?.toString() ?? '',
      dtype: raw['dtype']?.toString() ?? '',
      stale: raw['stale'] == true,
      thrash: asInt(raw['thrash']),
      hits: asInt(raw['hits']),
      misses: asInt(raw['misses']),
      rejectReason: raw['rejectReason']?.toString() ?? '',
      ts: raw['ts']?.toString() ?? '',
    );
  }

  /// One-line summary the list tiles show: what was corrected, where.
  String get summaryLine {
    final where = device.isNotEmpty
        ? device
        : dtype.isNotEmpty
            ? dtype
            : 'any device';
    final scope = project.isNotEmpty ? ' [$project]' : '';
    return '${failureKind.isEmpty ? 'correction' : failureKind}'
        '$scope on $where';
  }
}

/// Everything `/corrections` serves that the UI shows, plus the counts.
class CorrectionSnapshot {
  final List<CorrectionRow> stale;
  final List<CorrectionRow> rejected;
  final List<CorrectionRow> pending;
  final List<CorrectionRow> thrash;
  final int proposedCount;
  final int verifiedCount;
  final int hits;

  const CorrectionSnapshot({
    this.stale = const [],
    this.rejected = const [],
    this.pending = const [],
    this.thrash = const [],
    this.proposedCount = 0,
    this.verifiedCount = 0,
    this.hits = 0,
  });

  const CorrectionSnapshot.empty() : this();

  bool get isEmpty =>
      stale.isEmpty && rejected.isEmpty && pending.isEmpty && thrash.isEmpty;

  /// True when any user-taught entry stopped verifying - drives the banner.
  bool get hasStale => stale.isNotEmpty;

  factory CorrectionSnapshot.fromJson(Map<String, dynamic> j) {
    List<CorrectionRow> rows(dynamic raw) => (raw is List ? raw : const [])
        .map(CorrectionRow.fromJson)
        .where((r) => r.id.isNotEmpty)
        .toList();
    final summaryRaw = j['summary'];
    final summary = summaryRaw is Map ? summaryRaw : const {};
    return CorrectionSnapshot(
      stale: rows(j['stale']),
      // The API exposes rejected rows only inside the listing; fish them
      // out so the badge survives a sidecar that never grows a top-level
      // `rejected` key.
      rejected: rows(j['rejected']).isNotEmpty
          ? rows(j['rejected'])
          : rows(summary['corrections'])
              .where((r) => r.status == 'rejected')
              .toList(),
      pending: rows(j['pending']),
      thrash: rows(j['thrash']),
      proposedCount:
          summary['proposed'] is num ? summary['proposed'] as int : 0,
      verifiedCount:
          summary['verified'] is num ? summary['verified'] as int : 0,
      hits: summary['hits'] is num ? summary['hits'] as int : 0,
    );
  }
}

/// The verdicts of the most recent teach run, keyed by correction id.
class TeachRunSnapshot {
  final Map<String, TeachResult> byId;

  const TeachRunSnapshot({this.byId = const {}});
  const TeachRunSnapshot.empty() : this();

  bool get isEmpty => byId.isEmpty;

  factory TeachRunSnapshot.fromJson(Map<String, dynamic> statusJson) {
    final raw = statusJson['teachResults'] as List? ?? const [];
    final map = <String, TeachResult>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final id = item['correctionId']?.toString() ?? '';
      if (id.isEmpty) continue;
      map[id] = TeachResult(
        promoted: item['promoted'] == true,
        pending: item['pending'] == true,
        reason: item['reason']?.toString() ?? '',
      );
    }
    return TeachRunSnapshot(byId: map);
  }
}

class TeachResult {
  final bool promoted;
  final bool pending;
  final String reason;
  const TeachResult({
    required this.promoted,
    required this.pending,
    required this.reason,
  });
}
