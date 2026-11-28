import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_diagnostics.dart';
import 'app_version.dart';
import 'memory_service.dart';
import 'pkt_build_job_service.dart';
import 'stored_privacy.dart';

/// One self-contained, local-only training export.
///
/// The file is a single JSON document so it can be moved by any means the user
/// already has (email, USB, chat, cloud drive) without a server, a new
/// dependency or a proprietary container. Binary attachments and generated
/// files are embedded as base64 with a SHA-256 hash, and every path written by
/// the app is rewritten to the path inside this document so the export does
/// not carry the sender's home directory.
class ChatExportResult {
  final Uint8List bytes;
  final String fileName;
  final int conversations;
  final int messages;
  final int files;
  final int omitted;

  const ChatExportResult({
    required this.bytes,
    required this.fileName,
    required this.conversations,
    required this.messages,
    required this.files,
    required this.omitted,
  });
}

class ChatExportService {
  ChatExportService._();

  static const format = 'netbuilder-training-export';
  static const version = 1;

  /// A single attachment larger than this is listed as omitted instead of
  /// making the whole export fail. Chat images and generated .pkt saves are
  /// normally far below it.
  static const defaultMaxFileBytes = 20 * 1024 * 1024;

  /// The whole embedded-file budget. The JSON text is larger than this because
  /// of base64, so the cap is deliberately below what a phone can comfortably
  /// hold in memory.
  static const defaultMaxTotalFileBytes = 80 * 1024 * 1024;

  static const _maxFiles = 200;
  static const _allowedExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.pkt',
    '.json',
    '.txt',
    '.md',
    '.xml',
    '.cfg',
    '.conf',
  };

  /// Build the export from the real local store and the app's own file areas.
  static Future<ChatExportResult> export({
    required MemoryService memory,
    PktBuildJobService? buildJobs,
    Directory? documents,
    Future<String> Function()? diagnostics,
  }) async {
    final memoryText = await memory.exportJson();
    final memoryMap = Map<String, dynamic>.from(jsonDecode(memoryText) as Map);
    final open = await memory.openQuestions(limit: 200);
    final jobs = buildJobs ?? PktBuildJobService.instance;
    await jobs.loadHistory();
    final docs = documents ?? await getApplicationDocumentsDirectory();
    final log = await (diagnostics ?? AppDiagnostics.instance.exportText)();
    return buildBundle(
      memory: memoryMap,
      buildJobs: [for (final entry in jobs.history) entry.toJson()],
      openQuestions: [
        for (final question in open)
          {
            'question': question.question,
            'hits': question.hits,
            'lastSeenAt': question.lastSeenAt,
          },
      ],
      documents: docs,
      appLog: log,
      appVersion: AppVersion.full,
      platform: Platform.operatingSystem,
      platformVersion: Platform.operatingSystemVersion,
    );
  }

  /// The pure part, so the format can be tested without a database, a plugin
  /// or a real documents directory.
  static ChatExportResult buildBundle({
    required Map<String, dynamic> memory,
    List<Map<String, dynamic>> buildJobs = const [],
    List<Map<String, dynamic>> openQuestions = const [],
    required Directory documents,
    String appLog = '',
    String appVersion = '',
    String platform = '',
    String platformVersion = '',
    DateTime? now,
    int maxFileBytes = defaultMaxFileBytes,
    int maxTotalFileBytes = defaultMaxTotalFileBytes,
  }) {
    final exportedAt = now ?? DateTime.now();
    final files = <_ExportFile>[];
    final omitted = <Map<String, dynamic>>[];
    final takenNames = <String>{};
    final seenPaths = <String>{};
    final pathMap = <String, String>{};
    var totalBytes = 0;

    String normalized(String path) {
      try {
        return p.normalize(p.absolute(path));
      } catch (_) {
        return path;
      }
    }

    String keyOf(String path) {
      final value = normalized(path);
      return Platform.isWindows ? value.toLowerCase() : value;
    }

    void omit(String path, int size, String reason) {
      // Keep the absolute path out of the exported database even when the
      // file itself is too large to embed. The manifest still names it, so a
      // reader can tell what was left out.
      pathMap[normalized(path)] = _uniqueName(
        kind: 'omitted',
        original: p.basename(path),
        taken: takenNames,
      );
      omitted.add({'name': p.basename(path), 'bytes': size, 'reason': reason});
    }

    void addFile(String path, String kind) {
      if (path.trim().isEmpty) return;
      final file = File(path);
      if (!file.existsSync()) return;
      final extension = p.extension(file.path).toLowerCase();
      if (!_allowedExtensions.contains(extension)) return;
      final key = keyOf(file.path);
      if (!seenPaths.add(key)) return;
      int size;
      try {
        size = file.lengthSync();
      } catch (_) {
        return;
      }
      if (size <= 0) return;
      if (size > maxFileBytes) {
        omit(file.path, size, 'larger than the per-file limit');
        return;
      }
      if (files.length >= _maxFiles) {
        omit(file.path, size, 'file-count limit reached');
        return;
      }
      if (totalBytes + size > maxTotalFileBytes) {
        omit(file.path, size, 'total file-size budget reached');
        return;
      }
      Uint8List bytes;
      try {
        bytes = file.readAsBytesSync();
      } catch (_) {
        omit(file.path, size, 'could not be read');
        return;
      }
      final archiveName = _uniqueName(
        kind: kind,
        original: p.basename(file.path),
        taken: takenNames,
      );
      files.add(_ExportFile(archiveName, kind, bytes));
      pathMap[normalized(file.path)] = archiveName;
      totalBytes += bytes.length;
    }

    // 1. Every attachment referenced by a chat turn.
    final chatRows = _rows(memory['chat']);
    for (final row in chatRows) {
      for (final image in _rows(row['images'])) {
        addFile('${image['path'] ?? ''}', 'chat');
      }
    }

    // 2. Generated files the app remembers, including the companion manifest
    // that distinguishes a generated save from a hand-made one.
    for (final job in buildJobs) {
      final filePath = '${job['filePath'] ?? ''}'.trim();
      final savedLocation = '${job['savedLocation'] ?? ''}'.trim();
      addFile(filePath, 'generated');
      addFile(savedLocation, 'generated');
      if (filePath.isNotEmpty) {
        addFile('$filePath.netbuilder.json', 'generated');
      }
    }

    // 3. Files still sitting in the app's own working areas. This is the part
    // that catches a generated .pkt or chat screenshot the history has not
    // referenced (for example, a build whose row was dismissed).
    final appFolders = [
      Directory(p.join(documents.path, 'netbuilder', 'chat')),
      Directory(p.join(documents.path, 'pkt')),
    ];
    for (final folder in appFolders) {
      if (!folder.existsSync()) continue;
      final kind = folder.path.endsWith(p.join('netbuilder', 'chat'))
          ? 'chat'
          : 'generated';
      try {
        for (final entity in folder.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) addFile(entity.path, kind);
        }
      } catch (_) {
        // One unreadable folder must not lose the rest of the export.
      }
    }

    // 4. Paths inside the database are rewritten to the export's own names.
    // This keeps a chat image or build history entry useful without exposing
    // the sender's absolute file layout.
    dynamic rewrite(dynamic value) {
      if (value is String) {
        return pathMap[normalized(value)] ?? value;
      }
      if (value is Map) {
        return {
          for (final entry in value.entries) entry.key: rewrite(entry.value),
        };
      }
      if (value is List) return [for (final item in value) rewrite(item)];
      return value;
    }

    final rewrittenMemory = Map<String, dynamic>.from(rewrite(memory) as Map)
      // Local preferences (theme, output folder, last selection) are not part
      // of what the app was asked to do, and they can carry a home-directory
      // path. They stay on the device; the rest of the record travels.
      ..remove('prefs');
    final rewrittenJobs = [
      for (final job in buildJobs)
        // Build history is stored outside the memory database, so it gets the
        // same redaction pass rather than being trusted because it is local.
        Map<String, dynamic>.from(StoredPrivacy.redact(rewrite(job)) as Map),
    ];

    final conversations = _rows(rewrittenMemory['conversations']);
    final conversationById = {
      for (final row in conversations) '${row['id'] ?? ''}': row,
    };
    final training = <Map<String, dynamic>>[];
    for (final row in _rows(rewrittenMemory['chat'])) {
      final conversation = '${row['conversation'] ?? ''}';
      final meta = conversationById[conversation] ?? const <String, dynamic>{};
      training.add({
        'conversation': conversation,
        'title': '${meta['title'] ?? ''}',
        'project': '${meta['project'] ?? ''}',
        'role': '${row['role'] ?? ''}',
        'text': '${row['text'] ?? ''}',
        'createdAt': '${row['createdAt'] ?? ''}',
        if ('${row['source'] ?? ''}'.trim().isNotEmpty)
          'source': '${row['source']}',
        if (_rows(row['images']).isNotEmpty) 'images': row['images'],
        if (_rows(row['actions']).isNotEmpty) 'actions': row['actions'],
        if (row['executed'] is List && (row['executed'] as List).isNotEmpty)
          'executed': row['executed'],
      });
    }

    final fileEntries = [
      for (final file in files)
        {
          'path': file.path,
          'kind': file.kind,
          'name': p.basename(file.path),
          'bytes': file.bytes.length,
          'sha256': sha256.convert(file.bytes).toString(),
          'data': base64Encode(file.bytes),
        },
    ];

    final document = <String, dynamic>{
      'format': format,
      'version': version,
      'exportedAt': exportedAt.toUtc().toIso8601String(),
      'app': {
        'version': appVersion,
        'platform': platform,
        'platformVersion': platformVersion,
      },
      'privacy': {
        'localOnly': true,
        'secrets':
            'API keys, passwords and secure-storage values are excluded. '
            'The app redacts credentials in its text fields before this '
            'document is assembled.',
        'review':
            'Review this file before sharing it. Chats can contain network '
            'details, and generated .pkt files can contain lab credentials.',
      },
      'counts': {
        'conversations': conversations.length,
        'messages': training.length,
        'files': files.length,
        'omitted': omitted.length,
      },
      'readme':
          'This is a NetBuilder training export. "memory" is the app record '
          '(conversations, turns, builds, attempts, changes, rules, learned '
          'answers, concepts, clarification answers and environment profile). '
          '"training" is one flat turn per entry for fine-tuning. '
          '"openQuestions" are questions the offline material could not '
          'answer. "buildJobs" records generated files and their status. '
          '"files" embeds attachments and generated files as base64, with '
          'SHA-256 checksums; "omitted" lists anything the size limits left '
          'out. Nothing here was uploaded by the app.',
      'memory': rewrittenMemory,
      'training': training,
      'openQuestions': openQuestions,
      'buildJobs': rewrittenJobs,
      'files': fileEntries,
      'omitted': omitted,
      if (appLog.trim().isNotEmpty) 'appLog': appLog,
    };

    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(document)));
    return ChatExportResult(
      bytes: bytes,
      fileName: suggestedName(exportedAt),
      conversations: conversations.length,
      messages: training.length,
      files: files.length,
      omitted: omitted.length,
    );
  }

  static String suggestedName([DateTime? now]) {
    final at = now ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'netbuilder-training-export-${at.year}-${two(at.month)}-'
        '${two(at.day)}-${two(at.hour)}${two(at.minute)}.json';
  }

  static List<Map<String, dynamic>> _rows(Object? value) => [
    for (final row in value is List ? value : const [])
      if (row is Map) Map<String, dynamic>.from(row),
  ];

  static String _uniqueName({
    required String kind,
    required String original,
    required Set<String> taken,
  }) {
    final safe = original
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'^\.+'), 'file');
    final folder = switch (kind) {
      'chat' => 'files/chat',
      'generated' => 'files/generated',
      'omitted' => 'files/omitted',
      _ => 'files/other',
    };
    var candidate = '$folder/${safe.isEmpty ? 'file' : safe}';
    var counter = 2;
    while (!taken.add(candidate)) {
      final extension = p.extension(safe);
      final stem = extension.isEmpty
          ? safe
          : safe.substring(0, safe.length - extension.length);
      candidate = '$folder/${stem.isEmpty ? 'file' : stem}-$counter$extension';
      counter++;
    }
    return candidate;
  }
}

class _ExportFile {
  final String path;
  final String kind;
  final Uint8List bytes;

  const _ExportFile(this.path, this.kind, this.bytes);
}
