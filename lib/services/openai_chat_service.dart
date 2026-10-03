import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_provider.dart';
import 'generation_control.dart';

/// A client for anything that speaks OpenAI's `/chat/completions`.
///
/// Works with the free-tier gateways (Groq, OpenRouter, Together, Cerebras…),
/// with paid OpenAI itself, and with a local server (Ollama, llama.cpp,
/// LM Studio) because all of them share this request/response shape.
class OpenAiChatService {
  final http.Client _client;
  final AiProviderConfig config;
  final String apiKey;

  OpenAiChatService({
    required this.config,
    required this.apiKey,
    http.Client? client,
  }) : _client = client ?? http.Client();

  Uri _endpoint() {
    final base = config.effectiveBaseUrl();
    final bad = AiErrors.badBaseUrl(base);
    if (bad.isNotEmpty) throw Exception(bad);
    return Uri.parse('$base/chat/completions');
  }

  Map<String, String> _headers() => {
    'Content-Type': 'application/json',
    if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
    if (config.organization.isNotEmpty)
      'OpenAI-Organization': config.organization,
    if (config.project.isNotEmpty) 'OpenAI-Project': config.project,
    ...config.extraHeaders,
  };

  Map<String, dynamic> _body(List<Map<String, dynamic>> messages, bool stream) => {
    'model': config.model,
    'messages': messages,
    'stream': stream,
  };

  void _requireKey() {
    final key = apiKey.trim();
    if (key.isEmpty && !_isLocal()) {
      throw Exception(
        'No API key for ${config.label}. Add one in Settings, or point the '
        'base URL at a local server that does not need a key.',
      );
    }
  }

  /// A one-shot request, used by "Test connection" and by non-streaming chat.
  Future<String> complete(List<Map<String, String>> messages) async {
    _requireKey();
    try {
      // A momentary 429/5xx is retried - see [AiRetry].
      final r = await AiRetry.fetch<http.Response>(
        send: () => _client
            .post(
              _endpoint(),
              headers: _headers(),
              body: jsonEncode(_body(messages, false)),
            )
            .timeout(const Duration(seconds: 60)),
        status: (response) => response.statusCode,
      );
      if (r.statusCode != 200) {
        throw Exception(
          AiErrors.describe(
            status: r.statusCode,
            body: r.body,
            model: config.model,
            baseUrl: config.effectiveBaseUrl(),
          ),
        );
      }
      return textOf(r.body);
    } catch (e) {
      if (e.toString().startsWith('Exception: ')) rethrow;
      throw Exception(AiErrors.network(e));
    }
  }

  /// The answer as it arrives: OpenAI sends `data: {choices:[{delta:{...}}]}`.
  ///
  /// Text-only turns. [streamMessages] is the same call for a turn that also
  /// carries images.
  Stream<String> stream(List<Map<String, String>> messages) => streamMessages([
    for (final m in messages) Map<String, dynamic>.from(m),
  ]);

  /// The answer as it arrives, for a conversation that may carry images.
  ///
  /// `content` may be a plain string or a parts array (`{type:'text'} /
  /// {type:'image_url'}`) - the shape a vision turn needs, and the shape every
  /// gateway accepts.
  ///
  /// [abortTrigger] completes when the user pressed stop: the in-flight request
  /// is aborted and [AbortedException] is raised, so a cancelled answer is
  /// never reported as a provider failure. [abortProbe] answers the same
  /// question synchronously, which is the only way a stop that happened
  /// *before* this request was built can be seen. The stream is also bounded -
  /// see [StreamDeadlines] - because a provider that accepts the connection and
  /// then says nothing used to leave an empty bubble on screen.
  Stream<String> streamMessages(
    List<Map<String, dynamic>> messages, {
    Future<void>? abortTrigger,
    bool Function()? abortProbe,
    Duration? firstByteTimeout,
    Duration? idleTimeout,
    Duration? totalTimeout,
  }) async* {
    _requireKey();
    final signal = AbortSignal(
      abortTrigger,
      isAbortedNow: abortProbe,
      isAbortError: (e) => e is http.RequestAbortedException,
    );
    signal.throwIfAborted();
    final started = DateTime.now();

    /// A fresh request per attempt: an http request can only be sent once.
    http.AbortableRequest buildRequest() {
      final request = http.AbortableRequest(
        'POST',
        _endpoint(),
        abortTrigger: abortTrigger,
      );
      request.headers.addAll(_headers());
      request.body = jsonEncode(_body(messages, true));
      return request;
    }

    final http.StreamedResponse response;
    try {
      // Retried only before the first byte: past that, another attempt would
      // repeat text the user has already watched arrive.
      response = await AiRetry.fetch<http.StreamedResponse>(
        send: () => _client
            .send(buildRequest())
            .timeout(firstByteTimeout ?? StreamDeadlines.firstByte),
        status: (r) => r.statusCode,
        onFailure: (r) => r.stream.drain<void>(),
      );
    } on http.RequestAbortedException {
      throw const AbortedException();
    } catch (e) {
      if (signal.isAbortError(e)) throw const AbortedException();
      throw Exception(AiErrors.network(e));
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw Exception(
        AiErrors.describe(
          status: response.statusCode,
          body: body,
          model: config.model,
          baseUrl: config.effectiveBaseUrl(),
        ),
      );
    }
    var buffer = '';
    try {
      final pieces = StreamDeadlines.guarded(
        response.stream.transform(utf8.decoder),
        startedAt: started,
        idleGap: idleTimeout,
        budget: totalTimeout,
      );
      await for (final piece in pieces) {
        signal.throwIfAborted();
        buffer += piece;
        final lines = buffer.split('\n');
        buffer = lines.removeLast();
        final delta = sseDelta('${lines.join('\n')}\n');
        if (delta.isNotEmpty) yield delta;
      }
      final tail = sseDelta(buffer);
      if (tail.isNotEmpty) yield tail;
    } on http.RequestAbortedException {
      throw const AbortedException();
    } on TimeoutException catch (e) {
      throw Exception(AiErrors.network(e));
    }
    signal.throwIfAborted();
  }

  /// The text added by one SSE buffer. Pure, so it is tested with a fixture.
  static String sseDelta(String raw) {
    final out = StringBuffer();
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;
      final payload = trimmed.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        out.write(deltaOf(payload));
      } catch (_) {
        // A half-arrived line stays in the caller's buffer.
      }
    }
    return out.toString();
  }

  /// The text inside one non-streaming response body.
  static String textOf(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return '';
    final choices = decoded['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('The provider returned no choices.');
    }
    final message = (choices.first as Map)['message'] as Map?;
    final content = message?['content'];
    return content is String ? content : '';
  }

  /// The text inside one streaming `data:` payload.
  static String deltaOf(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return '';
    final choices = decoded['choices'] as List?;
    if (choices == null || choices.isEmpty) return '';
    final choice = choices.first as Map;
    // Some gateways only send the full text at the end.
    final delta = choice['delta'] as Map?;
    final fromDelta = delta?['content'];
    if (fromDelta is String && fromDelta.isNotEmpty) return fromDelta;
    final message = choice['message'] as Map?;
    final full = message?['content'];
    if (full is String) return full;
    final text = choice['text'];
    return text is String ? text : '';
  }

  /// A local server (Ollama, llama.cpp, LM Studio) usually needs no key.
  bool _isLocal() {
    final host = Uri.tryParse(config.effectiveBaseUrl())?.host ?? '';
    return host == '127.0.0.1' || host == 'localhost' || host == '::1' ||
        host == '10.0.2.2';
  }
}
