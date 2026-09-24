import 'dart:convert';

import 'package:http/http.dart' as http;

/// One model the Gemini API reports for a key, with the facts the picker
/// needs to present it and the ranking needs to order it.
///
/// Everything is derived from the ListModels response, so a new Google
/// release shows up on its own - no app update, no hardcoded list.
class GeminiModelInfo {
  final String name;

  /// Google's own label, e.g. "Gemini 2.5 Flash".
  final String displayName;
  final String description;

  /// Which REST verbs this model accepts; chat needs `generateContent`.
  final List<String> methods;
  final int inputTokenLimit;
  final int outputTokenLimit;
  final DateTime? updated;

  const GeminiModelInfo({
    required this.name,
    this.displayName = '',
    this.description = '',
    this.methods = const [],
    this.inputTokenLimit = 0,
    this.outputTokenLimit = 0,
    this.updated,
  });

  bool get supportsChat => methods.contains('generateContent');
  bool get supportsStreaming => methods.contains('streamGenerateContent');

  bool get thinking => name.contains('-thinking');
  bool get experimental =>
      name.contains('-exp') || description.toLowerCase().contains('experimental');
  bool get preview => name.contains('-preview') || name.contains('-preview-');

  /// The version family as a sortable number: 3, 2.5, 2.0, 1.5...
  /// Null for anything that is not a numbered Gemini chat family (gemma).
  double? get version {
    final m = RegExp(r'^gemini-(\d+(?:\.\d+)?)').firstMatch(name);
    if (m == null) return null;
    return double.tryParse(m.group(1)!);
  }

  /// The variant inside a family: pro, flash, flash-lite.
  String get variant {
    final m = RegExp(r'^gemini-[\d.]+-(.+)$').firstMatch(name);
    return m == null ? '' : m.group(1)!;
  }

  double get _variantScore {
    final v = variant;
    if (v == 'pro') return 3;
    if (v == 'flash') return 2;
    if (v == 'flash-lite' || v == 'lite') return 1;
    if (v.contains('pro')) return 2.5;
    if (v.contains('flash')) return 1.5;
    return 0;
  }

  /// Higher is better. Version dominates, then capability tier, then
  /// stability: a stable flash beats an experimental pro of the same
  /// generation for everyday use, and thinking models pay a small cost
  /// because they trade latency and tokens for reasoning depth.
  double get rankScore {
    var s = (version ?? 0) * 100 + _variantScore;
    if (experimental) s -= 2;
    if (thinking) s -= 1.5;
    if (preview) s -= 0.5;
    return s;
  }

  /// What the picker shows as a short subtitle.
  String get facts {
    final bits = <String>[
      if (inputTokenLimit > 0) '${(inputTokenLimit / 1024).round()}k context',
      if (supportsStreaming) 'streaming',
    ];
    return bits.join(' · ');
  }

  String get label => displayName.trim().isEmpty ? name : displayName.trim();
}

/// Detects which Gemini models a stored API key can actually use.
///
/// The endpoint is public and read-only; the key travels in the same header
/// every other Gemini call in this app already uses. The result replaces the
/// hardcoded suggestion lists wherever a key is present, so the model picker
/// offers exactly what this account can call - and recommends the latest
/// stable version among them.
class GeminiModelCatalog {
  final http.Client _client;
  GeminiModelCatalog({http.Client? client}) : _client = client ?? http.Client();

  static const _endpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';

  /// Shown when there is no key (or the list cannot be fetched): current,
  /// stable names rather than the retired ones the old static list carried.
  static const fallbackSuggestions = <String>[
    'gemini-2.5-flash',
    'gemini-2.5-pro',
    'gemini-2.5-flash-lite',
    'gemini-2.0-flash',
  ];

  /// The models this key can use for chat, best first.
  ///
  /// Throws with a message a person can act on; the callers show it verbatim.
  Future<List<GeminiModelInfo>> fetchFor(String apiKey) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw Exception('Paste a Gemini API key first - the model list comes '
          'from that key.');
    }
    final http.Response r;
    try {
      r = await _client
          .get(
            Uri.parse(_endpoint),
            headers: {'x-goog-api-key': key},
          )
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw Exception('Could not reach the Gemini model list: '
          '${e.toString().replaceFirst('Exception: ', '')}');
    }
    if (r.statusCode != 200) {
      throw Exception(_friendly(r.statusCode, r.body));
    }
    final chat = parseListModels(r.body).where(isChatModel).toList()
      ..sort((a, b) => b.rankScore.compareTo(a.rankScore));
    return chat;
  }

  /// Pure: the models in one ListModels response body. Returns empty for
  /// anything that is not a JSON object with a models list - a proxy error
  /// page or a truncated reply never crashes the picker.
  static List<GeminiModelInfo> parseListModels(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map) return const [];
    final list = decoded['models'] as List? ?? const [];
    final out = <GeminiModelInfo>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final name =
          '${raw['name'] ?? ''}'.replaceFirst(RegExp(r'^models/'), '').trim();
      if (name.isEmpty) continue;
      out.add(GeminiModelInfo(
        name: name,
        displayName: '${raw['displayName'] ?? ''}',
        description: '${raw['description'] ?? ''}',
        methods: [
          for (final m in (raw['supportedGenerationMethods'] as List? ?? const []))
            '$m',
        ],
        inputTokenLimit: (raw['inputTokenLimit'] as num?)?.toInt() ?? 0,
        outputTokenLimit: (raw['outputTokenLimit'] as num?)?.toInt() ?? 0,
        updated: DateTime.tryParse('${raw['updatedTime'] ?? ''}'),
      ));
    }
    return out;
  }

  /// Pure: whether this model is one a chat app should offer.
  ///
  /// Chat needs `generateContent`; everything else the endpoint returns -
  /// embeddings, image and video generators, audio, and the non-Gemini
  /// families like Gemma - is noise here. Deprecated entries are dropped so
  /// a picker never recommends a model that 404s.
  static bool isChatModel(GeminiModelInfo m) {
    final n = m.name.toLowerCase();
    if (!n.startsWith('gemini-')) return false;
    if (m.version == null) return false;
    if (!m.supportsChat) return false;
    if (RegExp(r'embedding|aqa|imagen|veo|lyria|tts|native-audio')
        .hasMatch(n)) {
      return false;
    }
    if (m.description.toLowerCase().contains('deprecated')) return false;
    return true;
  }

  /// Pure: the model to recommend - the latest STABLE one, preferring pro
  /// over flash within a generation, and never an experimental or preview
  /// entry while a stable one exists.
  static GeminiModelInfo? recommend(List<GeminiModelInfo> models) {
    final valid = models.where(isChatModel).toList();
    if (valid.isEmpty) return null;
    final stable = valid.where((m) => !m.experimental && !m.preview).toList();
    final pool = stable.isEmpty ? valid : stable;
    GeminiModelInfo? best;
    for (final m in pool) {
      if (best == null || m.rankScore > best.rankScore) best = m;
    }
    return best;
  }

  String _friendly(int code, String body) {
    final short = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final cut = short.length <= 200 ? short : '${short.substring(0, 200)}...';
    if (code == 400 && short.contains('API key not valid')) {
      return 'This API key was rejected (400). Paste a fresh key from '
          'aistudio.google.com.';
    }
    if (code == 403) {
      return 'The key is not allowed to list models (403). Enable the Gemini '
          'API for its AI Studio project.';
    }
    return 'HTTP $code: $cut';
  }
}
