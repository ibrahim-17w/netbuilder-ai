import 'diagnostic_playbooks.dart';
import 'phrase_match.dart';

/// One scored playbook match. [signalLength] is the length of the longest
/// symptom phrase that matched; it is what tells a specific signal ("stuck in
/// exstart") from a generic one ("slow"), and the triage layer uses it to
/// decide whether two clauses describe two real symptoms.
class PlaybookMatch {
  final DiagnosticPlaybook playbook;
  final double score;
  final int signalLength;

  const PlaybookMatch(this.playbook, this.score, this.signalLength);
}

/// Deterministic fault reasoning for [NetworkingIntellect].
///
/// The knowledge corpus answers "what is X". This layer answers "X is
/// broken, in this state, why?" - and it is deliberately separate, because
/// a fault answer is not a definition with a troubleshooting paragraph
/// stapled on. It names what the state proves, ranks the causes that fit,
/// gives the one command that separates them, and states the rule that keeps
/// the repair from coming back.
///
/// Matching is phrase based, not keyword based. A playbook needs its
/// technology words AND its symptom phrase, so "stuck in active" with "bgp"
/// never lands on the OSPF answer, and a question that merely mentions a
/// technology still gets the corpus, not a fault playbook.
class NetworkingPlaybooks {
  const NetworkingPlaybooks._();

  /// The rendered diagnosis, or null when no playbook fits.
  static String? answer(String text) {
    final match = bestMatch(text);
    if (match == null) return null;
    return render(match);
  }

  /// The playbook whose evidence is strongest, or null.
  static DiagnosticPlaybook? bestMatch(String text) {
    final found = matches(text, limit: 1);
    return found.isEmpty ? null : found.first.playbook;
  }

  /// Every playbook with evidence, strongest first. A longer symptom phrase
  /// outranks a shorter one, so the list is already the order a senior would
  /// rank the candidates in.
  static List<PlaybookMatch> matches(String text, {int limit = 3}) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty || limit < 1) return const [];
    final found = <PlaybookMatch>[];
    for (final playbook in diagnosticPlaybooks) {
      final match = _match(playbook, t);
      if (match != null) found.add(match);
    }
    found.sort((a, b) {
      final score = b.score.compareTo(a.score);
      if (score != 0) return score;
      final signal = b.signalLength.compareTo(a.signalLength);
      if (signal != 0) return signal;
      return a.playbook.id.compareTo(b.playbook.id);
    });
    return found.take(limit).toList();
  }

  /// Renders one playbook as the answer an engineer would give.
  static String render(DiagnosticPlaybook playbook) {
    final b = StringBuffer()
      ..writeln(playbook.title)
      ..writeln()
      ..writeln(playbook.meaning)
      ..writeln()
      ..writeln('Most likely, in the order I would test:');
    for (var i = 0; i < playbook.causes.length; i++) {
      b.writeln('${i + 1}. ${playbook.causes[i]}');
    }
    b.writeln();
    b.writeln('Prove it, read-only:');
    for (final check in playbook.checks) {
      b.writeln('- `${check.command}` - ${check.proves}.');
    }
    b.writeln();
    b.writeln('Fix: ${playbook.fix}');
    b.writeln();
    b.writeln('Rule: ${playbook.rule}');
    if (playbook.variants.isNotEmpty) {
      b.writeln();
      b.writeln('Other platforms:');
      for (final variant in playbook.variants) {
        b.writeln('- ${variant.platform}: ${variant.commands}');
      }
    }
    return b.toString().trim();
  }

  /// Evidence score: the longest symptom phrase that matched, plus a
  /// technology bonus. A longer, more specific phrase always beats a short
  /// generic one, which is what keeps "slow wifi" out of the generic slow
  /// playbook.
  static PlaybookMatch? _match(DiagnosticPlaybook playbook, String t) {
    if (playbook.excludes.any((phrase) => PhraseMatch.has(t, phrase))) {
      return null;
    }
    if (playbook.subjects.isNotEmpty &&
        !playbook.subjects.any((subject) => PhraseMatch.has(t, subject))) {
      return null;
    }
    var signal = 0;
    for (final phrase in playbook.signals) {
      if (phrase.length > signal && PhraseMatch.has(t, phrase)) {
        signal = phrase.length;
      }
    }
    if (signal == 0) return null;
    final subject = playbook.subjects.isEmpty
        ? 0
        : playbook.subjects
              .where((s) => PhraseMatch.has(t, s))
              .fold<int>(
                0,
                (longest, s) => s.length > longest ? s.length : longest,
              );
    return PlaybookMatch(playbook, signal + subject / 10, signal);
  }

  /// The playbook ids, for tests and for the capability catalogue.
  static List<String> get ids => [for (final p in diagnosticPlaybooks) p.id];

  /// One playbook by id, or null when the id is not in the corpus.
  static DiagnosticPlaybook? byId(String id) {
    for (final playbook in diagnosticPlaybooks) {
      if (playbook.id == id) return playbook;
    }
    return null;
  }
}
