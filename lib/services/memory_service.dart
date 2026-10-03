import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/build_record.dart';
import '../models/build_attempt.dart';
import '../models/chat_message.dart';
import '../models/network_intent.dart';
import 'phrasing_memory_service.dart';

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
      version: 7,
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

  /// The version stamped on [exportJson]. A backup whose shape can change
  /// silently is not a backup: this is what lets a reader (a future importer,
  /// a person) tell what it is looking at before trusting it.
  /// v2: adds the learned-phrasing table.
  static const exportSchemaVersion = 2;

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
