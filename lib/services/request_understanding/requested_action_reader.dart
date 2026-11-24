import '../../models/request_interpretation.dart';

/// Reads the small set of follow-on outputs the app can perform directly.
///
/// Actions are returned in source order. This reader is deliberately narrow:
/// questions, hypothetical wording, and explicit negation never become file
/// writes or builds.
class RequestedActionReader {
  const RequestedActionReader._();

  static final _boundaries = RegExp(
    r'[,;\n]|\b(?:and|then)\b',
    caseSensitive: false,
  );

  static final _build = RegExp(
    r'\b(?:build|compile|generate|create)\s+'
    r'(?:(?:the|my|this|current|standing|new)\s+)*'
    r'(?:\.pkt|\bpkt\b|\bpacket\s+tracer(?:\s+file)?\b|'
    r'\bfile\b|\btopology\b|\bit\b|\bthis\b|\bthat\b)',
    caseSensitive: false,
  );

  static final _exportPacketTracer = RegExp(
    r'\bexport\s+(?:(?:the|my|current)\s+)*'
    r'(?:\.pkt|\bpkt\b|\bpacket\s+tracer(?:\s+file)?\b|\bfile\b)',
    caseSensitive: false,
  );

  static final _exportConfiguration = RegExp(
    r'\bexport\s+(?:(?:the|my|these|all|current|device|router|switch|network)\s+)*'
    r'(?:(Cisco\s+IOS|IOS|GNS3|Packet\s+Tracer)\s+)?'
    r'(?:configs?\b|configurations?\b)'
    r'(?:\s+(?:in|as|for)\s+(Cisco\s+IOS|IOS|GNS3|Packet\s+Tracer)\b)?',
    caseSensitive: false,
  );

  static final _unsafeClause = RegExp(
    r'\b(?:don.t|do\s+not|never|must\s+not|not\s+yet|'
    r'what\s+if|how\s+to|how\s+do\s+i|whether|consider|maybe)\b',
    caseSensitive: false,
  );

  static List<RequestedAction> read({
    required String text,
    required String turnId,
  }) {
    if (text.trim().isEmpty) return const [];
    final candidates = <_ActionCandidate>[];
    for (final match in _build.allMatches(text)) {
      if (_isActionClause(text, match.start, match.end)) {
        candidates.add(
          _ActionCandidate(match.start, RequestedActionKind.build),
        );
      }
    }
    for (final match in _exportPacketTracer.allMatches(text)) {
      if (_isActionClause(text, match.start, match.end)) {
        candidates.add(
          _ActionCandidate(match.start, RequestedActionKind.exportPacketTracer),
        );
      }
    }
    for (final match in _exportConfiguration.allMatches(text)) {
      if (_isActionClause(text, match.start, match.end)) {
        candidates.add(
          _ActionCandidate(
            match.start,
            RequestedActionKind.exportConfiguration,
            format: _configurationFormat(match.group(1) ?? match.group(2)),
          ),
        );
      }
    }
    candidates.sort((left, right) => left.start.compareTo(right.start));

    final safeTurnId = turnId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    final actions = <RequestedAction>[];
    for (final candidate in candidates) {
      // The broad "file" target overlaps phrases such as "export the
      // configuration file". Keep the more useful configuration action.
      if (actions.any(
        (action) =>
            action.kind == candidate.kind &&
            action.target == _targetFor(candidate.kind) &&
            action.outputOptions['format'] ==
                (candidate.format ??
                    (candidate.kind == RequestedActionKind.exportConfiguration
                        ? 'text'
                        : 'pkt')),
      )) {
        continue;
      }
      actions.add(
        RequestedAction(
          id: 'action-$safeTurnId-${actions.length}',
          kind: candidate.kind,
          target: _targetFor(candidate.kind),
          outputOptions: switch (candidate.kind) {
            RequestedActionKind.build ||
            RequestedActionKind.exportPacketTracer => const {'format': 'pkt'},
            RequestedActionKind.exportConfiguration => {
              'format': candidate.format ?? 'text',
              'scope': 'supported-device-configurations',
            },
            _ => const {},
          },
        ),
      );
    }
    return List.unmodifiable(actions);
  }

  static String? _configurationFormat(String? qualifier) =>
      switch (qualifier?.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')) {
        'cisco ios' || 'ios' => 'cisco-ios',
        'gns3' => 'gns3',
        'packet tracer' => 'packet-tracer',
        _ => null,
      };

  static bool _isActionClause(String text, int start, int end) {
    var clauseStart = 0;
    var clauseEnd = text.length;
    for (final boundary in _boundaries.allMatches(text)) {
      if (boundary.end <= start) clauseStart = boundary.end;
      if (boundary.start >= end) {
        clauseEnd = boundary.start;
        break;
      }
    }
    final clause = text.substring(clauseStart, clauseEnd).trim();
    if (clause.contains('?') || _unsafeClause.hasMatch(clause)) return false;
    return true;
  }

  static String _targetFor(RequestedActionKind kind) => switch (kind) {
    RequestedActionKind.build ||
    RequestedActionKind.exportPacketTracer => 'current-plan-packet-tracer-file',
    RequestedActionKind.exportConfiguration => 'current-plan-configurations',
    _ => 'current-plan',
  };
}

class _ActionCandidate {
  final int start;
  final RequestedActionKind kind;
  final String? format;

  const _ActionCandidate(this.start, this.kind, {this.format});
}
