import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'generation_control.dart';
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
/// [baseProvider] is how the sidecar's address is resolved at call time: the
/// port moves when the sidecar restarts, and a tool layer that kept talking to
/// the old port looked like a dead chat forever.
class ToolRuntime {
  final AiProviderConfig config;
  final String geminiKey;
  final String openaiKey;
  final String sidecarBase;
  final http.Client client;

  /// Resolves the sidecar base at call time, so an endpoint change is picked
  /// up without rebuilding the runtime.
  final String Function()? baseProvider;

  /// How long one provider round trip inside the loop may take.
  final Duration providerTimeout;

  /// How long one tool call into the engine's tool layer may take.
  final Duration toolTimeout;

  /// The capture the tools should be answered from (a server-side path).
  String capturePath;

  ToolRuntime({
    required this.config,
    required this.sidecarBase,
    this.geminiKey = '',
    this.openaiKey = '',
    this.capturePath = '',
    this.baseProvider,
    this.providerTimeout = StreamDeadlines.firstByte,
    this.toolTimeout = StreamDeadlines.toolCall,
    http.Client? client,
  }) : client = client ?? http.Client();

  List<Map<String, dynamic>> _tools = const [];

  /// Whether the engine actually offered tools. The chat falls back to the
  /// plain path when this is false, so a missing sidecar never breaks chat.
  bool get available => _tools.isNotEmpty;
  List<Map<String, dynamic>> get tools => List.unmodifiable(_tools);

  bool _loaded = false;
  String? _loadedFor;

  /// What the loaded catalogue belongs to.
  ///
  /// The model AND the resolved sidecar base: a different endpoint is a
  /// different engine, with its own tools, so a cached catalogue is only reused
  /// for the same key. Without the base in the key, a sidecar that came back on
  /// a new port kept answering with the previous one's tool list (or none).
  String get toolCacheKey => '${config.model}@${_base()}';

  /// Load once per endpoint, and remember the answer: the chat may ask on
  /// every turn.
  ///
  /// A failed attempt is NOT remembered. The old version marked itself loaded
  /// before trying, so a sidecar that was still starting when the first turn
  /// arrived was written off for the whole session - the chat silently lost
  /// tools it could have had a second later.
  Future<bool> ensureLoaded() async {
    final key = toolCacheKey;
    if (_loaded && _loadedFor == key) return available;
    final ok = await load();
    if (ok) {
      _loaded = true;
      _loadedFor = key;
    } else {
      _loaded = false;
      _loadedFor = null;
    }
    return ok;
  }

  bool get isGemini => config.kind == AiProviderKind.gemini;

  /// Ask the engine which tools exist. Returns false if it cannot be reached.
  Future<bool> load() async {
    final base = _base();
    if (base.isEmpty) {
      _tools = const [];
      return false;
    }
    try {
      final uri = Uri.parse('$base/tools/list');
      final response = await client
          .get(uri)
          .timeout(StreamDeadlines.discovery);
      if (response.statusCode != 200) {
        _tools = const [];
        return false;
      }
      _tools = ToolProtocol.catalogue(jsonDecode(response.body));
      return _tools.isNotEmpty;
    } catch (_) {
      // Whatever was loaded belonged to a previous endpoint; keeping it would
      // let the model call tools this engine does not have.
      _tools = const [];
      return false;
    }
  }

  /// The declarations to attach to the provider request.
  List<Map<String, dynamic>> declarations() => isGemini
      ? ToolProtocol.geminiDeclarations(_tools)
      : ToolProtocol.openAiDeclarations(_tools);

  /// The headers a gateway may need, so a tool turn is authenticated exactly
  /// like a plain one. A gateway that needs an org header failed 401 on the
  /// tool loop while the plain path worked.
  Map<String, String> _openAiHeaders() => {
    'Content-Type': 'application/json',
    if (openaiKey.trim().isNotEmpty)
      'Authorization': 'Bearer ${openaiKey.trim()}',
    if (config.organization.isNotEmpty)
      'OpenAI-Organization': config.organization,
    if (config.project.isNotEmpty) 'OpenAI-Project': config.project,
    ...config.extraHeaders,
  };

  /// One POST, bounded and abortable. Every leg of the tool loop goes through
  /// here so none of them can hang the turn forever.
  Future<http.Response> _post(
    Uri uri, {
    required Map<String, String> headers,
    required Object? body,
    required Duration timeout,
    Future<void>? abortTrigger,
    bool Function()? abortProbe,
  }) async {
    final signal = AbortSignal(
      abortTrigger,
      isAbortedNow: abortProbe,
      isAbortError: (e) => e is http.RequestAbortedException,
    );
    signal.throwIfAborted();
    final request = http.AbortableRequest(
      'POST',
      uri,
      abortTrigger: abortTrigger,
    );
    request.headers.addAll(headers);
    request.body = jsonEncode(body);
    try {
      final response = await client.send(request).timeout(timeout);
      return await http.Response.fromStream(response).timeout(timeout);
    } on http.RequestAbortedException {
      throw const AbortedException();
    } on TimeoutException catch (e) {
      if (signal.isAbortError(e)) throw const AbortedException();
      throw Exception(AiErrors.network(e));
    } catch (e) {
      if (signal.isAbortError(e)) throw const AbortedException();
      rethrow;
    }
  }

  /// One provider round-trip. [messages] are OpenAI-shaped (the loop's
  /// internal form); Gemini gets them translated, rich content included.
  Future<Object?> send(
    List<Map<String, dynamic>> messages, {
    Future<void>? abortTrigger,
    bool Function()? abortProbe,
  }) async {
    final system = _systemText(messages);
    final response = isGemini
        ? await _post(
            Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/'
              'models/${config.model}:generateContent',
            ),
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': geminiKey,
            },
            body: {
              'contents': _geminiContents(messages),
              // Gemini takes the system prompt out of band, not as a turn.
              if (system.isNotEmpty)
                'systemInstruction': {
                  'parts': [
                    {'text': system},
                  ],
                },
              'tools': declarations(),
            },
            timeout: providerTimeout,
            abortTrigger: abortTrigger,
            abortProbe: abortProbe,
          )
        : await _post(
            Uri.parse('${config.effectiveBaseUrl()}/chat/completions'),
            headers: _openAiHeaders(),
            body: {
              'model': config.model,
              'messages': messages,
              'tools': declarations(),
            },
            timeout: providerTimeout,
            abortTrigger: abortTrigger,
            abortProbe: abortProbe,
          );

    if (response.statusCode != 200) {
      throw Exception(AiErrors.describe(
        status: response.statusCode,
        body: response.body,
        model: config.model,
        baseUrl: config.effectiveBaseUrl(),
      ));
    }
    return jsonDecode(response.body);
  }

  /// Run one tool through the engine's tool layer.
  ///
  /// A `modify` tool comes back as a **proposal** carrying
  /// `requiresApproval: true`; nothing is written here. Applying it remains
  /// the user's decision through the existing approval gate (spec §8).
  Future<Object?> execute(
    ToolCall call, {
    Future<void>? abortTrigger,
    bool Function()? abortProbe,
  }) async {
    final base = _base();
    if (base.isEmpty) throw Exception('The tool engine is not configured.');
    final response = await _post(
      Uri.parse('$base/tools/call'),
      headers: {'Content-Type': 'application/json'},
      body: {
        'name': call.name,
        'args': call.args,
        if (capturePath.trim().isNotEmpty) 'path': capturePath,
      },
      timeout: toolTimeout,
      abortTrigger: abortTrigger,
      abortProbe: abortProbe,
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
  ToolLoop loop({Future<void>? abortTrigger, bool Function()? abortProbe}) =>
      ToolLoop(
        send: (messages) =>
            send(messages, abortTrigger: abortTrigger, abortProbe: abortProbe),
        execute: (call) =>
            execute(call, abortTrigger: abortTrigger, abortProbe: abortProbe),
        extractText: extractText,
      );

  /// The sidecar address as of right now, without a trailing slash.
  String _base() {
    final raw = (baseProvider?.call() ?? sidecarBase).trim();
    var base = raw;
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
        if (parts.isEmpty && message['content'] != null) {
          parts.addAll(_geminiParts(message['content']));
        }
      } else if (role == 'tool') {
        parts.add({
          'functionResponse': {
            'name': message['name'],
            'response': {'result': _decodeAny(message['content'])},
          },
        });
      } else {
        parts.addAll(_geminiParts(message['content']));
      }

      // Gemini rejects a turn with no parts, so an empty turn still gets one.
      if (parts.isEmpty) parts.add({'text': ''});

      contents.add({
        'role': role == 'assistant' ? 'model' : 'user',
        'parts': parts,
      });
    }
    return contents;
  }

  /// One message's `content` as Gemini `parts`.
  ///
  /// A plain string is one `text` part. A content ARRAY - what a turn with a
  /// screenshot looks like - is walked part by part: `image_url` becomes
  /// `inlineData` (the data URL is split back into mime type and bytes). The
  /// old code did `content.toString()`, so a vision turn through the tool loop
  /// arrived at Gemini as a literal `[{type: image_url, ...}]` - the model was
  /// told it had been shown a picture and could see nothing.
  static List<Map<String, dynamic>> _geminiParts(Object? content) {
    if (content is String) {
      return [if (content.isNotEmpty) {'text': content}];
    }
    if (content is! List) {
      final text = content?.toString() ?? '';
      return [if (text.isNotEmpty) {'text': text}];
    }
    final parts = <Map<String, dynamic>>[];
    for (final part in content) {
      if (part is String) {
        if (part.isNotEmpty) parts.add({'text': part});
        continue;
      }
      if (part is! Map) continue;
      final type = part['type']?.toString() ?? 'text';
      if (type == 'image_url' || part.containsKey('image_url')) {
        final url = part['image_url'];
        final dataUrl = url is Map ? url['url']?.toString() : url?.toString();
        final inline = _inlineFromDataUrl(dataUrl);
        if (inline != null) parts.add(inline);
        continue;
      }
      final text = part['text']?.toString() ?? '';
      if (text.isNotEmpty) parts.add({'text': text});
    }
    return parts;
  }

  /// `data:image/png;base64,AAAA` as a Gemini `inlineData` part.
  static Map<String, dynamic>? _inlineFromDataUrl(String? url) {
    if (url == null) return null;
    const marker = ';base64,';
    final at = url.indexOf(marker);
    if (!url.startsWith('data:') || at <= 5) return null;
    final data = url.substring(at + marker.length);
    if (data.isEmpty) return null;
    final mime = url.substring(5, at);
    return {
      'inlineData': {
        'mimeType': mime.isEmpty ? 'image/png' : mime,
        'data': data,
      },
    };
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
