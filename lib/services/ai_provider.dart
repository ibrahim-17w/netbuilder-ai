/// Which model backend the app talks to, and how to describe its failures.
///
/// Two kinds are supported and nothing else:
///  * `gemini`  - Google's REST shape (the original integration);
///  * `openai`  - anything that speaks OpenAI's /chat/completions, which is
///                what the free-tier providers and local servers do.
///
/// Neither the URL, the key nor the model is hardcoded anywhere in the request
/// path: they all come from [AiProviderConfig].
enum AiProviderKind { gemini, openai }

class AiProviderConfig {
  final AiProviderKind kind;

  /// Only used by the OpenAI-compatible client, e.g.
  /// `https://api.groq.com/openai/v1` or `http://127.0.0.1:11434/v1`.
  final String baseUrl;
  final String model;

  /// Extra headers a gateway may ask for (proxy tokens, referral headers...).
  final Map<String, String> extraHeaders;

  /// Optional OpenAI org / project fields; harmless when unused.
  final String organization;
  final String project;

  const AiProviderConfig({
    required this.kind,
    required this.model,
    this.baseUrl = '',
    this.extraHeaders = const {},
    this.organization = '',
    this.project = '',
  });

  String get label =>
      kind == AiProviderKind.gemini ? 'Google Gemini' : 'OpenAI-compatible';

  /// The model list we can SUGGEST. It is not an allow-list: the model field
  /// accepts anything the user types, so a new model release never needs an
  /// app update.
  static const geminiSuggestions = <String>[
    'gemini-2.5-flash',
    'gemini-2.5-pro',
    'gemini-2.0-flash',
  ];

  static const openaiSuggestions = <String>[
    'llama-3.3-70b-versatile',
    'llama-3.1-8b-instant',
    'gpt-4o-mini',
    'qwen-2.5-72b-instruct',
  ];

  /// The default Gemini model. The old default (`gemini-3.8-flash`) is not a
  /// model Google serves, which is why a stock install failed with a 404.
  static const defaultGeminiModel = 'gemini-2.5-flash';

  String effectiveBaseUrl() {
    var base = baseUrl.trim();
    if (base.isEmpty) return '';
    if (!base.contains('://')) base = 'https://$base';
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }
}

/// What the app can honestly say about the model backend right now.
///
/// The chat used to say it in every answer ("The AI model is unavailable
/// (HTTP 503: {}), so I am answering offline"), which is noise on a working
/// conversation and useless on a broken one - by the time you read it, you are
/// already reading the offline answer. The state belongs ABOVE the transcript
/// (one live sign) and UNDER the answer it produced (one small source line),
/// so it is visible when it matters and never repeated per message.
enum AiAvailability {
  /// A key is set and the last call worked (or nothing failed yet).
  ready,

  /// A key is set but the provider refused the last request.
  failing,

  /// No key set: the app answers from its own planner.
  keyless,

  /// Private mode: the app never calls a model, with or without a key.
  private,
}

/// Where an answer came from, and whether the API model is in play.
class AiStatus {
  final AiAvailability availability;

  /// "Google Gemini" or "OpenAI-compatible" - the configured backend.
  final String providerLabel;
  final String model;

  /// Why it is not ready, in one line ('' when there is nothing to explain).
  final String detail;

  const AiStatus({
    required this.availability,
    this.providerLabel = '',
    this.model = '',
    this.detail = '',
  });

  /// The truth from what the app actually knows: is a key set, is private mode
  /// on, and did the last call fail. Nothing here is inferred from hope.
  static AiStatus describe({
    required String providerLabel,
    required String model,
    required bool hasKey,
    required bool privateMode,
    String lastError = '',
  }) {
    if (privateMode) {
      return AiStatus(
        availability: AiAvailability.private,
        providerLabel: providerLabel,
        model: model,
        detail: 'private mode is on, so no model is called at all',
      );
    }
    if (!hasKey) {
      return AiStatus(
        availability: AiAvailability.keyless,
        providerLabel: providerLabel,
        model: model,
        detail: 'no API key is set, so the built-in planner answers',
      );
    }
    if (lastError.trim().isNotEmpty) {
      return AiStatus(
        availability: AiAvailability.failing,
        providerLabel: providerLabel,
        model: model,
        detail: lastError.trim(),
      );
    }
    return AiStatus(
      availability: AiAvailability.ready,
      providerLabel: providerLabel,
      model: model,
    );
  }

  /// Is the API-key model the thing answering? (Private mode and a missing key
  /// both mean "no", and the app must not pretend otherwise.)
  bool get apiInUse =>
      availability == AiAvailability.ready ||
      availability == AiAvailability.failing;

  /// The sign above the transcript. Short: it sits next to the engine light.
  String get short {
    switch (availability) {
      case AiAvailability.ready:
        return providerLabel.isEmpty ? 'AI on' : 'AI: $providerLabel';
      case AiAvailability.failing:
        return 'AI: not answering';
      case AiAvailability.keyless:
        return 'AI: off — no key';
      case AiAvailability.private:
        return 'AI: private mode';
    }
  }

  /// The one line shown under an answer, saying where THAT answer came from.
  String get source {
    switch (availability) {
      case AiAvailability.ready:
        return 'via ${providerLabel.isEmpty ? 'the API model' : providerLabel}'
            '${model.isEmpty ? '' : ' ($model)'}';
      case AiAvailability.failing:
        return 'from the built-in planner — the API model did not answer';
      case AiAvailability.keyless:
        return 'from the built-in planner — no API key';
      case AiAvailability.private:
        return 'from the built-in planner — private mode';
    }
  }

  /// What a build or an edit says about itself: those are the app's own work,
  /// with no model involved, and saying so is more useful than staying quiet.
  static const String plannerSource =
      'from the built-in planner — no model was called';
}

/// Bounded retry for provider failures that are usually momentary.
///
/// Before this existed, a single 503/429 ended the whole turn in the offline
/// fallback - the user read "The AI model is unavailable (HTTP 503: {}), so I
/// am answering offline" for a blip a second try would have cleared, and the
/// plan they got back was the offline planner's reading of their brief rather
/// than the answer they asked for.
///
/// Only the FIRST byte is retried: once an answer is streaming, a retry would
/// duplicate part of it, so callers only wrap the initial request.
class AiRetry {
  const AiRetry._();

  /// The first try plus two retries.
  static const int maxAttempts = 3;

  /// Worth another try: rate limits and server-side trouble. Every 4xx that is
  /// not a 429 (bad key, unknown model, malformed request) is the caller's to
  /// fix, and retrying it would only delay the real message.
  static bool isTransient(int status) => status == 429 || status >= 500;

  /// Backoff: 700ms, then 1.4s. Long enough for a blip to clear, short enough
  /// that a chat turn is not left hanging.
  static Future<void> backoff(int attempt) =>
      Future<void>.delayed(Duration(milliseconds: 700 * attempt));

  /// Send with a bounded retry.
  ///
  /// [send] is called once per attempt, so it must build a FRESH request and
  /// timeout each time (an http request can only be sent once). [onFailure]
  /// releases the body of a failed response so the connection is not left
  /// dangling. [wait] is injectable so tests never wait in real time.
  static Future<Response> fetch<Response>({
    required Future<Response> Function() send,
    required int Function(Response) status,
    Future<void> Function(Response)? onFailure,
    Future<void> Function(int attempt)? wait,
    int maxAttempts = maxAttempts,
  }) async {
    for (var attempt = 1; ; attempt++) {
      final response = await send();
      final code = status(response);
      if (code == 200 || !isTransient(code) || attempt >= maxAttempts) {
        return response;
      }
      if (onFailure != null) {
        try {
          await onFailure(response);
        } catch (_) {
          // A body that cannot be drained must not stop the retry.
        }
      }
      await (wait ?? backoff)(attempt);
    }
  }
}

/// One place that turns an HTTP failure into something a person can act on.
/// Each case is distinct because the fix is different in each case.
class AiErrors {
  const AiErrors._();

  static String describe({
    required int status,
    required String body,
    required String model,
    String baseUrl = '',
    bool gemini = false,
  }) {
    final short = _short(body);
    final where = baseUrl.isEmpty ? '' : ' at $baseUrl';
    switch (status) {
      case 400:
        return 'The provider rejected the request (400). If the model name or '
            'the message is wrong, fix it and retry.$where  Server said: $short';
      case 401:
        return 'The API key was rejected (401). Check the key, or whether it '
            'belongs to this provider.$where  Server said: $short';
      case 403:
        return 'The key is valid but not allowed to use `$model` (403). Pick '
            'another model or check the account\'s permissions.$where  '
            'Server said: $short';
      case 404:
        return gemini
            ? 'Provider could not find the model `$model` (404). Google does '
                  'not serve that name - type a current model such as '
                  '`gemini-2.5-flash`.$where  Server said: $short'
            : 'Nothing at that address, or the model `$model` is unknown '
                  '(404). Check the base URL ends with the right path '
                  '(usually `/v1`) and that the model id is exact.$where  '
                  'Server said: $short';
      case 422:
        return 'The provider could not accept those parameters (422). This '
            'usually means the model does not support the request shape.$where  '
            'Server said: $short';
      case 429:
        return 'Rate limited or out of quota (429). Free tiers reset on their '
            'own schedule - wait, or pick another model/provider.$where  '
            'Server said: $short';
      case 500:
      case 502:
      case 503:
      case 504:
        return 'The provider is having trouble (HTTP $status). Retry shortly; '
            'the offline planner still works with no key.$where  Server '
            'said: $short';
      default:
        return 'The provider refused the request (HTTP $status).$where  Server '
            'said: $short';
    }
  }

  static String network(Object error) {
    final text = error.toString();
    if (text.contains('TimeoutException') || text.toLowerCase().contains('timeout')) {
      return 'The request timed out. The endpoint may be slow, blocked by a '
          'firewall, or unreachable - test the connection again.';
    }
    if (text.contains('SocketException') || text.contains('Failed host lookup')) {
      return 'Could not reach that address. Check the base URL, your internet '
          'connection, and any proxy.';
    }
    if (text.contains('HandshakeException')) {
      return 'TLS handshake failed. The endpoint may need http://, or its '
          'certificate is not trusted.';
    }
    return 'Request failed: ${_short(text)}';
  }

  static String badBaseUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      return 'No base URL set. An OpenAI-compatible endpoint needs one, e.g. '
          '`https://api.groq.com/openai/v1`.';
    }
    final uri = Uri.tryParse(
      value.contains('://') ? value : 'https://$value',
    );
    if (uri == null || uri.host.isEmpty) {
      return 'That base URL is not a valid address: `$value`.';
    }
    return '';
  }

  static String _short(String body) {
    final one = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 220 ? one : '${one.substring(0, 220)}...';
  }
}
