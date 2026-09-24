import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/build_record.dart';
import '../models/build_attempt.dart';
import '../models/chat_message.dart';
import '../models/network_intent.dart';

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
      version: 4,
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
      },
    );
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
 createdAt TEXT NOT NULL
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
    final rows = await _active!.query(
      'attempts',
      orderBy: 'id DESC',
      limit: limit,
    );
    return rows.map(BuildAttempt.fromMap).toList();
  }

  Future<List<BuildRecord>> recentBuilds({int limit = 20}) async {
    final rows = await _active!.query(
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
    final rows = await _active!.query('rules', orderBy: 'id DESC', limit: 100);
    return rows.map(LearnedRule.fromMap).toList();
  }

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
    final rows = await _active!.query('prefs', limit: 200);
    return {for (final r in rows) (r['k'] as String): (r['v'] as String)};
  }

  Future<String> exportJson() async {
    final builds = await recentBuilds(limit: 500);
    final rules = await allRules();
    final prefs = await allPrefs();
    return const JsonEncoder.withIndent('  ').convert({
      'builds': builds.map((b) => b.toMap()).toList(),
      'attempts': (await recentAttempts(
        limit: 500,
      )).map((a) => a.toMap()).toList(),
      'rules': rules.map((r) => r.toMap()).toList(),
      'prefs': prefs,
      'chat': (await recentChat(limit: 500)).map((c) => c.toMap()).toList(),
    });
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

  /// Oldest first, so the list reads like a conversation.
  Future<List<ChatMessage>> recentChat({
    int limit = 60,
    String conversation = '',
  }) async {
    final name = conversation.trim();
    final rows = await _active!.query(
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
  /// This is what the sidebar lists: the title is the first thing the user
  /// said, because that is what a person recognises a chat by.
  Future<List<Map<String, dynamic>>> conversations({int limit = 30}) async {
    final rows = await _active!.rawQuery(
      'SELECT conversation, COUNT(*) AS messages, MAX(id) AS lastId, '
      'MAX(createdAt) AS updatedAt FROM chat GROUP BY conversation '
      'ORDER BY lastId DESC LIMIT ?',
      [limit],
    );
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      final id = (row['conversation'] ?? 'default').toString();
      final first = await _active!.query(
        'chat',
        columns: ['text'],
        where: "conversation = ? AND role = 'user' AND text != ''",
        whereArgs: [id],
        orderBy: 'id ASC',
        limit: 1,
      );
      final raw = first.isEmpty ? '' : first.first['text'].toString();
      final title = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      out.add({
        'id': id,
        'messages': (row['messages'] as num?)?.toInt() ?? 0,
        'updatedAt': (row['updatedAt'] ?? '').toString(),
        'title': title.isEmpty
            ? 'New chat'
            : (title.length <= 60 ? title : '${title.substring(0, 60)}...'),
      });
    }
    return out;
  }

  Future<void> _pruneChat() async {
    await _active!.rawDelete(
      'DELETE FROM chat WHERE id NOT IN '
      '(SELECT id FROM chat ORDER BY id DESC LIMIT ?)',
      [chatRetention],
    );
  }

  /// Delete one conversation, or every conversation when none is named.
  Future<void> clearChat({String conversation = ''}) async {
    final name = conversation.trim();
    await _active!.delete(
      'chat',
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
