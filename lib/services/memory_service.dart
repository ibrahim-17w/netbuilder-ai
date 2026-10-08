import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/build_record.dart';
import '../models/build_attempt.dart';
import '../models/chat_message.dart';
import '../models/environment_profile.dart';
import '../models/network_intent.dart';
import 'learned_answers_service.dart';
import 'misparse_ledger.dart';
import 'phrasing_memory_service.dart';
import 'plan_repair_service.dart';
import 'repair_learning_service.dart';

/// On-device learning memory: builds + rules + preferences + chat.
/// SQLite file stays on device; nothing is uploaded.
class MemoryService extends ChangeNotifier {
  Database? _db;
  final Database? injected; // for tests
  MemoryService({this.injected});

  /// How many chat turns are kept. Older turns are pruned on insert so a
  /// Oldest messages beyond this are pruned so a very long conversation
  /// cannot grow the memory DB without bound. Raised from 200 to 5000 when
  /// the chat gained a real context window: the old value, together with a
  /// 60-message load and a 20-turn send cap, is why the assistant forgot a
  /// request made at the start of a session.
  static const chatRetention = 5000;

  bool get ready => _db != null || injected != null;
  Database? get _active => injected ?? _db;

  Future<void> init() async {
    if (injected != null) return;
    if (_db != null) return;
    // Desktop (Windows/Linux): use ffi. Mobile: default factory.
    try {
      if (defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
    } catch (_) {
      // ignore, fall back to default factory
    }
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'netbuilder', 'memory.db');
    // ensure parent exists via getApplicationDocumentsDirectory side-effect;
    // sqflite creates dirs on most platforms, but be explicit with ffi.
    _db = await openDatabase(
      path,
      version: 10,
      onCreate: (db, v) async => _create(db),
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE builds ADD COLUMN status TEXT NOT NULL DEFAULT 'verified'",
          );
          await db.execute('''
CREATE TABLE attempts(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 buildId INTEGER,
 projectName TEXT NOT NULL,
 instruction TEXT NOT NULL,
 intentJson TEXT NOT NULL,
 target TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'planned',
 failureKind TEXT,
 failureDetail TEXT,
 evidenceJson TEXT,
 correction TEXT,
 createdAt TEXT NOT NULL,
 updatedAt TEXT NOT NULL
)''');
        }
        if (oldVersion < 3) {
          await db.execute(_chatTableSql);
        }
        if (oldVersion < 4) {
          // Existing rows become one conversation called "default", which is
          // what they effectively already were: a single transcript.
          await db.execute(
            "ALTER TABLE chat ADD COLUMN conversation TEXT NOT NULL "
            "DEFAULT 'default'",
          );
        }
        if (oldVersion < 5) {
          // Real conversation records (title, project, summary, structured
          // state) and the exact change log "undo that" reads from.
          await db.execute(_conversationsTableSql);
          await db.execute(_changesTableSql);
          await db.execute(_changesIndexSql);
        }
        if (oldVersion < 6) {
          // Learned English phrasings (see [PhrasingMemoryService]).
          await db.execute(_phrasingTableSql);
        }
        if (oldVersion < 7) {
          // Which model answered each turn (see [ChatMessage.source]): the
          // provider status belongs to the turn, not to the app's current
          // settings, which may have changed since.
          await db.execute(
            "ALTER TABLE chat ADD COLUMN source TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 8) {
          // Answers learned from keyed-model replies (see
          // [LearnedAnswers]): question -> answer, replayed offline.
          await db.execute(_learnedAnswerTableSql);
          await db.execute(_learnedAnswerIndexSql);
        }
        if (oldVersion < 9) {
          // The remembered environment (venue, scale, budget, skill) the
          // advisor used to re-derive from every message and forget.
          await db.execute(_envProfileTableSql);
        }
        if (oldVersion < 10) {
          // Answers to clarifying questions, remembered so the same person
          // is never asked the same thing twice (see [ClarificationService]).
          await db.execute(_clarificationAnswerTableSql);
        }
      },
    );
    await _refreshPhrasingIndex();
    notifyListeners();
  }

  static Future<void> _create(DatabaseExecutor db) async {
    await db.execute('''
CREATE TABLE builds(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 projectName TEXT NOT NULL,
 instruction TEXT NOT NULL,
 intentJson TEXT NOT NULL,
 target TEXT NOT NULL,
 success INTEGER NOT NULL DEFAULT 1,
 status TEXT NOT NULL DEFAULT 'verified',
 error TEXT,
 fix TEXT,
 createdAt TEXT NOT NULL
)''');
    await db.execute('''
CREATE TABLE rules(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 ruleText TEXT NOT NULL,
 targets TEXT NOT NULL DEFAULT 'all',
 hits INTEGER NOT NULL DEFAULT 0,
 misses INTEGER NOT NULL DEFAULT 0
)''');
    await db.execute('''
CREATE TABLE prefs(
 k TEXT PRIMARY KEY,
 v TEXT NOT NULL
)''');
    await db.execute('''
CREATE TABLE attempts(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 buildId INTEGER,
 projectName TEXT NOT NULL,
 instruction TEXT NOT NULL,
 intentJson TEXT NOT NULL,
 target TEXT NOT NULL,
 status TEXT NOT NULL DEFAULT 'planned',
 failureKind TEXT,
 failureDetail TEXT,
 evidenceJson TEXT,
 correction TEXT,
 createdAt TEXT NOT NULL,
 updatedAt TEXT NOT NULL
)''');
    await db.execute(_chatTableSql);
    await db.execute(_conversationsTableSql);
    await db.execute(_changesTableSql);
    await db.execute(_changesIndexSql);
    await db.execute(_phrasingTableSql);
    await db.execute(_learnedAnswerTableSql);
    await db.execute(_learnedAnswerIndexSql);
    await db.execute(_envProfileTableSql);
    await db.execute(_clarificationAnswerTableSql);
  }

  /// Attachments are paths on disk, not blobs: screenshots are hundreds of
  /// KB each and keeping them out of SQLite keeps reads fast.
  static const _chatTableSql = '''
CREATE TABLE chat(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 conversation TEXT NOT NULL DEFAULT 'default',
 role TEXT NOT NULL,
 text TEXT NOT NULL DEFAULT '',
 imagesJson TEXT NOT NULL DEFAULT '[]',
 actionsJson TEXT NOT NULL DEFAULT '[]',
 executedJson TEXT NOT NULL DEFAULT '[]',
 createdAt TEXT NOT NULL,
 source TEXT NOT NULL DEFAULT ''
)''';

  /// One row per conversation. The chat table holds the transcript; this
  /// holds what the transcript cannot answer: what the chat is called, which
  /// network it is about, its compacted summary and its structured state.
  ///
  /// The title is stored rather than always derived from the first message so
  /// a generated title and a manual rename both survive, and the summary is
  /// stored rather than recomputed so "summarize the summary" never happens.
  static const _conversationsTableSql = '''
CREATE TABLE conversations(
 id TEXT PRIMARY KEY,
 title TEXT NOT NULL DEFAULT '',
 project TEXT NOT NULL DEFAULT '',
 createdAt TEXT NOT NULL,
 updatedAt TEXT NOT NULL,
 summary TEXT NOT NULL DEFAULT '',
 summaryUpToId INTEGER NOT NULL DEFAULT 0,
 stateJson TEXT NOT NULL DEFAULT '{}'
)''';

  /// The exact, structured record of every network change the app made.
  ///
  /// This is what makes "undo that" reliable: the app looks up the last
  /// change for a conversation (or for a named device) instead of asking a
  /// model to remember which value it typed. One row = one field on one
  /// interface, with both values recorded verbatim.
  static const _changesTableSql = '''
CREATE TABLE changes(
 actionId INTEGER PRIMARY KEY AUTOINCREMENT,
 conversation TEXT NOT NULL,
 device TEXT NOT NULL,
 interface TEXT NOT NULL DEFAULT '',
 field TEXT NOT NULL,
 oldValue TEXT NOT NULL DEFAULT '',
 newValue TEXT NOT NULL DEFAULT '',
 source TEXT NOT NULL DEFAULT '',
 createdAt TEXT NOT NULL,
 undoneAt TEXT
)''';

  static const _changesIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_changes_conversation '
      'ON changes(conversation, actionId DESC)';

  /// One learned phrasing per row: what the user said, and the resolved
  /// brief it replayed to. Its own table, not prefs - a lesson is memory the
  /// app acts on, not a setting the user chose.
  static const _phrasingTableSql = '''
CREATE TABLE phrasing(
 phrasing TEXT PRIMARY KEY,
 rewrite TEXT NOT NULL,
 createdAt TEXT NOT NULL
)''';

  static const _learnedAnswerTableSql = '''
CREATE TABLE learned_answer(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 qkey TEXT NOT NULL,
 question TEXT NOT NULL,
 answer TEXT NOT NULL,
 source TEXT NOT NULL DEFAULT '',
 seenCount INTEGER NOT NULL DEFAULT 1,
 confirmed INTEGER NOT NULL DEFAULT 0,
 createdAt TEXT NOT NULL,
 lastSeenAt TEXT NOT NULL
)''';

  static const _learnedAnswerIndexSql = '''
CREATE INDEX idx_learned_answer_qkey ON learned_answer(qkey)
''';

  /// The remembered environment (see [EnvironmentProfile]): exactly one row,
  /// because "the user's environment" is one fact, not a history - the newest
  /// merge replaces the row, and the JSON carries its own timestamp.
  static const _envProfileTableSql = '''
CREATE TABLE environment_profile(
 id INTEGER PRIMARY KEY CHECK(id = 1),
 json TEXT NOT NULL,
 updatedAt TEXT NOT NULL
)''';

  /// Answers to clarifying questions (see [ClarificationService]): "OSPF or
  /// static?" -> "OSPF", remembered WITH the venue/scale it was answered
  /// under, so a home-lab answer never silently becomes the office answer.
  /// A row with no venue applies anywhere - the user said it without a site
  /// in play.
  static const _clarificationAnswerTableSql = '''
CREATE TABLE clarification_answer(
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 question_id TEXT NOT NULL,
 answer TEXT NOT NULL,
 venue TEXT NOT NULL DEFAULT '',
 scale INTEGER NOT NULL DEFAULT 0,
 created_at TEXT NOT NULL
)''';

  /// Used by unit tests to create schema on an in-memory db.
  static Future<void> createSchema(DatabaseExecutor db) => _create(db);

  Future<int> logBuild(BuildRecord r) async {
    final id = await _active!.insert('builds', r.toMap());
    notifyListeners();
    return id;
  }

  Future<void> updateBuildOutcome({
    required int id,
    required bool success,
    required String status,
    String? error,
    String? fix,
  }) async {
    final values = <String, dynamic>{
      'success': success ? 1 : 0,
      'status': status,
      'error': error,
    };
    if (fix != null) values['fix'] = fix;
    await _active!.update('builds', values, where: 'id=?', whereArgs: [id]);
    notifyListeners();
    // THE REPAIR LOOP CLOSES HERE. This is the one choke point every build
    // path reports through (PT autopilot evidence, GNS3 push, the offline
    // .pkt write), so it is also the only place worth teaching from: a rule
    // the repair pass proposed is promoted only when the plan it was found in
    // actually built, and is dropped when that build failed. Learning must
    // never be wired to "a repair ran" - that would teach the app to repeat
    // fixes that do not survive a build.
    try {
      final plan = await planForBuild(id);
      if (plan != null) {
        await confirmRepairedPlan(plan, verified: success && status == 'verified');
      }
    } catch (_) {
      // A learning hiccup must never cost a build its outcome.
    }
  }

  /// The plan a build row was written for, or null when it cannot be read
  /// back. Used to match a build against the repair that shaped it.
  Future<NetworkIntent?> planForBuild(int id) async {
    final db = _active;
    if (db == null) return null;
    final rows = await db.query(
      'builds',
      columns: ['intentJson'],
      where: 'id=?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      final raw = rows.first['intentJson']?.toString() ?? '';
      if (raw.isEmpty) return null;
      return NetworkIntent.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  // --- repair learning ---------------------------------------------------
  // The repair pass finds real defects in a real plan. When the plan it
  // produced BUILDS, the defect is worth teaching. Until then the candidate
  // rules are parked under the plan's fingerprint with no effect at all.

  /// prefs key holding the parked, not-yet-proven repair rules.
  static const repairLearningKey = 'repair_learning';

  /// Park the rules a repair pass would like to teach, keyed by the shape of
  /// the plan it repaired.
  ///
  /// Parking teaches nothing. The rules are promoted by [confirmRepairedPlan]
  /// once a build of this exact plan comes back verified, and are dropped when
  /// it fails. Nothing here is visible to a planner in the meantime.
  Future<void> noteRepairedPlan({
    required NetworkIntent plan,
    required List<RepairFix> fixes,
    required String target,
  }) async {
    final db = _active;
    if (db == null) return;
    final rules = RepairLearning.rulesFrom(fixes);
    if (rules.isEmpty) return;
    final fp = RepairLearning.fingerprint(plan);
    final parked = await _repairCandidates();
    // One entry per plan shape: a second repair of the same plan replaces the
    // first, rather than stacking two copies of the same lesson.
    final kept = <Map<String, dynamic>>[
      {
        'fp': fp,
        'target': target.trim().isEmpty ? 'all' : target.trim(),
        'rules': rules,
        'at': DateTime.now().toIso8601String(),
      },
      for (final entry in parked)
        if (entry['fp'] != fp) entry,
    ].take(RepairLearning.maxCandidates).toList();
    await setPref(repairLearningKey, jsonEncode(kept));
  }

  /// Resolve what a build of [plan] means for the rules a repair parked.
  ///
  /// Verified promotes them into [rules] (scoped to the target the plan was
  /// repaired for, and skipped when the app already knows the rule); anything
  /// else discards them. Returns how many rules were promoted, so callers and
  /// tests can see the promotion actually happened.
  ///
  /// Nothing negative is ever recorded. A failed build teaches the app what
  /// NOT to do, and storing that is how a store starts steering plans away
  /// from a fix that was merely unlucky; the failing build is already in
  /// [recentBuilds] for anything that needs the evidence.
  Future<int> confirmRepairedPlan(
    NetworkIntent plan, {
    required bool verified,
  }) async {
    final db = _active;
    if (db == null) return 0;
    final fp = RepairLearning.fingerprint(plan);
    final parked = await _repairCandidates();
    final match = parked.where((e) => e['fp'] == fp).toList();
    if (match.isEmpty) return 0;
    final rest = parked.where((e) => e['fp'] != fp).toList();
    if (!verified) {
      await setPref(repairLearningKey, jsonEncode(rest));
      return 0;
    }
    var promoted = 0;
    for (final entry in match) {
      final known = {
        for (final rule in await allRules())
          rule.ruleText.trim().toLowerCase(),
      };
      for (final rule in (entry['rules'] as List?) ?? const []) {
        final text = rule.toString().trim();
        if (text.isEmpty || known.contains(text.toLowerCase())) continue;
        known.add(text.toLowerCase());
        await addRule(text, targets: entry['target']?.toString() ?? 'all');
        promoted++;
      }
    }
    await setPref(repairLearningKey, jsonEncode(rest));
    return promoted;
  }

  /// The parked repair candidates, newest first. Unparseable content is
  /// treated as empty: a corrupt pref must not stop the app.
  Future<List<Map<String, dynamic>>> _repairCandidates() async {
    final db = _active;
    if (db == null) return const [];
    final rows = await db.query(
      'prefs',
      columns: ['v'],
      where: 'k=?',
      whereArgs: [repairLearningKey],
      limit: 1,
    );
    if (rows.isEmpty) return const [];
    try {
      final decoded = jsonDecode(rows.first['v']?.toString() ?? '[]');
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map) Map<String, dynamic>.from(item),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<int> logAttempt(BuildAttempt attempt) async {
    final id = await _active!.insert('attempts', attempt.toMap());
    notifyListeners();
    return id;
  }

  Future<void> updateAttempt({
    required int id,
    required String status,
    String? failureKind,
    String? failureDetail,
    String? evidenceJson,
    String? correction,
  }) async {
    await _active!.update(
      'attempts',
      {
        'status': status,
        'failureKind': failureKind,
        'failureDetail': failureDetail,
        'evidenceJson': evidenceJson,
        'correction': correction,
        'updatedAt': DateTime.now().toIso8601String(),
      },
      where: 'id=?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  Future<BuildAttempt?> latestAttemptForBuild(int buildId) async {
    final rows = await _active!.query(
      'attempts',
      where: 'buildId=?',
      whereArgs: [buildId],
      orderBy: 'id DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : BuildAttempt.fromMap(rows.first);
  }

  Future<List<BuildAttempt>> recentAttempts({int limit = 30}) async {
    final db = _active;
    if (db == null) return const [];
    final rows = await db.query('attempts', orderBy: 'id DESC', limit: limit);
    return rows.map(BuildAttempt.fromMap).toList();
  }

  Future<List<BuildRecord>> recentBuilds({int limit = 20}) async {
    final db = _active;
    if (db == null) return const [];
    final rows = await db.query(
      'builds',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(BuildRecord.fromMap).toList();
  }

  /// Naive keyword search for similar past builds (offline, no vectors v1).
  Future<List<BuildRecord>> searchSimilar(
    String instruction, {
    int limit = 5,
  }) async {
    final words = instruction
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 3)
        .take(6)
        .toList();
    if (words.isEmpty) return recentBuilds(limit: limit);
    final where = words.map((_) => 'lower(instruction) LIKE ?').join(' OR ');
    final args = words.map((w) => '%$w%').toList();
    final rows = await _active!.query(
      'builds',
      where: where,
      whereArgs: args,
      orderBy: 'id DESC',
      limit: limit,
    );
    if (rows.isEmpty) return recentBuilds(limit: limit);
    return rows.map(BuildRecord.fromMap).toList();
  }

  Future<int> addRule(String text, {String targets = 'all'}) async {
    final id = await _active!.insert(
      'rules',
      LearnedRule(ruleText: text, targets: targets).toMap(),
    );
    notifyListeners();
    return id;
  }

  Future<List<LearnedRule>> allRules() async {
    final db = _active;
    if (db == null) return const [];
    final rows = await db.query('rules', orderBy: 'id DESC', limit: 100);
    return rows.map(LearnedRule.fromMap).toList();
  }

  /// Only the rules a user actually taught the app.
  ///
  /// The Memory screen also files the sidecar's journal advice (the
  /// `/suggest` suggestion strings) as rules with an `autopilot` target.
  /// That text is troubleshooting prose, not a rule - feeding it to the
  /// planner's rule reader meant one sentence that merely *mentions* OSPF
  /// silently rewrote every later keyless plan. Journal rows stay in
  /// [allRules] so they remain reviewable and deletable, but planners and
  /// model context must read rules through this method instead.
  static bool _isPlannerRule(LearnedRule rule) {
    final targets = rule.targets
        .toLowerCase()
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty);
    return !targets.contains('autopilot');
  }

  /// Rule texts safe to steer a plan or a model prompt: user-taught rules
  /// only. Journal advice is excluded, including legacy rows written before
  /// the targets were recorded.
  Future<List<String>> plannerRuleTexts() async => [
        for (final rule in await allRules())
          if (_isPlannerRule(rule)) rule.ruleText,
      ];

  Future<void> markRule(int id, bool helpful) async {
    await _active!.rawUpdate(
      helpful
          ? 'UPDATE rules SET hits=hits+1 WHERE id=?'
          : 'UPDATE rules SET misses=misses+1 WHERE id=?',
      [id],
    );
    notifyListeners();
  }

  Future<void> setPref(String k, String v) async {
    await _active!.insert('prefs', {
      'k': k,
      'v': v,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<Map<String, String>> allPrefs() async {
    final db = _active;
    if (db == null) return const {};
    final rows = await db.query('prefs', limit: 200);
    return {for (final r in rows) (r['k'] as String): (r['v'] as String)};
  }

  // --- environment profile -------------------------------------------------

  /// The remembered environment (venue, scale, budget, skill), or null when
  /// nothing has been learned yet. A row whose JSON will not parse reads as
  /// "nothing learned" - the advisor then just answers from the message, as
  /// it always did, instead of the chat breaking over one bad value.
  Future<EnvironmentProfile?> environmentProfile() async {
    final db = _active;
    if (db == null) return null;
    final rows = await db.query(
      'environment_profile',
      where: 'id = 1',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return EnvironmentProfile.tryDecode('${rows.first['json'] ?? ''}');
  }

  /// Store the environment, replacing whatever was there: one row, newest
  /// merge wins.
  Future<void> setEnvironmentProfile(EnvironmentProfile profile) async {
    final db = _active;
    if (db == null) return;
    final now = DateTime.now().toIso8601String();
    final stamped = profile.updatedAt.isEmpty
        ? EnvironmentProfile(
            venue: profile.venue,
            scale: profile.scale,
            budget: profile.budget,
            skill: profile.skill,
            updatedAt: now,
            source: profile.source,
          )
        : profile;
    await db.insert(
      'environment_profile',
      {
        'id': 1,
        'json': jsonEncode(stamped.toJson()),
        'updatedAt': stamped.updatedAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    notifyListeners();
  }

  /// Forget the environment entirely. The advisor goes back to deriving
  /// everything from each message, which is the behaviour this store was
  /// added on top of - forgetting is always safe.
  Future<void> forgetEnvironmentProfile() async {
    final db = _active;
    if (db == null) return;
    await db.delete('environment_profile');
    notifyListeners();
  }

  // --- clarification answers ------------------------------------------------

  /// Remember one answered clarification (see [ClarificationService]).
  /// [venue]/[scale] stamp the environment it was answered under, so the
  /// lookup can prefer an answer given for the same kind of site.
  Future<void> rememberClarification(
    String questionId,
    String answer, {
    String venue = '',
    int scale = 0,
  }) async {
    final db = _active;
    if (db == null) return;
    await db.insert('clarification_answer', {
      'question_id': questionId,
      'answer': answer,
      'venue': venue,
      'scale': scale,
      'created_at': DateTime.now().toIso8601String(),
    });
    notifyListeners();
  }

  /// Every remembered answer, newest first - what the Memory screen lists.
  Future<List<Map<String, dynamic>>> clarificationAnswers() async {
    final db = _active;
    if (db == null) return const [];
    return db.query(
      'clarification_answer',
      orderBy: 'id DESC',
      limit: 200,
    );
  }

  /// The remembered answer for [questionId], or null.
  ///
  /// Preference order: an answer given under the SAME venue (newest first),
  /// then a venue-less global answer. A home-lab answer must never silently
  /// become the office answer, but an answer given with no site in play
  /// applies everywhere. The scale stamp stays informational - it shows the
  /// Memory screen what the answer was given for.
  Future<String?> answerForClarification(
    String questionId,
    EnvironmentProfile? profile,
  ) async {
    final db = _active;
    if (db == null) return null;
    final rows = await db.query(
      'clarification_answer',
      where: 'question_id = ?',
      whereArgs: [questionId],
      orderBy: 'id DESC',
    );
    if (rows.isEmpty) return null;
    final venue = profile?.venue ?? '';
    Map<String, dynamic>? venueMatch;
    Map<String, dynamic>? globalMatch;
    for (final row in rows) {
      final rowVenue = '${row['venue'] ?? ''}';
      if (venue.isNotEmpty && rowVenue == venue) {
        venueMatch ??= row;
      } else if (rowVenue.isEmpty) {
        globalMatch ??= row;
      }
    }
    final picked = venueMatch ?? globalMatch;
    if (picked == null) return null;
    return '${picked['answer'] ?? ''}';
  }

  /// Forget one remembered answer.
  Future<void> forgetClarification(int id) async {
    final db = _active;
    if (db == null) return;
    await db.delete(
      'clarification_answer',
      where: 'id = ?',
      whereArgs: [id],
    );
    notifyListeners();
  }

  // --- phrasing memory ---------------------------------------------------

  /// Remember one phrasing lesson (see [PhrasingMemoryService]): the words
  /// the user used, and the resolved brief they meant. The live index is
  /// refreshed here, so the very next parse sees the lesson.
  ///
  /// [key] must already be canonical - hand it
  /// [PhrasingMemoryService.normalizeKey] (which is exactly what
  /// [PhrasingMemoryService.teachIfResolved] hands you), because lookup
  /// queries canonical keys.
  Future<void> teachPhrasing(String key, String rewrite) async {
    final db = _active;
    if (db == null) return;
    await db.insert(
      'phrasing',
      {
        'phrasing': key,
        'rewrite': rewrite,
        'createdAt': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _refreshPhrasingIndex();
    notifyListeners();
  }

  /// Replace the live index from SQLite. Newest first, capped: the index is
  /// a replay cache, not an archive.
  Future<void> _refreshPhrasingIndex() async {
    final db = _active;
    if (db == null) return;
    final rows = await db.query(
      'phrasing',
      orderBy: 'createdAt DESC',
      limit: 100,
    );
    PhrasingMemoryService.setIndex([
      for (final r in rows)
        (phrasing: r['phrasing'].toString(), rewrite: r['rewrite'].toString()),
    ]);
  }

  /// Every learned phrasing, newest first - what the Memory screen lists.
  Future<List<Map<String, dynamic>>> allPhrasings() async {
    final db = _active;
    if (db == null) return const [];
    return db.query('phrasing', orderBy: 'createdAt DESC', limit: 100);
  }

  /// Drop one learned phrasing by its stored key.
  Future<void> forgetPhrasing(String key) async {
    final db = _active;
    if (db == null) return;
    await db.delete('phrasing', where: 'phrasing = ?', whereArgs: [key]);
    await _refreshPhrasingIndex();
    notifyListeners();
  }

  // --- misparse ledger (user corrections, counted) -------------------------

  /// The pref holding the ledger AND its turn counter. One blob, the way the
  /// repair candidates are stored, so the numerator and the denominator
  /// cannot drift apart.
  static const misparseLedgerKey = 'misparse_ledger';

  /// Read the raw ledger blob. Unparseable content is empty: a corrupt pref
  /// must not stop the app.
  Future<({List<MisparseEntry> entries, int turns})> _misparseState() async {
    final db = _active;
    if (db == null) return (entries: const <MisparseEntry>[], turns: 0);
    final rows = await db.query(
      'prefs',
      columns: ['v'],
      where: 'k=?',
      whereArgs: [misparseLedgerKey],
      limit: 1,
    );
    if (rows.isEmpty) return (entries: const <MisparseEntry>[], turns: 0);
    try {
      final decoded =
          jsonDecode(rows.first['v']?.toString() ?? '{}');
      if (decoded is! Map) return (entries: const <MisparseEntry>[], turns: 0);
      final raw = decoded['entries'];
      return (
        entries: [
          if (raw is List)
            for (final item in raw)
              if (item is Map)
                MisparseEntry.fromMap(Map<String, dynamic>.from(item)),
        ],
        turns: (decoded['turns'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return (entries: const <MisparseEntry>[], turns: 0);
    }
  }

  Future<void> _writeMisparseState(
    List<MisparseEntry> entries,
    int turns, {
    bool notify = true,
  }) async {
    final db = _active;
    if (db == null) return;
    await db.insert(
      'prefs',
      {
        'k': misparseLedgerKey,
        'v': jsonEncode({
          'turns': turns,
          'entries': [for (final e in entries) e.toMap()],
        }),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (notify) notifyListeners();
  }

  /// One more turn the app parsed into a plan. The denominator of the
  /// misparse rate: without it, "improving" would be unmeasurable.
  Future<void> noteParsedTurn() async {
    final db = _active;
    if (db == null) return;
    final state = await _misparseState();
    // No notify: a counter is not something any widget renders on its own,
    // and rebuilding the world once per turn is a cost for no one.
    await _writeMisparseState(state.entries, state.turns + 1, notify: false);
  }

  /// Log one user correction. Returns the row after the merge - its [count]
  /// and [MisparseEntry.status] say whether this wording has been corrected
  /// enough times to be worth reviewing - or null when nothing was recorded
  /// (no store, or a correction that would not replay).
  Future<MisparseEntry?> recordMisparse({
    required String original,
    required String understood,
    required String corrected,
    required String slot,
    required String source,
  }) async {
    final db = _active;
    if (db == null) return null;
    final state = await _misparseState();
    final result = MisparseLedger.record(
      entries: state.entries,
      original: original,
      understood: understood,
      corrected: corrected,
      slot: slot,
      source: source,
    );
    await _writeMisparseState(result.entries, state.turns);
    return result.entry;
  }

  /// Every logged correction, newest first.
  Future<List<MisparseEntry>> misparseLedger() async =>
      (await _misparseState()).entries;

  /// The numbers the Memory health strip shows.
  ///
  /// [corrections] is every correction the user ever had to make;
  /// [turns] every turn parsed into a plan. The rate is corrections per
  /// parsed turn, so a falling number means the lessons are landing - it is
  /// counted, not felt.
  Future<
      ({
        int turns,
        int corrections,
        int proposed,
        int taught,
        int dismissed,
      })> misparseStats() async {
    final state = await _misparseState();
    var corrections = 0;
    var proposed = 0;
    var taught = 0;
    var dismissed = 0;
    for (final e in state.entries) {
      corrections += e.count;
      switch (e.status) {
        case 'proposed':
          proposed++;
        case 'taught':
          taught++;
        case 'dismissed':
          dismissed++;
      }
    }
    return (
      turns: state.turns,
      corrections: corrections,
      proposed: proposed,
      taught: taught,
      dismissed: dismissed,
    );
  }

  /// Promote a proposed correction into the live phrasing index.
  ///
  /// This is the only way a misparse lesson becomes a lesson: the row is
  /// taught, marked, and the very next parse can replay it.
  Future<bool> teachMisparse(String key, String corrected) async {
    final db = _active;
    if (db == null) return false;
    final state = await _misparseState();
    final at = state.entries
        .indexWhere((e) => e.key == key && e.corrected == corrected);
    if (at < 0) return false;
    await teachPhrasing(key, corrected);
    final next = [...state.entries];
    next[at] = MisparseEntry(
      key: next[at].key,
      original: next[at].original,
      understood: next[at].understood,
      corrected: next[at].corrected,
      slot: next[at].slot,
      source: next[at].source,
      status: 'taught',
      count: next[at].count,
      createdAt: next[at].createdAt,
      updatedAt: DateTime.now().toIso8601String(),
    );
    await _writeMisparseState(next, state.turns);
    return true;
  }

  /// Reject a proposed correction. It stays in the ledger as evidence - the
  /// rate still counts it - but it never reaches the parser.
  Future<void> dismissMisparse(String key, String corrected) async {
    final db = _active;
    if (db == null) return;
    final state = await _misparseState();
    final at = state.entries
        .indexWhere((e) => e.key == key && e.corrected == corrected);
    if (at < 0) return;
    final next = [...state.entries];
    next[at] = MisparseEntry(
      key: next[at].key,
      original: next[at].original,
      understood: next[at].understood,
      corrected: next[at].corrected,
      slot: next[at].slot,
      source: next[at].source,
      status: 'dismissed',
      count: next[at].count,
      createdAt: next[at].createdAt,
      updatedAt: DateTime.now().toIso8601String(),
    );
    await _writeMisparseState(next, state.turns);
  }

  // --- learned answers (from keyed-model replies, replayed offline) ---------

  /// Learn one model answer for [question]. The decision (learn / agree /
  /// reject) belongs to [LearnedAnswers]; this only persists it. Returns
  /// the affected row id, or -1 when the answer was rejected.
  Future<int> learnAnswer({
    required String question,
    required String answer,
    required String source,
  }) async {
    final db = _active;
    if (db == null) return -1;
    final key = LearnedAnswers.keyFor(question);
    final existing = await _learnedCandidates(key);
    final capture = LearnedAnswers.capture(
      question: question,
      answer: answer,
      source: source,
      existing: existing,
    );
    final now = DateTime.now().toIso8601String();
    final id = switch (capture.action) {
      LearnedCapture.learned => await db.insert('learned_answer', {
        'qkey': key,
        'question': question.trim(),
        'answer': capture.candidate!.answer,
        'source': source,
        'seenCount': 1,
        'confirmed': capture.candidate!.confirmed ? 1 : 0,
        'createdAt': now,
        'lastSeenAt': now,
      }),
      LearnedCapture.agrees => () {
        final row = existing.firstWhere(
          (e) => e.id == capture.existingId,
          orElse: () => existing.first,
        );
        db.update(
          'learned_answer',
          {
            'seenCount': row.seenCount + 1,
            // Agreement across independent model calls is confirmation.
            'confirmed': row.seenCount + 1 >= 2 ? 1 : 0,
            'lastSeenAt': now,
          },
          where: 'id = ?',
          whereArgs: [row.id],
        );
        return row.id;
      }(),
      _ => -1,
    };
    if (id > 0) await _capLearnedAnswers();
    notifyListeners();
    return id;
  }

  /// The best learned answer for this question, or null. Exact-key match:
  /// the same wording the model answered is the wording it is replayed
  /// for; paraphrases stay with the curated corpus.
  Future<LearnedAnswer?> bestLearnedAnswer(String question) async {
    final db = _active;
    if (db == null) return null;
    final candidates = await _learnedCandidates(LearnedAnswers.keyFor(question));
    return LearnedAnswers.pickBest(candidates);
  }

  Future<List<LearnedAnswer>> _learnedCandidates(String key) async {
    final db = _active;
    if (db == null) return const [];
    final rows = await db.query(
      'learned_answer',
      where: 'qkey = ?',
      whereArgs: [key],
      orderBy: 'lastSeenAt DESC',
      limit: 10,
    );
    return [for (final r in rows) _learnedFromRow(r)];
  }

  /// Every learned answer, newest-seen first - what the Memory screen lists.
  Future<List<Map<String, dynamic>>> allLearnedAnswers() async {
    final db = _active;
    if (db == null) return const [];
    return db.query('learned_answer', orderBy: 'lastSeenAt DESC', limit: 500);
  }

  /// Drop one learned answer by id.
  Future<void> forgetLearnedAnswer(int id) async {
    final db = _active;
    if (db == null) return;
    await db.delete('learned_answer', where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  /// Working memory, not an archive: beyond the cap the least-recently-seen
  /// answers are dropped.
  Future<void> _capLearnedAnswers() async {
    final db = _active;
    if (db == null) return;
    await db.delete(
      'learned_answer',
      where:
          'id NOT IN (SELECT id FROM learned_answer '
          'ORDER BY lastSeenAt DESC LIMIT ?)',
      whereArgs: [LearnedAnswers.maxAnswers],
    );
  }

  LearnedAnswer _learnedFromRow(Map<String, Object?> r) => LearnedAnswer(
    id: (r['id'] as num?)?.toInt() ?? 0,
    qkey: (r['qkey'] ?? '').toString(),
    question: (r['question'] ?? '').toString(),
    answer: (r['answer'] ?? '').toString(),
    source: (r['source'] ?? '').toString(),
    seenCount: (r['seenCount'] as num?)?.toInt() ?? 1,
    confirmed: (r['confirmed'] as num?)?.toInt() == 1,
    createdAt: (r['createdAt'] ?? '').toString(),
    lastSeenAt: (r['lastSeenAt'] ?? '').toString(),
  );

  /// The version stamped on [exportJson]. A backup whose shape can change
  /// silently is not a backup: this is what lets a reader (a future importer,
  /// a person) tell what it is looking at before trusting it.
  /// v2: adds the learned-phrasing table.
  /// v3: adds the environment profile (one row or null).
  /// v4: adds the clarification answers.
  static const exportSchemaVersion = 4;

  /// Everything the app remembers, as one JSON document.
  ///
  /// This used to keep the newest 500 chat turns and nothing else about them:
  /// no conversation, so a restore could not tell which turn belonged to which
  /// chat; no title, summary or session state, so every chat came back
  /// anonymous with no memory of what it had established; no change log, so
  /// "undo that" had nothing to read; and the attempts were capped and
  /// unfiltered, detached from the builds they explain.  The export is what a
  /// person takes when they move machines or keep a record, so it now carries
  /// every table in full.
  Future<String> exportJson() async {
    final db = _active;
    if (db == null) {
      return const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': exportSchemaVersion,
        'exportedAt': DateTime.now().toIso8601String(),
        'builds': <Map<String, dynamic>>[],
        'attempts': <Map<String, dynamic>>[],
        'rules': <Map<String, dynamic>>[],
        'prefs': <String, String>{},
        'conversations': <Map<String, dynamic>>[],
        'chat': <Map<String, dynamic>>[],
        'changes': <Map<String, dynamic>>[],
        'phrasing': <Map<String, dynamic>>[],
        'clarificationAnswers': <Map<String, dynamic>>[],
        'environmentProfile': null,
      });
    }
    final builds = await db.query('builds', orderBy: 'id ASC');
    final attempts = await db.query('attempts', orderBy: 'id ASC');
    final rules = await db.query('rules', orderBy: 'id ASC');
    final prefs = await db.query('prefs', orderBy: 'k ASC');
    final conversations = await db.query('conversations', orderBy: 'createdAt ASC');
    final chat = await _exportChat();
    final changes = await _exportChanges();
    final phrasing = await db.query('phrasing', orderBy: 'createdAt ASC');
    final clarifications = await db.query(
      'clarification_answer',
      orderBy: 'id ASC',
    );
    final envRow = await db.query(
      'environment_profile',
      where: 'id = 1',
      limit: 1,
    );
    return const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': exportSchemaVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'builds': builds,
      'attempts': attempts,
      'rules': rules,
      'prefs': {for (final row in prefs) row['k'].toString(): row['v']},
      'conversations': conversations,
      'chat': chat,
      'changes': changes,
      'phrasing': phrasing,
      'clarificationAnswers': clarifications,
      'environmentProfile': envRow.isEmpty
          ? null
          : EnvironmentProfile.tryDecode('${envRow.first['json'] ?? ''}')
                ?.toJson(),
    });
  }

  /// Every chat row, oldest first and uncapped, with the conversation it
  /// belongs to. The three JSON columns are decoded into real JSON so the
  /// exported file is one document to read and re-encode, not a list of
  /// escaped strings.
  Future<List<Map<String, dynamic>>> _exportChat() async {
    final db = _active;
    if (db == null) return const [];
    final rows = await db.query('chat', orderBy: 'id ASC');
    return [for (final row in rows) _exportChatRow(row)];
  }

  /// One chat row for the export: the same fields, with the three JSON
  /// columns decoded so the file is a document to read rather than a list of
  /// escaped strings. A column that will not parse is kept as its stored text
  /// - losing a whole turn over one bad attachment list helps nobody.
  static Map<String, dynamic> _exportChatRow(Map<String, Object?> row) {
    final out = <String, dynamic>{};
    for (final entry in row.entries) {
      if (entry.key.endsWith('Json')) continue;
      out[entry.key] = entry.value;
    }
    out['images'] = _decoded(row['imagesJson']);
    out['actions'] = _decoded(row['actionsJson']);
    out['executed'] = _decoded(row['executedJson']);
    return out;
  }

  /// The change log, oldest first. Every row is kept, including the undone
  /// ones and the `undoneAt` stamp: a change that was reverted is part of the
  /// history, and dropping the undo flag would offer the same edit twice.
  Future<List<Map<String, dynamic>>> _exportChanges() async {
    final db = _active;
    if (db == null) return const [];
    return db.query('changes', orderBy: 'actionId ASC');
  }

  /// One JSON column as JSON, falling back to the stored text when it is not
  /// parseable so an export never loses a row over one bad value.
  static dynamic _decoded(dynamic column) {
    final text = (column ?? '').toString();
    if (text.isEmpty) return const [];
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  // --- conversation ------------------------------------------------------
  // The chat is persisted so "keep going" survives a restart, and so an
  // instruction the user gave three turns ago is still in context.

  Future<int> logChat(
    ChatMessage message, {
    String conversation = 'default',
  }) async {
    final row = message.toMap();
    row.remove('id');
    row['conversation'] = conversation.trim().isEmpty
        ? 'default'
        : conversation.trim();
    final id = await _active!.insert('chat', row);
    await _pruneChat();
    notifyListeners();
    return id;
  }

  Future<void> updateChat(int id, ChatMessage message) async {
    final row = message.toMap();
    row.remove('id');
    await _active!.update('chat', row, where: 'id=?', whereArgs: [id]);
    notifyListeners();
  }

  /// Remove one conversation's transcript FROM a turn onward, in place.
  ///
  /// "Answer again" and "Edit and resend" both rewrite history: the turn
  /// they start from and everything after it are gone. Cutting only the
  /// screen copies would leave the rows in SQLite, and the next reload
  /// would grow the abandoned branch straight back.
  ///
  /// The anchor is the row id when the caller knows it (a turn read back
  /// from the store carries its id); a turn created this session does not,
  /// so it is matched by the exact (createdAt, role, text) that was written
  /// to its row - and if that is somehow ambiguous, the EARLIEST match wins,
  /// so the deletion always covers at least what the screen removed and
  /// never leaves rows behind it. Fail-closed on purpose:
  ///
  ///  * an empty [conversation] deletes nothing - an unnamed "all" is how
  ///    one chat's Clear once wiped every transcript;
  ///  * a [fromId] that is not a row OF this conversation deletes nothing,
  ///    or `id >= ?` would cut into whatever was logged after it;
  ///  * an anchor that matches no row deletes nothing: a truncation that
  ///    cannot find its place must not become a wipe.
  ///
  /// Returns the number of rows removed, so callers and tests can tell a
  /// truncation from a no-op.
  ///
  /// The change log is deliberately left alone. A `changes` row records an
  /// edit that was really made to a device, keyed by its own actionId - it
  /// has no link to a chat row, and discarding a branch of the conversation
  /// does not un-configure what that branch already applied.
  Future<int> deleteChatFrom(
    String conversation, {
    int? fromId,
    String fromCreatedAt = '',
    String fromRole = '',
    String fromText = '',
  }) async {
    final db = _active;
    if (db == null) return 0;
    final name = conversation.trim();
    if (name.isEmpty) return 0;
    final int anchor;
    if (fromId != null) {
      final own = await db.query(
        'chat',
        columns: ['id'],
        where: 'id = ? AND conversation = ?',
        whereArgs: [fromId, name],
        limit: 1,
      );
      if (own.isEmpty) return 0;
      anchor = fromId;
    } else {
      final rows = await db.query(
        'chat',
        columns: ['id'],
        where: 'conversation = ? AND createdAt = ? AND role = ? AND text = ?',
        whereArgs: [name, fromCreatedAt, fromRole, fromText],
        orderBy: 'id ASC',
        limit: 1,
      );
      if (rows.isEmpty) return 0;
      anchor = (rows.first['id'] as num).toInt();
    }
    final removed = await db.delete(
      'chat',
      where: 'conversation = ? AND id >= ?',
      whereArgs: [name, anchor],
    );
    notifyListeners();
    return removed;
  }

  /// Oldest first, so the list reads like a conversation.
  Future<List<ChatMessage>> recentChat({
    int limit = 5000,
    String conversation = '',
  }) async {
    final db = _active;
    if (db == null) return const [];
    final name = conversation.trim();
    final rows = await db.query(
      'chat',
      where: name.isEmpty ? null : 'conversation = ?',
      whereArgs: name.isEmpty ? null : [name],
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.reversed.map(ChatMessage.fromMap).toList();
  }

  /// Every conversation that has at least one message, newest first.
  ///
  /// This is what the sidebar lists. The title is the stored one when the
  /// conversation has been named (generated or renamed) and the first thing
  /// the user said otherwise, because that is what a person recognises a chat
  /// by. [query] filters by title AND message text, so searching finds a chat
  /// by a device name mentioned three turns in, not only by its title.
  Future<List<Map<String, dynamic>>> conversations({
    int limit = 200,
    String query = '',
  }) async {
    final db = _active;
    if (db == null) return const [];
    final q = query.trim();
    final rows = await db.rawQuery(
      'SELECT c.conversation AS id, COUNT(*) AS messages, MAX(c.id) AS lastId, '
      'MAX(c.createdAt) AS updatedAt, '
      '(SELECT title FROM conversations v WHERE v.id = c.conversation) '
      '  AS storedTitle, '
      '(SELECT project FROM conversations v WHERE v.id = c.conversation) '
      '  AS project, '
      '(SELECT summary FROM conversations v WHERE v.id = c.conversation) '
      '  AS summary '
      'FROM chat c '
      '${q.isEmpty ? '' : 'WHERE c.conversation IN ('
          'SELECT conversation FROM chat WHERE text LIKE ? '
          'UNION SELECT id FROM conversations WHERE title LIKE ?) '}'
      'GROUP BY c.conversation ORDER BY lastId DESC LIMIT ?',
      q.isEmpty ? [limit] : ['%$q%', '%$q%', limit],
    );
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      // The column is aliased to `id` above; the group key is the
      // conversation name.
      final id = (row['id'] ?? 'default').toString();
      final stored = (row['storedTitle'] ?? '').toString().trim();
      var title = stored;
      if (title.isEmpty) {
        final first = await _active!.query(
          'chat',
          columns: ['text'],
          where: "conversation = ? AND role = 'user' AND text != ''",
          whereArgs: [id],
          orderBy: 'id ASC',
          limit: 1,
        );
        final raw = first.isEmpty ? '' : first.first['text'].toString();
        title = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      }
      final updatedAt = (row['updatedAt'] ?? '').toString();
      out.add({
        'id': id,
        'messages': (row['messages'] as num?)?.toInt() ?? 0,
        'updatedAt': updatedAt,
        'project': (row['project'] ?? '').toString(),
        'summary': (row['summary'] ?? '').toString(),
        'title': title.isEmpty
            ? 'New chat'
            : (title.length <= 60 ? title : '${title.substring(0, 60)}...'),
        // A timestamp the sidebar can group on without parsing strings in the
        // widget tree (SQLite stores MAX(createdAt) as the ISO text above).
        'at': DateTime.tryParse(updatedAt)?.millisecondsSinceEpoch ?? 0,
      });
    }
    return out;
  }

  /// Create the conversation record if it is not there yet, and keep its
  /// project link current. Cheap and idempotent: called on every send.
  Future<void> ensureConversation(
    String id, {
    String project = '',
    String title = '',
  }) async {
    if (_active == null) return;
    final name = id.trim().isEmpty ? 'default' : id.trim();
    final now = DateTime.now().toIso8601String();
    final existing = await _active!.query(
      'conversations',
      columns: ['id', 'title', 'project'],
      where: 'id = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (existing.isEmpty) {
      await _active!.insert('conversations', {
        'id': name,
        'title': title,
        'project': project,
        'createdAt': now,
        'updatedAt': now,
      });
    } else {
      await _active!.update(
        'conversations',
        {
          'updatedAt': now,
          if (project.isNotEmpty) 'project': project,
          // An explicit title only fills a blank one; a rename is never
          // overwritten by a later generated title.
          if (title.isNotEmpty && (existing.first['title'] ?? '').toString().isEmpty)
            'title': title,
        },
        where: 'id = ?',
        whereArgs: [name],
      );
    }
    notifyListeners();
  }

  Future<Map<String, dynamic>?> conversationMeta(String id) async {
    final db = _active;
    if (db == null) return null;
    final rows = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id.trim().isEmpty ? 'default' : id.trim()],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Rename a conversation. An empty title clears the stored one, so the
  /// sidebar falls back to the first message again.
  Future<void> renameConversation(String id, String title) async {
    if (_active == null) return;
    final name = id.trim().isEmpty ? 'default' : id.trim();
    await ensureConversation(name);
    await _active!.update(
      'conversations',
      {'title': title.trim(), 'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [name],
    );
    notifyListeners();
  }

  /// The compacted summary of the turns that no longer fit, kept so the app
  /// never has to summarize a summary.
  Future<void> setConversationSummary(
    String id,
    String summary, {
    int upToId = 0,
  }) async {
    if (_active == null) return;
    final name = id.trim().isEmpty ? 'default' : id.trim();
    await ensureConversation(name);
    await _active!.update(
      'conversations',
      {'summary': summary, 'summaryUpToId': upToId},
      where: 'id = ?',
      whereArgs: [name],
    );
  }

  Future<String> conversationSummary(String id) async {
    final meta = await conversationMeta(id);
    return (meta?['summary'] ?? '').toString();
  }

  /// The structured session state (layer 2) for a conversation.
  Future<void> setSessionState(String id, String stateJson) async {
    if (_active == null) return;
    final name = id.trim().isEmpty ? 'default' : id.trim();
    await ensureConversation(name);
    await _active!.update(
      'conversations',
      {'stateJson': stateJson},
      where: 'id = ?',
      whereArgs: [name],
    );
  }

  Future<String> sessionStateJson(String id) async {
    final meta = await conversationMeta(id);
    return (meta?['stateJson'] ?? '{}').toString();
  }

  // --- exact change log ---------------------------------------------------
  // Network edits are recorded as structured transactions, not as prose in
  // the transcript. "Undo the change you made to Router1" then has ONE
  // correct answer that can be looked up, instead of a model guessing which
  // value it typed earlier.

  Future<int> logChange({
    required String conversation,
    required String device,
    required String field,
    required String oldValue,
    required String newValue,
    String interface = '',
    String source = '',
  }) async {
    if (_active == null) return -1;
    final id = await _active!.insert('changes', {
      'conversation': conversation.trim().isEmpty
          ? 'default'
          : conversation.trim(),
      'device': device,
      'interface': interface,
      'field': field,
      'oldValue': oldValue,
      'newValue': newValue,
      'source': source,
      'createdAt': DateTime.now().toIso8601String(),
    });
    notifyListeners();
    return id;
  }

  /// Newest first. [device] narrows it to one device, which is what
  /// "undo the change to Router1" asks for.
  Future<List<Map<String, dynamic>>> recentChanges({
    String conversation = '',
    String device = '',
    int limit = 50,
  }) async {
    final db = _active;
    if (db == null) return const [];
    final clauses = <String>[];
    final args = <Object?>[];
    final name = conversation.trim();
    if (name.isNotEmpty) {
      clauses.add('conversation = ?');
      args.add(name);
    }
    if (device.trim().isNotEmpty) {
      clauses.add('lower(device) = ?');
      args.add(device.trim().toLowerCase());
    }
    final rows = await db.query(
      'changes',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: clauses.isEmpty ? null : args,
      orderBy: 'actionId DESC',
      limit: limit,
    );
    return rows;
  }

  /// The change an "undo that" is about: the newest one, optionally for one
  /// device, that has not already been undone.
  Future<Map<String, dynamic>?> lastChange({
    String conversation = '',
    String device = '',
  }) async {
    final rows = await recentChanges(
      conversation: conversation,
      device: device,
      limit: 20,
    );
    for (final row in rows) {
      if ((row['undoneAt'] ?? '').toString().isEmpty) return row;
    }
    return null;
  }

  Future<void> markChangeUndone(int actionId) async {
    if (_active == null) return;
    await _active!.update(
      'changes',
      {'undoneAt': DateTime.now().toIso8601String()},
      where: 'actionId = ?',
      whereArgs: [actionId],
    );
    notifyListeners();
  }

  Future<void> _pruneChat() async {
    await _active!.rawDelete(
      'DELETE FROM chat WHERE id NOT IN '
      '(SELECT id FROM chat ORDER BY id DESC LIMIT ?)',
      [chatRetention],
    );
  }

  /// Delete one conversation, or every conversation when none is named.
  ///
  /// Deleting a chat takes everything that belongs to it: the transcript, the
  /// title/summary/state record, and its change log. Leaving the change log
  /// behind would let a later "undo that" reach for an edit from a chat the
  /// user deleted.
  Future<void> clearChat({String conversation = ''}) async {
    final name = conversation.trim();
    await _active!.delete(
      'chat',
      where: name.isEmpty ? null : 'conversation = ?',
      whereArgs: name.isEmpty ? null : [name],
    );
    await _active!.delete(
      'conversations',
      where: name.isEmpty ? null : 'id = ?',
      whereArgs: name.isEmpty ? null : [name],
    );
    await _active!.delete(
      'changes',
      where: name.isEmpty ? null : 'conversation = ?',
      whereArgs: name.isEmpty ? null : [name],
    );
    notifyListeners();
  }

  Future<void> clearAll() async {
    await _active!.delete('builds');
    await _active!.delete('attempts');
    await _active!.delete('rules');
    await _active!.delete('prefs');
    await _active!.delete('chat');
    await _active!.delete('conversations');
    await _active!.delete('changes');
    await _active!.delete('phrasing');
    await _active!.delete('environment_profile');
    await _active!.delete('clarification_answer');
    PhrasingMemoryService.clearIndex();
    notifyListeners();
  }

  /// Summaries for prompt injection.
  static List<String> summaries(List<BuildRecord> builds) => builds
      .map(
        (b) =>
            '${b.projectName} [${b.target}] ${b.status.toUpperCase()}: ${b.instruction} ${b.fix != null ? "fix=${b.fix}" : ""}',
      )
      .toList();

  static List<String> attemptSummaries(List<BuildAttempt> attempts) => attempts
      .map(
        (a) =>
            '${a.projectName} [${a.target}] ${a.status}: '
            '${a.failureKind ?? "no failure"}'
            '${a.failureDetail == null ? "" : " detail=${a.failureDetail}"}'
            '${a.correction == null ? "" : " correction=${a.correction}"}',
      )
      .toList();

  /// Distill a correction into a reusable rule (offline heuristic v1).
  static String distillRule({
    required NetworkIntent intent,
    required String userFix,
  }) {
    final t = userFix.trim();
    if (t.isEmpty) return '';
    // Keep it short + target-scoped.
    return 'Prefer user correction for ${intent.projectName} [${intent.routing}]: $t'
        .trim();
  }
}
