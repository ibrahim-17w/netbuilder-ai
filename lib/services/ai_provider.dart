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
