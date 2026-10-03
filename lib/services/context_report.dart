import 'package:flutter/foundation.dart';

/// One line of the request breakdown: a label and what it cost in tokens.
class ReportSection {
  final String label;
  final int tokens;

  /// Extra evidence for this line, e.g. "3 messages" or "cut at 8,000 chars".
  final String detail;

  const ReportSection(this.label, this.tokens, [this.detail = '']);

  Map<String, dynamic> toJson() => {
    'label': label,
    'tokens': tokens,
    if (detail.isNotEmpty) 'detail': detail,
  };
}

/// What ONE request actually carried, and why.
///
/// The app used to be able to say "context 9,340 / 1,024,000 tokens (0.9%)"
/// and nothing else, which is exactly the number that made the memory look
/// broken: the plan was measured against a ceiling the runtime never had, so
/// the request was silently cut down by the runtime with no trace in the app.
/// This class is the trace: every section of the prompt with its cost, the
/// window the runtime really allocates, what was left out and the reason.
///
/// It is development/debug information. It is logged only when [RequestLog.verbose]
/// is on, and shown in the UI behind the context chip - never in the answer.
class RequestReport {
  /// Monotonic request number for this session (the "Request #18" of the log).
  final int sequence;

  /// The model and provider the request went to.
  final String model;
  final String provider;

  /// The window the runtime allocates, and where that number came from.
  final int runtimeWindow;
  final String runtimeWindowSource;
  final bool runtimeWindowAssumed;

  /// The user's ceiling from Settings, and the ceiling actually used (the
  /// smaller of the two).
  final int configuredBudget;
  final int effectiveBudget;

  /// Room left for the model's own answer.
  final int outputReserve;

  /// The prompt, section by section, in the order the model receives it.
  final List<ReportSection> sections;

  /// Turns sent word-for-word, and turns compacted into the summary instead.
  final int turnsSent;
  final int turnsSummarized;

  /// Why something was left out (empty when the whole conversation fitted).
  final List<String> notes;

  final DateTime at;

  const RequestReport({
    required this.sequence,
    required this.model,
    required this.provider,
    required this.runtimeWindow,
    required this.runtimeWindowSource,
    required this.configuredBudget,
    required this.effectiveBudget,
    required this.outputReserve,
    required this.sections,
    required this.turnsSent,
    required this.turnsSummarized,
    this.runtimeWindowAssumed = false,
    this.notes = const [],
    required this.at,
  });

  /// The same report with its request number stamped on it. The planner builds
  /// a report for every candidate request (including the UI's preview), and the
  /// number is only meaningful for one that was actually sent.
  RequestReport numbered(int sequence) => RequestReport(
    sequence: sequence,
    model: model,
    provider: provider,
    runtimeWindow: runtimeWindow,
    runtimeWindowSource: runtimeWindowSource,
    runtimeWindowAssumed: runtimeWindowAssumed,
    configuredBudget: configuredBudget,
    effectiveBudget: effectiveBudget,
    outputReserve: outputReserve,
    sections: sections,
    turnsSent: turnsSent,
    turnsSummarized: turnsSummarized,
    notes: notes,
    at: at,
  );

  /// Everything the model is asked to read, not counting the reserve.
  int get totalInput =>
      sections.fold<int>(0, (sum, section) => sum + section.tokens);

  int get totalWithReserve => totalInput + outputReserve;

  /// How full the *real* window is. The number that matters.
  double get windowFraction => runtimeWindow <= 0
      ? 0
      : (totalWithReserve / runtimeWindow).clamp(0.0, 9.99);

  bool get overflowed => totalWithReserve > effectiveBudget;

  int get freedBySummarizing =>
      notes.where((n) => n.startsWith('summarized')).length;

  Map<String, dynamic> toJson() => {
    'request': sequence,
    'at': at.toIso8601String(),
    'model': model,
    'provider': provider,
    'runtimeWindow': runtimeWindow,
    'runtimeWindowSource': runtimeWindowSource,
    'runtimeWindowAssumed': runtimeWindowAssumed,
    'configuredBudget': configuredBudget,
    'effectiveBudget': effectiveBudget,
    'outputReserve': outputReserve,
    'sections': sections.map((s) => s.toJson()).toList(),
    'totalInput': totalInput,
    'turnsSent': turnsSent,
    'turnsSummarized': turnsSummarized,
    'notes': notes,
  };

  /// The dump the developer reads: one line per section, then the reasons.
  String toText() {
    final b = StringBuffer()
      ..writeln('Request #$sequence   ${_clock(at)}')
      ..writeln('model: $model   provider: $provider')
      ..writeln(
        'runtime window: ${_thousands(runtimeWindow)} tokens '
        '($runtimeWindowSource${runtimeWindowAssumed ? ', assumed' : ''})',
      )
      ..writeln(
        'configured budget: ${_thousands(configuredBudget)}   '
        'effective budget: ${_thousands(effectiveBudget)}',
      )
      ..writeln();
    final width = sections.fold<int>(
      0,
      (max, s) => s.label.length > max ? s.label.length : max,
    );
    for (final section in sections) {
      final label = section.label.padRight(width);
      final detail = section.detail.isEmpty ? '' : '   ${section.detail}';
      b.writeln('$label  ${_thousands(section.tokens).padLeft(9)}$detail');
    }
    b.writeln('${'-' * width}  ${'-' * 9}');
    b.writeln(
      '${'total input'.padRight(width)}  '
      '${_thousands(totalInput).padLeft(9)}',
    );
    b.writeln(
      '${'output reserve'.padRight(width)}  '
      '${_thousands(outputReserve).padLeft(9)}',
    );
    b.writeln(
      '${'total'.padRight(width)}  ${_thousands(totalWithReserve).padLeft(9)}'
      '   ${(windowFraction * 100).toStringAsFixed(0)}% of the window',
    );
    b.writeln(
      'history: $turnsSent turn(s) sent verbatim, '
      '$turnsSummarized compacted',
    );
    if (notes.isEmpty) {
      b.writeln('truncation: none - the whole conversation fitted');
    } else {
      for (final note in notes) {
        b.writeln('truncation: $note');
      }
    }
    return b.toString().trimRight();
  }

  static String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  static String _thousands(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}

/// The last few request reports, for the developer and the context inspector.
///
/// In-memory on purpose: this is a debugging view of the current run, not a
/// log file the app accumulates. It is bounded so a long session cannot grow
/// it without limit.
class RequestLog {
  RequestLog._();

  /// When true, every request is printed with [debugPrint]. Wired to the
  /// Settings developer toggle so a normal user never sees it.
  static bool verbose = false;

  static const int keep = 20;
  static final List<RequestReport> _reports = <RequestReport>[];
  static int _sequence = 0;

  static int nextSequence() => ++_sequence;

  static void record(RequestReport report) {
    _reports.add(report);
    if (_reports.length > keep) _reports.removeAt(0);
    if (verbose || kDebugMode && verbose) {
      // ignore: avoid_print
      debugPrint('[context] ${report.toText()}');
    }
  }

  /// Newest first.
  static List<RequestReport> get reports => _reports.reversed.toList();

  static RequestReport? get last => _reports.isEmpty ? null : _reports.last;

  static void clear() {
    _reports.clear();
    _sequence = 0;
  }
}
