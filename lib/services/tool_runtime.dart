import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'tool_loop.dart';
import 'tool_protocol.dart';

/// The real wiring for the tool loop (spec §2, §3, §11).
///
/// It is the only place that knows how to talk to two things at once:
/// the model (already configured in [config]) and the sidecar's tool layer.
/// The model is told which tools exist; when it asks for one, the call goes to
/// `POST /tools/call` and the answer goes back as data. The model itself never
/// reads or writes a `.pkt`.
///
/// [client] is injected so the whole path can be tested without a network.
class ToolRuntime {
  final AiProviderConfig config;
  final String geminiKey;
  final String openaiKey;
  final String sidecarBase;
  final http.Client client;

  /// The capture the tools should be answered from (a server-side path).
  String capturePath;

  ToolRuntime({
    required this.config,
    required this.sidecarBase,
    this.geminiKey = '',
    this.openaiKey = '',
    this.capturePath = '',
    http.Client? client,
  }) : client = client ?? http.Client();

  List<Map<String, dynamic>> _tools = const [];

  /// Whether the engine actually offered tools. The chat falls back to the
  /// plain path when this is false, so a missing sidecar never breaks chat.
  bool get available => _tools.isNotEmpty;
  List<Map<String, dynamic>> get tools => List.unmodifiable(_tools);

  bool _loaded = false;

  /// Load once, and remember the answer: the chat may ask on every turn.
  Future<bool> ensureLoaded() async {
    if (_loaded) return available;
    _loaded = true;
    return load();
  }

  bool get isGemini => config.kind == AiProviderKind.gemini;

  /// Ask the engine which tools exist. Returns false if it cannot be reached.
  Future<bool> load() async {
    try {
      final uri = Uri.parse('${_base()}/tools/list');
      final response = await client.get(uri);
      if (response.statusCode != 200) return false;
      _tools = ToolProtocol.catalogue(jsonDecode(response.body));
      return _tools.isNotEmpty;
    } catch (_) {
      _tools = const [];
      return false;
    }
  }

  /// The declarations to attach to the provider request.
  List<Map<String, dynamic>> declarations() => isGemini
      ? ToolProtocol.geminiDeclarations(_tools)
      : ToolProtocol.openAiDeclarations(_tools);

  /// One provider round-trip. [messages] are OpenAI-shaped (the loop's
  /// internal form); Gemini gets them translated.
  Future<Object?> send(List<Map<String, dynamic>> messages) async {
    final response = isGemini
        ? await client.post(
            Uri.parse('https://generativelanguage.googleapis.com/v1beta/'
                'models/${config.model}:generateContent'),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': geminiKey,
            },
            body: jsonEncode({
              'contents': _geminiContents(messages),
              // Gemini takes the system prompt out of band, not as a turn.
              if (_systemText(messages).isNotEmpty)
                'systemInstruction': {
                  'parts': [
                    {'text': _systemText(messages)},
                  ],
                },
              'tools': declarations(),
            }),
          )
        : await client.post(
            Uri.parse('${config.effectiveBaseUrl()}/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              if (openaiKey.trim().isNotEmpty)
                'Authorization': 'Bearer ${openaiKey.trim()}',
            },
            body: jsonEncode({
              'model': config.model,
              'messages': messages,
              'tools': declarations(),
            }),
          );

    if (response.statusCode != 200) {
      throw Exception(AiErrors.describe(
        status: response.statusCode,
        body: response.body,
        model: config.model,
      ));
    }
    return jsonDecode(response.body);
  }

  /// Run one tool through the engine's tool layer.
  ///
  /// A `modify` tool comes back as a **proposal** carrying
  /// `requiresApproval: true`; nothing is written here. Applying it remains
  /// the user's decision through the existing approval gate (spec §8).
  Future<Object?> execute(ToolCall call) async {
    final response = await client.post(
      Uri.parse('${_base()}/tools/call'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': call.name,
        'args': call.args,
        if (capturePath.trim().isNotEmpty) 'path': capturePath,
      }),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is Map && decoded['ok'] == false) {
      throw Exception(decoded['error']?.toString() ?? 'tool failed');
    }
    if (decoded is Map && decoded.containsKey('result')) return decoded['result'];
    return decoded;
  }

  /// The assistant text of a reply, for either provider.
  String extractText(Object? decoded) {
    if (decoded is! Map) return '';
    final candidates = decoded['candidates'];
    if (candidates is List && candidates.isNotEmpty) {
      final content = (candidates.first as Map)['content'];
      final parts = (content is Map) ? content['parts'] : null;
      if (parts is List) {
        final buffer = StringBuffer();
        for (final part in parts) {
          if (part is Map && part['text'] is String) buffer.write(part['text']);
        }
        return buffer.toString().trim();
      }
    }
    final choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final message = (choices.first as Map)['message'];
      if (message is Map) {
        final content = message['content'];
        if (content is String) return content.trim();
      }
    }
    return '';
  }

  /// A ready-to-run loop for this provider and capture.
  ToolLoop loop() => ToolLoop(
    send: send,
    execute: execute,
    extractText: extractText,
  );

  String _base() {
    var base = sidecarBase.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  /// The system prompt(s), which Gemini carries outside `contents`.
  static String _systemText(List<Map<String, dynamic>> messages) => messages
      .where((m) => m['role'] == 'system')
      .map((m) => m['content']?.toString() ?? '')
      .where((s) => s.trim().isNotEmpty)
      .join('\n\n');

  /// The loop's internal OpenAI-shaped messages as Gemini `contents`.
  static List<Map<String, dynamic>> _geminiContents(
    List<Map<String, dynamic>> messages,
  ) {
    final contents = <Map<String, dynamic>>[];
    for (final message in messages) {
      final role = message['role']?.toString() ?? 'user';
      if (role == 'system') continue; // handled as systemInstruction elsewhere

      final parts = <Map<String, dynamic>>[];
      final calls = message['tool_calls'];
      if (role == 'assistant' && calls is List) {
        for (final call in calls) {
          if (call is! Map) continue;
          final fn = call['function'];
          if (fn is! Map) continue;
          parts.add({
            'functionCall': {
              'name': fn['name'],
              'args': _decodeObject(fn['arguments']),
            },
          });
        }
        if (parts.isEmpty && message['content'] is String) {
          parts.add({'text': message['content']});
        }
      } else if (role == 'tool') {
        parts.add({
          'functionResponse': {
            'name': message['name'],
            'response': {'result': _decodeAny(message['content'])},
          },
        });
      } else {
        parts.add({'text': message['content']?.toString() ?? ''});
      }

      contents.add({
        'role': role == 'assistant' ? 'model' : 'user',
        'parts': parts,
      });
    }
    return contents;
  }

  static Map<String, dynamic> _decodeObject(Object? raw) {
    final value = _decodeAny(raw);
    return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  }

  static Object? _decodeAny(Object? raw) {
    if (raw is! String) return raw;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }
}
