import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/chat_message.dart';
import 'context_budget.dart';

/// One parsed assistant turn.
class ChatReply {
  final String text;
  final List<ChatAction> actions;
  final List<String> questions;

  const ChatReply({
    required this.text,
    this.actions = const [],
    this.questions = const [],
  });

  bool get isEmpty => text.trim().isEmpty && actions.isEmpty;
}

/// Result of trying to attach an image.
class AttachResult {
  final ChatImage? image;
  final String error;

  const AttachResult({this.image, this.error = ''});
  bool get ok => image != null;
}

/// Conversational, vision-capable front end for the same Gemini key the
/// planner uses.
///
/// Two things this deliberately does NOT do:
///
/// * It never executes an action. The model returns proposals, the UI renders
///   each one behind an approve button, and only a click runs it. A model
///   answer therefore cannot change a device on its own - the same rule the
///   rest of the app follows (fail closed, show the evidence).
/// * It never lets the model write executable CLI for the *plan*. Planning
///   still goes through the deterministic adapter; chat CLI actions are
///   corrections the user reads and approves line by line.
class ChatService {
  final http.Client _client;

  /// The context ceiling this client builds requests against. Defaults to
  /// [ContextBudget.defaultContextTokens] (~256k) and can be set from
  /// Settings, so the ceiling is a documented value, not a hardcoded one.
  final int? contextTokens;

  /// What the last request actually carried: turns sent, tokens used and
  /// how many earlier turns were compacted into memory. The chat UI shows
  /// this so the user can see the memory working.
  ContextPlan? lastPlan;

  ChatService({http.Client? client, this.contextTokens})
    : _client = client ?? http.Client();

  /// Per-image cap. Real evidence screenshots are 140-300 KB, so this is a
  /// guard against someone attaching a huge export, not a working limit.
  static const maxImageBytes = 8 * 1024 * 1024;
  /// Cap on the base64 payload of one request (Gemini's inline limit is
  /// 20 MB including text).
  static const maxRequestBytes = 15 * 1024 * 1024;
  static const maxImagesPerTurn = 4;

  String _url(String model) =>
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';

  Map<String, String> _headers(String apiKey) => {
    'Content-Type': 'application/json',
    'x-goog-api-key': apiKey,
  };

  /// Send one turn: the conversation so far, the new text, and any images.
  ///
  /// [attachments] are attached to the CURRENT user turn only. Replaying
  /// every historical screenshot would multiply the request size for no
  /// benefit - the model already has its own earlier conclusions in the text.
  Future<ChatReply> send({
    required String apiKey,
    required String model,
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    List<ChatImage> attachments = const [],
    int? contextTokens,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw Exception(
        'No Gemini API key. Add one in Settings - chat needs a model to talk to.',
      );
    }

    // THE CONTEXT WINDOW. The whole conversation is considered and only
    // what genuinely does not fit is compacted into a memory block. There
    // is no turn cap: the old `historyLimit = 20` (plus a 60-message load
    // and a 200-row retention) is exactly why the chat forgot a request
    // made at the start of a session.
    final plan = ContextBudget.plan(
      history: history,
      systemContext: systemContext,
      pendingText: text,
      budgetTokens: contextTokens ?? this.contextTokens,
    );
    lastPlan = plan;

    final contents = <Map<String, dynamic>>[];
    for (final turn in plan.recentTurns) {
      if (turn.actions.isNotEmpty && turn.text.trim().isEmpty) {
        // A turn that was only proposals: keep the prose the user read.
        continue;
      }
      contents.add(turn.toGeminiTurn());
    }

    final parts = <Map<String, dynamic>>[
      {'text': text.trim().isEmpty ? '(look at the attached image)' : text},
    ];
    var inlineBytes = 0;
    for (final image in attachments.take(maxImagesPerTurn)) {
      final encoded = await readBase64(image);
      if (encoded.isEmpty) continue;
      inlineBytes += encoded.length;
      parts.add({
        'inlineData': {'mimeType': image.mimeType, 'data': encoded},
      });
    }
    if (inlineBytes > maxRequestBytes) {
      throw Exception(
        'Those images are too large to send in one request '
        '(${(inlineBytes / (1024 * 1024)).round()} MB). Attach fewer or smaller ones.',
      );
    }
    contents.add({'role': 'user', 'parts': parts});

    final r = await _client
        .post(
          Uri.parse(_url(model)),
          headers: _headers(key),
          body: jsonEncode({
            'contents': contents,
            'systemInstruction': {
              'parts': [
                {
                  'text': plan.memoryBlock.isEmpty
                      ? systemContext
                      : '$systemContext\n\n${plan.memoryBlock}',
                },
              ],
            },
            'generationConfig': {'responseMimeType': 'application/json'},
          }),
        )
        .timeout(const Duration(seconds: 90));

    if (r.statusCode != 200) {
      throw Exception(_friendlyError(r.statusCode, r.body, model));
    }
    return parseReply(_extractText(r.body));
  }

  String _streamUrl(String model) =>
      'https://generativelanguage.googleapis.com/v1beta/models/'
      '$model:streamGenerateContent?alt=sse';

  /// The text carried by one SSE buffer. Pure, so the parser can be
  /// tested with a fixture instead of a live connection.
  static String sseText(String raw) {
    final out = StringBuffer();
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        out.write(_textFromJson(jsonDecode(payload)));
      } catch (_) {
        // A half-arrived line: the caller keeps it in its buffer.
      }
    }
    return out.toString();
  }

  static String _textFromJson(dynamic decoded) {
    if (decoded is! Map) return '';
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) return '';
    final content = candidates.first['content'] as Map?;
    final parts = content?['parts'] as List?;
    if (parts == null) return '';
    final b = StringBuffer();
    for (final part in parts) {
      final piece = (part as Map)['text'];
      if (piece is String) b.write(piece);
    }
    return b.toString();
  }

  /// Send one turn and yield the answer AS IT ARRIVES.
  ///
  /// Same budget, same memory block and same request as [send] - only the
  /// transport differs (server-sent events), so the chat can show the
  /// answer growing instead of a spinner.
  Stream<String> stream({
    required String apiKey,
    required String model,
    required List<ChatMessage> history,
    required String text,
    required String systemContext,
    List<ChatImage> attachments = const [],
    int? contextTokens,
  }) async* {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw Exception(
        'No Gemini API key. Add one in Settings - chat needs a model to talk to.',
      );
    }
    final plan = ContextBudget.plan(
      history: history,
      systemContext: systemContext,
      pendingText: text,
      budgetTokens: contextTokens ?? this.contextTokens,
    );
    lastPlan = plan;
    final contents = <Map<String, dynamic>>[];
    for (final turn in plan.recentTurns) {
      if (turn.actions.isNotEmpty && turn.text.trim().isEmpty) continue;
      contents.add(turn.toGeminiTurn());
    }
    final parts = <Map<String, dynamic>>[
      {'text': text.trim().isEmpty ? '(look at the attached image)' : text},
    ];
    for (final image in attachments.take(maxImagesPerTurn)) {
      final encoded = await readBase64(image);
      if (encoded.isEmpty) continue;
      parts.add({
        'inlineData': {'mimeType': image.mimeType, 'data': encoded},
      });
    }
    contents.add({'role': 'user', 'parts': parts});

    final request = http.Request('POST', Uri.parse(_streamUrl(model)));
    request.headers.addAll(_headers(key));
    request.body = jsonEncode({
      'contents': contents,
      'systemInstruction': {
        'parts': [
          {
            'text': plan.memoryBlock.isEmpty
                ? systemContext
                : '$systemContext\n\n${plan.memoryBlock}',
          },
        ],
      },
      'generationConfig': {'responseMimeType': 'application/json'},
    });
    final response = await _client.send(request);
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw Exception(_friendlyError(response.statusCode, body, model));
    }
    // A chunk can split a line, so keep the tail and only parse complete
    // lines - otherwise a JSON payload cut in half would be dropped.
    var buffer = '';
    await for (final piece in response.stream.transform(utf8.decoder)) {
      buffer += piece;
      final lines = buffer.split('\n');
      buffer = lines.removeLast();
      final delta = sseText('${lines.join('\n')}\n');
      if (delta.isNotEmpty) yield delta;
    }
    final tail = sseText(buffer);
    if (tail.isNotEmpty) yield tail;
  }

  /// Read the model text out of a generateContent response body.
  static String _extractText(String body) {
    final j = jsonDecode(body) as Map<String, dynamic>;
    final candidates = j['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('Gemini returned no candidates');
    }
    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      throw Exception('Gemini returned no parts');
    }
    return parts
        .map((part) => (part as Map)['text']?.toString() ?? '')
        .join()
        .trim();
  }

  /// Parse `{"reply": ..., "actions": [...], "questions": [...]}`.
  ///
  /// Tolerant on purpose: a model that ignores the schema and answers with
  /// plain prose should still be readable rather than shown as an error.
  static ChatReply parseReply(String raw) {
    var cleaned = raw.trim();
    if (cleaned.startsWith('```')) {
      cleaned = cleaned
          .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '')
          .trim();
    }
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {
      data = null;
    }
    if (data == null) {
      // Fall back to the first JSON object in the text, then to prose.
      final match = RegExp(r'\{[\s\S]*\}').firstMatch(cleaned);
      if (match != null) {
        try {
          final decoded = jsonDecode(match.group(0)!);
          if (decoded is Map<String, dynamic>) data = decoded;
        } catch (_) {}
      }
    }
    if (data == null) {
      return ChatReply(text: cleaned);
    }
    final questions = <String>[];
    final rawQuestions = data['questions'];
    if (rawQuestions is List) {
      for (final q in rawQuestions) {
        final text = q.toString().trim();
        if (text.isNotEmpty) questions.add(text);
      }
    }
    return ChatReply(
      text: (data['reply'] ?? data['text'] ?? '').toString().trim(),
      actions: ChatAction.parseList(data['actions']),
      questions: questions,
    );
  }

  /// The instructions the chat model works from.
  ///
  /// [liveState] is filled in only when the user turns live context on: it
  /// carries the running summary, the recent journal events and the blockers,
  /// which is what makes "what is it stuck on right now?" answerable.
  static String systemContext({
    required String target,
    required String rulePacks,
    required List<String> learnedRules,
    required Map<String, String> preferences,
    required List<String> knownBlockers,
    required List<String> unsupportedCapabilities,
    required String liveState,
  }) {
    final sb = StringBuffer();
    sb.writeln(
      'You are the NetBuilder AI assistant, running inside a local desktop '
      'app that builds and repairs Cisco labs in Packet Tracer and GNS3.',
    );
    sb.writeln();
    sb.writeln('## How this app works (do not contradict this)');
    sb.writeln(
      '- A "plan" is validated locally, then executed by an autopilot that '
      'clicks and types in Packet Tracer and verifies every step on screen.',
    );
    sb.writeln(
      '- The app is fail-closed: if it cannot prove a step worked, it reports '
      'the step instead of guessing. Never tell the user something is done '
      'unless the app reported it verified.',
    );
    sb.writeln(
      '- The autopilot refuses to blind-type when it cannot read the screen. '
      '"the CLI prompt was not proven" is that safety rule firing, not a bug '
      'to work around by typing harder.',
    );
    sb.writeln(
      '- An ASA firewall and some Packet Tracer features are not IOS and/or '
      'not implemented. Say so plainly rather than emitting commands for them.',
    );
    sb.writeln(
      '- Never invent credentials (passwords, pre-shared keys, usernames). '
      'If one is needed, ask for it.',
    );
    sb.writeln();
    sb.writeln('## Current target: $target');
    if (rulePacks.trim().isNotEmpty) {
      sb.writeln(rulePacks.trim());
    }
    if (learnedRules.isNotEmpty) {
      sb.writeln();
      sb.writeln('## Rules the user already taught the app');
      for (final rule in learnedRules.take(20)) {
        sb.writeln('- $rule');
      }
    }
    if (preferences.isNotEmpty) {
      sb.writeln();
      sb.writeln('## User preferences');
      preferences.forEach((k, v) => sb.writeln('- $k=$v'));
    }
    if (knownBlockers.isNotEmpty) {
      sb.writeln();
      sb.writeln(
        '## Known blockers from previous runs (these already failed and '
        'never recovered)',
      );
      for (final line in knownBlockers.take(12)) {
        sb.writeln(line.startsWith('-') ? line : '- $line');
      }
      sb.writeln(
        'Treat these as the most likely reason a run is stuck, and prefer a '
        'different approach over repeating them.',
      );
    }
    if (unsupportedCapabilities.isNotEmpty) {
      sb.writeln();
      sb.writeln('## Packet Tracer cannot do these on this setup');
      for (final line in unsupportedCapabilities.take(12)) {
        sb.writeln(line.startsWith('-') ? line : '- $line');
      }
    }
    if (liveState.trim().isNotEmpty) {
      sb.writeln();
      sb.writeln('## Live run state (just read from the sidecar)');
      sb.writeln(liveState.trim());
    }
    sb.writeln();
    sb.writeln('## How to answer (this is what makes you useful)');
    sb.writeln(
      '- USE THE CONVERSATION. Everything above is the source of truth. '
      'When the user says "it", "that", "the first thing" or "as I '
      'asked", they mean an earlier request in this conversation - go '
      'back, find it, and name it ("you asked for X, so ..."). NEVER '
      'ask the user to repeat something they already said here.',
    );
    sb.writeln(
      '- LEAD WITH THE ANSWER. The first sentence answers the question. '
      'Detail after.',
    );
    sb.writeln(
      '- GIVE GUIDANCE, NOT FILLER. 2-5 concrete steps, the exact '
      'commands/addresses/model names where they apply, and what to check '
      'afterwards. Say what you would do, and why.',
    );
    sb.writeln(
      '- ASK WHEN IT MATTERS. If the request is ambiguous in a way that '
      'changes the answer, ask ONE short clarifying question - but still '
      'answer for the most likely reading so the user is not left waiting.',
    );
    sb.writeln(
      '- USE THE REAL NAMES. If a plan or project was discussed, refer to '
      'its actual device names, interfaces and addresses.',
    );
    sb.writeln();
    sb.writeln('## What you can propose');
    sb.writeln(
      'You cannot act directly. You propose actions and the user approves '
      'each one with a click. Use only these kinds:',
    );
    sb.writeln(
      '- {"kind":"save_rule","rule":"...","targets":"all|<target>"} - a '
      'durable instruction for future plans.',
    );
    sb.writeln(
      '- {"kind":"save_preference","key":"...","value":"..."} - a small '
      'setting the user wants remembered.',
    );
    sb.writeln(
      '- {"kind":"paste_cli","configs":{"<device>":"<one command per '
      'line>"}} - corrections typed into that device and verified.',
    );
    sb.writeln(
      '- {"kind":"config_pcs","pcs":{"<pc>":{"ip":"...","mask":"...",'
      '"gw":"..."}}} - Desktop IP configuration.',
    );
    sb.writeln(
      '- {"kind":"run_control","command":"pause"|"resume"|"stop"} - control '
      'a run that is already going.',
    );
    sb.writeln(
      '- {"kind":"open_project","project":"<name>"} - bring a project up for '
      'review.',
    );
    sb.writeln();
    sb.writeln('## Output format');
    sb.writeln(
      'Reply with STRICT JSON only, no code fences, no prose outside it:',
    );
    sb.writeln(
      '{"reply":"<what you would say to the user, markdown allowed>",'
      '"actions":[<zero or more actions>],"questions":["<only questions '
      'whose answer changes what you propose>"]}',
    );
    sb.writeln(
      'Rules for actions: at most 3 per turn; keep CLI to a handful of short '
      'lines; every CLI line must be real IOS for that device type; when a '
      'screenshot or the live state is enough to answer, do not propose '
      'actions at all.',
    );
    return sb.toString();
  }

  /// Persist an attachment under the app documents folder and return it.
  ///
  /// Returns [AttachResult] rather than throwing so the UI can show why an
  /// image was rejected (too large, unreadable) instead of failing silently.
  Future<AttachResult> persistImage({
    required List<int> bytes,
    required String name,
    String mimeType = 'image/png',
  }) async {
    if (bytes.isEmpty) {
      return const AttachResult(error: 'That image was empty.');
    }
    if (bytes.length > maxImageBytes) {
      return AttachResult(
        error:
            'That image is ${(bytes.length / (1024 * 1024)).toStringAsFixed(1)} MB; '
            'the limit is ${maxImageBytes ~/ (1024 * 1024)} MB.',
      );
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(dir.path, 'netbuilder', 'chat'));
      if (!await folder.exists()) await folder.create(recursive: true);
      final safe = p.basename(name).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final file = File(p.join(folder.path, '${stamp}_$safe'));
      await file.writeAsBytes(bytes, flush: true);
      return AttachResult(
        image: ChatImage(
          path: file.path,
          name: safe,
          mimeType: mimeType,
          bytes: bytes.length,
        ),
      );
    } catch (e) {
      return AttachResult(error: 'Could not save that image: $e');
    }
  }

  /// Read an attachment back as base64, or '' when it is gone.
  Future<String> readBase64(ChatImage image) async {
    try {
      final file = File(image.path);
      if (!await file.exists()) return '';
      final bytes = await file.readAsBytes();
      return base64Encode(bytes);
    } catch (_) {
      return '';
    }
  }

  String _friendlyError(int code, String body, String model) {
    final short = body.length > 500 ? '${body.substring(0, 500)}...' : body;
    if (code == 404) {
      return 'HTTP 404: model "$model" is not available for this key. '
          'Pick gemini-3.8-flash in Settings. Server: $short';
    }
    if (code == 400 && short.contains('API key not valid')) {
      return 'HTTP 400: API key not valid. Create one at '
          'aistudio.google.com. Server: $short';
    }
    if (code == 403) {
      return 'HTTP 403: key forbidden or billing not enabled. Server: $short';
    }
    if (code == 413) {
      return 'HTTP 413: the request (usually the images) was too large. '
          'Attach fewer screenshots and retry.';
    }
    return 'HTTP $code: $short';
  }
}
