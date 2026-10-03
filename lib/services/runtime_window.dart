import 'dart:convert';

import 'package:http/http.dart' as http;

/// What the inference runtime will REALLY hold, as opposed to what the app
/// would like it to hold.
///
/// This exists because of the memory bug: the app planned its request against
/// the *configured* context budget (up to 1,024k, a number the Settings slider
/// happily accepts), while a local runtime allocates its own window and
/// silently discards the front of an oversized prompt. Ollama's default
/// `num_ctx` is 4096, and its OpenAI-compatible endpoint ignores `num_ctx`
/// entirely - so a request that "fits" in 1,024k arrived at a 4k window with
/// the system prompt eating most of it and the older turns cut off the top.
/// The assistant appeared to remember one or two messages.
///
/// Nothing here is a guess about the model: the numbers come from the runtime
/// that will serve the request, and every fallback is the *conservative*
/// direction (assume a small window and send less, rather than assume a large
/// one and be silently truncated).
class RuntimeWindow {
  /// The window the runtime will actually allocate, in tokens.
  final int tokens;

  /// The model's own supported ceiling, when the runtime publishes it. The
  /// allocated window can be smaller (prompt-processing cost, VRAM) and this
  /// is what it could be raised to.
  final int? modelMax;

  /// Where [tokens] came from, e.g. `Ollama /api/ps`. Shown to the user in the
  /// context inspector so the number is never mysterious.
  final String source;

  /// True when a runtime answered. False means [tokens] is an assumption, and
  /// the UI says so instead of presenting it as fact.
  final bool certain;

  /// One actionable sentence about this window (empty when nothing to say).
  final String note;

  const RuntimeWindow({
    required this.tokens,
    required this.source,
    this.modelMax,
    this.certain = false,
    this.note = '',
  });

  /// The window assumed for a keyless local server when it will not say.
  ///
  /// 4096 is Ollama's documented default and the usual llama.cpp start value.
  /// It is deliberately pessimistic: sending a request that is too small costs
  /// a little recall, while sending one that is too big costs the *oldest*
  /// turns, which is the bug being fixed.
  static const int conservativeLocal = 4096;

  /// The smallest window the app will ever plan against.
  static const int floorTokens = 2048;

  /// The ceiling for any runtime that does not publish its own: a remote
  /// gateway model (Gemini, Groq, OpenAI, OpenRouter) has a large window, so
  /// the configured budget is believable there.
  static const int remoteAssumed = 262144;

  bool get isAssumed => !certain;

  /// A sentence for the UI, including how to raise the window when it is the
  /// runtime's default that is limiting the chat.
  String get hint {
    if (note.isNotEmpty) return note;
    if (certain) return '';
    return 'The runtime did not report its context window, so the chat is '
        'planned against $tokens tokens.';
  }

  RuntimeWindow copyWith({int? tokens, String? source, bool? certain}) =>
      RuntimeWindow(
        tokens: tokens ?? this.tokens,
        source: source ?? this.source,
        modelMax: modelMax,
        certain: certain ?? this.certain,
        note: note,
      );

  /// The budget the planner should work to.
  ///
  /// [configured] is the user's ceiling (Settings). It is a *maximum*, never a
  /// target: a 1,024k setting on a runtime that allocates 8k must plan against
  /// 8k, or the request gets truncated before the model ever sees it.
  static int effectiveBudget({
    required int configured,
    required RuntimeWindow window,
  }) {
    final ceiling = configured <= 0 ? remoteAssumed : configured;
    final usable = window.tokens;
    return (usable < ceiling ? usable : ceiling)
        .clamp(floorTokens, 8 * 1024 * 1024);
  }
}

/// Asks the local runtime how much context it actually allocates.
///
/// Best-effort and non-blocking by design: every call is short-timeout, every
/// failure is swallowed, and a null result means "we could not tell" - the
/// caller then falls back to [RuntimeWindow.conservativeLocal] for a local
/// server, which is what makes the chat work out of the box on a machine whose
/// runtime never answers these questions.
class RuntimeWindowProbe {
  /// Probe endpoints are Ollama's and llama.cpp's own APIs, not the
  /// OpenAI-compatible facade: the facade is precisely what hides `num_ctx`.
  static Uri? _root(String baseUrl) {
    var base = baseUrl.trim();
    if (base.isEmpty) return null;
    if (!base.contains('://')) base = 'http://$base';
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) return null;
    // `http://host:11434/v1/chat/completions` -> `http://host:11434`
    final segments = uri.pathSegments
        .where((s) => s.isNotEmpty && s != 'v1')
        .toList();
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: segments.isEmpty ? '' : '/${segments.first}',
    );
  }

  /// True for an address that resolves to this machine. A remote gateway has a
  /// real window of its own and no local probe to make.
  static bool isLocal(String baseUrl) {
    final uri = Uri.tryParse(
      baseUrl.trim().contains('://') ? baseUrl.trim() : 'http://${baseUrl.trim()}',
    );
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '[::1]' ||
        host == 'host.docker.internal' ||
        host == '10.0.2.2';
  }

  static Future<RuntimeWindow?> probe({
    required String baseUrl,
    required String model,
    http.Client? client,
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    final root = _root(baseUrl);
    if (root == null) return null;
    final http.Client c = client ?? http.Client();
    try {
      // 1. llama.cpp / LM Studio server: /props publishes the allocated n_ctx.
      final props = await _getJson(c, root.replace(path: '${root.path}/props'), timeout);
      final fromProps = parse('props', props, model);
      if (fromProps != null) return fromProps;

      // 2. Ollama: /api/ps reports the window of the *loaded* instance, which
      //    is the number that actually applies to the next request.
      final ps = await _postJson(
        c,
        root.replace(path: '${root.path}/api/ps'),
        const {},
        timeout,
      );
      final fromPs = parse('ps', ps, model);
      if (fromPs != null) return fromPs;

      // 3. Ollama: /api/show carries the Modelfile parameters (so a baked
      //    `PARAMETER num_ctx` is visible) and the model's own ceiling.
      final show = await _postJson(
        c,
        root.replace(path: '${root.path}/api/show'),
        {'model': model},
        timeout,
      );
      return parse('show', show, model);
    } catch (_) {
      // A runtime that does not answer any of these is normal (LM Studio, a
      // proxy, a remote gateway). The caller decides the fallback.
    } finally {
      if (client == null) c.close();
    }
    return null;
  }

  /// Turn one endpoint's JSON into a window, or null when it does not say.
  ///
  /// Public and pure so the shapes each runtime returns are unit-tested
  /// against the real code rather than against a stand-in that could drift.
  /// [endpoint] is 'props' (llama.cpp /props), 'ps' (Ollama /api/ps) or
  /// 'show' (Ollama /api/show).
  static RuntimeWindow? parse(
    String endpoint,
    Map<String, dynamic>? body,
    String model,
  ) {
    if (body == null) return null;
    switch (endpoint) {
      case 'props':
        final nCtx = _intAt(body, ['n_ctx']) ??
            _intAt(body, ['default_generation_settings', 'n_ctx']) ??
            _intAt(body, ['default_generation_settings', 'n_ctx_per_seq']);
        if (nCtx == null || !_plausible(nCtx)) return null;
        return RuntimeWindow(
          tokens: nCtx,
          source: 'llama.cpp /props',
          certain: true,
        );

      case 'ps':
        final loaded = _listAt(body, ['models']);
        if (loaded == null) return null;
        for (final entry in loaded) {
          if (entry is! Map) continue;
          final name = (entry['name'] ?? entry['model'] ?? '').toString();
          if (model.isNotEmpty && name.isNotEmpty && !_sameModel(name, model)) {
            continue;
          }
          final allocated = _intAt(entry, ['context_length']) ??
              _intAt(entry, ['context_window']);
          if (allocated == null || !_plausible(allocated)) continue;
          return RuntimeWindow(
            tokens: allocated,
            source: 'Ollama /api/ps',
            certain: true,
          );
        }
        return null;

      case 'show':
        final modelMax = _contextLengthFromModelInfo(body);
        final parameter = _numCtxFromParameters(body);
        if (parameter != null && _plausible(parameter)) {
          return RuntimeWindow(
            tokens: parameter,
            modelMax: modelMax,
            source: 'Ollama /api/show (num_ctx)',
            certain: true,
          );
        }
        if (modelMax != null) {
          // The model CAN hold this much, but Ollama allocates its own default
          // unless a num_ctx is baked in - so this is reported as the ceiling,
          // not as the window in force.
          return RuntimeWindow(
            tokens: _min(RuntimeWindow.conservativeLocal, modelMax),
            modelMax: modelMax,
            source: 'Ollama /api/show (model ceiling)',
            certain: false,
            note:
                'The model supports $modelMax tokens, but Ollama allocates its '
                'own window (its default is 4096) and its OpenAI-compatible '
                'endpoint ignores a per-request num_ctx. Raise it with '
                'OLLAMA_CONTEXT_LENGTH=$modelMax (or bake `PARAMETER num_ctx '
                '$modelMax` into the Modelfile), then the chat will use the '
                'full window automatically.',
          );
        }
        return null;
    }
    return null;
  }

  /// The window to plan against, from a probe result (or its absence).
  static RuntimeWindow resolve({
    required String baseUrl,
    RuntimeWindow? probed,
    int? manual,
  }) {
    if (manual != null && manual > 0) {
      return RuntimeWindow(
        tokens: manual,
        source: 'Settings (manual)',
        certain: true,
      );
    }
    if (probed != null) return probed;
    if (isLocal(baseUrl)) {
      return const RuntimeWindow(
        tokens: RuntimeWindow.conservativeLocal,
        source: 'assumed (local runtime)',
        note:
            'A local server did not report its context window, so the chat is '
            'planned against 4096 tokens - the common default. If your runtime '
            'is configured for more, set the runtime window in Settings so the '
            'chat can use it.',
      );
    }
    return const RuntimeWindow(
      tokens: RuntimeWindow.remoteAssumed,
      source: 'assumed (remote provider)',
      certain: true,
    );
  }

  // --- parsing helpers (pure, so they are unit-testable) -------------------

  /// `{"llama.context_length": 131072}` / `{"qwen2.context_length": ...}`:
  /// the architecture prefix varies, the suffix does not.
  static int? _contextLengthFromModelInfo(Map<String, dynamic>? show) {
    final info = show?['model_info'];
    if (info is! Map) return null;
    for (final entry in info.entries) {
      final key = entry.key.toString().toLowerCase();
      if (!key.endsWith('.context_length')) continue;
      final value = entry.value;
      final n = value is num ? value.toInt() : int.tryParse('$value');
      if (n != null && _plausible(n)) return n;
    }
    return null;
  }

  /// `parameters` arrives as a multi-line string: `stop "x"\nnum_ctx 8192`.
  static int? _numCtxFromParameters(Map<String, dynamic>? show) {
    final raw = show?['parameters'];
    if (raw is Map) {
      final n = raw['num_ctx'];
      return n is num ? n.toInt() : int.tryParse('$n');
    }
    if (raw is! String) return null;
    for (final line in raw.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2 && parts.first.toLowerCase() == 'num_ctx') {
        return int.tryParse(parts[1]);
      }
    }
    return null;
  }

  /// `127.0.0.1:11434`-style names and bare tags both have to match
  /// `llama3.2:3b`.
  static bool _sameModel(String loaded, String wanted) {
    String norm(String s) =>
        s.toLowerCase().split(':').first.trim().replaceAll('.gguf', '');
    return norm(loaded) == norm(wanted) || loaded.toLowerCase() == wanted.toLowerCase();
  }

  static bool _plausible(int tokens) => tokens >= 512 && tokens <= 8 * 1024 * 1024;

  static int _min(int a, int b) => a < b ? a : b;

  static int? _intAt(Object? node, List<String> path) {
    var current = node;
    for (final key in path) {
      if (current is! Map) return null;
      current = current[key];
    }
    if (current is num) return current.toInt();
    return current == null ? null : int.tryParse('$current');
  }

  static List? _listAt(Object? node, List<String> path) {
    var current = node;
    for (final key in path) {
      if (current is! Map) return null;
      current = current[key];
    }
    return current is List ? current : null;
  }

  static Future<Map<String, dynamic>?> _getJson(
    http.Client client,
    Uri url,
    Duration timeout,
  ) async {
    final r = await client.get(url).timeout(timeout);
    if (r.statusCode != 200) return null;
    final decoded = jsonDecode(r.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  static Future<Map<String, dynamic>?> _postJson(
    http.Client client,
    Uri url,
    Map<String, dynamic> body,
    Duration timeout,
  ) async {
    final r = await client
        .post(
          url,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(timeout);
    if (r.statusCode != 200) return null;
    final decoded = jsonDecode(r.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }
}
