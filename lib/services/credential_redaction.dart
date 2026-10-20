/// Credential-shaped text that must never reach a log, a copied diagnostic
/// report, or an error message shown on screen.
///
/// The sidecar redacts its own journal and exports too. This helper covers
/// the app side: transport errors can quote a response body, and the engine
/// log tail is copied into the diagnostics card verbatim.
class CredentialRedaction {
  CredentialRedaction._();

  static const marker = '<redacted>';

  static final _sk = RegExp(r'\bsk-[A-Za-z0-9_-]{8,}', caseSensitive: false);
  static final _bearer = RegExp(
    r'\bBearer\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final _googleKey = RegExp(r'\bAIza[0-9A-Za-z_-]{20,}');
  static final _keyValue = RegExp(
    r'''(\b(?:api[_-]?key|apiKey|x-goog-api-key|authorization|password|passwd|secret|token|community)\b["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,;}]+)''',
    caseSensitive: false,
  );

  /// Replace recognised credentials with a stable marker. Idempotent.
  static String redact(String text) {
    if (text.isEmpty) return text;
    var out = text
        .replaceAll(_sk, 'sk-$marker')
        .replaceAll(_bearer, 'Bearer $marker')
        .replaceAll(_googleKey, 'AIza$marker');
    out = out.replaceAllMapped(
      _keyValue,
      (match) => '${match.group(1)}$marker',
    );
    return out;
  }
}
