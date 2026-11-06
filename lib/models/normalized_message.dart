import 'request_requirement.dart';

enum NormalizationSegmentKind { copied, replacement, expansion, deletion }

/// Maps a normalized range back to a range in the user's original message.
/// Offsets use Dart UTF-16 code units.
class NormalizationSegment {
  final int normalizedStart;
  final int normalizedEnd;
  final int originalStart;
  final int originalEnd;
  final NormalizationSegmentKind kind;

  const NormalizationSegment({
    required this.normalizedStart,
    required this.normalizedEnd,
    required this.originalStart,
    required this.originalEnd,
    required this.kind,
  });

  Map<String, dynamic> toJson() => {
    'normalizedStart': normalizedStart,
    'normalizedEnd': normalizedEnd,
    'originalStart': originalStart,
    'originalEnd': originalEnd,
    'kind': kind.name,
  };
}

/// Text prepared for deterministic readers, with evidence links to the input.
class NormalizedMessage {
  final String originalText;
  final String normalizedText;
  final List<NormalizationSegment> segments;
  final List<(int, int)> opaqueSourceRanges;

  NormalizedMessage({
    required this.originalText,
    required this.normalizedText,
    required List<NormalizationSegment> segments,
    List<(int, int)> opaqueSourceRanges = const [],
  }) : segments = List.unmodifiable(segments),
       opaqueSourceRanges = List.unmodifiable(opaqueSourceRanges) {
    for (final segment in this.segments) {
      if (segment.normalizedStart < 0 ||
          segment.normalizedEnd < segment.normalizedStart ||
          segment.normalizedEnd > normalizedText.length ||
          segment.originalStart < 0 ||
          segment.originalEnd < segment.originalStart ||
          segment.originalEnd > originalText.length) {
        throw const FormatException('Normalization segment is out of bounds.');
      }
    }
    for (final range in this.opaqueSourceRanges) {
      if (range.$1 < 0 ||
          range.$2 < range.$1 ||
          range.$2 > originalText.length) {
        throw const FormatException('Opaque source range is out of bounds.');
      }
    }
  }

  /// Creates an excerpt only when normalized characters have source evidence.
  SourceSpan? sourceSpan({
    required String messageId,
    required int start,
    required int end,
  }) {
    if (start < 0 ||
        end < start ||
        end > normalizedText.length ||
        start == end) {
      return null;
    }
    var originalStart = originalText.length;
    var originalEnd = 0;
    for (final segment in segments) {
      if (segment.normalizedStart == segment.normalizedEnd) continue;
      if (segment.normalizedEnd <= start || segment.normalizedStart >= end) {
        continue;
      }
      var from = segment.originalStart;
      var to = segment.originalEnd;
      if (segment.kind == NormalizationSegmentKind.copied &&
          segment.originalEnd - segment.originalStart ==
              segment.normalizedEnd - segment.normalizedStart) {
        final overlapStart = start > segment.normalizedStart
            ? start
            : segment.normalizedStart;
        final overlapEnd = end < segment.normalizedEnd
            ? end
            : segment.normalizedEnd;
        from += overlapStart - segment.normalizedStart;
        to = segment.originalStart + overlapEnd - segment.normalizedStart;
      }
      if (from < originalStart) originalStart = from;
      if (to > originalEnd) originalEnd = to;
    }
    if (originalEnd <= originalStart || originalStart == originalText.length) {
      return null;
    }
    return SourceSpan.fromText(
      messageId: messageId,
      originalText: originalText,
      start: originalStart,
      end: originalEnd,
    );
  }

  /// Opaque user values such as SSIDs and credentials must not be re-read as
  /// ordinary network instructions.
  bool overlapsOpaqueSource({required int start, required int end}) {
    if (start < 0 || end <= start || end > normalizedText.length) return false;
    var sourceStart = originalText.length;
    var sourceEnd = 0;
    for (final segment in segments) {
      if (segment.normalizedStart == segment.normalizedEnd ||
          segment.normalizedEnd <= start ||
          segment.normalizedStart >= end) {
        continue;
      }
      if (segment.originalStart < sourceStart) {
        sourceStart = segment.originalStart;
      }
      if (segment.originalEnd > sourceEnd) sourceEnd = segment.originalEnd;
    }
    return opaqueSourceRanges.any(
      (range) => range.$1 < sourceEnd && range.$2 > sourceStart,
    );
  }
}
