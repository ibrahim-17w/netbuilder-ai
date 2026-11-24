import '../../models/request_interpretation.dart';

/// Only the current user's words select an action. Never pass OCR, config,
/// file contents or tool output as [userText]. Those are grounding data.
enum AttachmentAction { unspecified, explain, compare, import, edit, buildFrom }

class AttachmentIntent {
  final AttachmentAction action;
  final bool requiresClarification;

  const AttachmentIntent(this.action, {this.requiresClarification = false});

  bool get mutationRequested =>
      action == AttachmentAction.import ||
      action == AttachmentAction.edit ||
      action == AttachmentAction.buildFrom;

  RequestMode get mode => switch (action) {
    AttachmentAction.explain => RequestMode.explain,
    AttachmentAction.compare => RequestMode.compare,
    AttachmentAction.import => RequestMode.create,
    AttachmentAction.edit => RequestMode.edit,
    AttachmentAction.buildFrom => RequestMode.build,
    AttachmentAction.unspecified => RequestMode.clarify,
  };

  /// Presence alone is not permission. Review requests and explicit no-change
  /// language win over words such as "build" quoted inside the user question.
  static AttachmentIntent read(String userText, {bool hasAttachments = true}) {
    if (!hasAttachments) {
      return const AttachmentIntent(AttachmentAction.unspecified);
    }
    final text = userText
        .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
        .replaceAll(RegExp(r'''"[^"\n]*"|'[^'\n]*'|“[^”\n]*”'''), ' ')
        .trim()
        .toLowerCase();
    final compare = RegExp(
      r'\b(?:compare|diff|difference(?:s)?)\b|قارن|مقارنة',
    ).hasMatch(text);
    final explain = RegExp(
      r'\b(?:explain|describe|review|summari[sz]e|inspect|analy[sz]e|what|why|how)\b|اشرح|فسر|وض.?ح',
    ).hasMatch(text);
    final noChange = RegExp(
      r"\b(?:do not|don't|dont|never|without)\s+(?:\w+\s+){0,2}(?:change|edit|modify|replace|redesign|build|import|apply)\b|"
      r'\bread[ -]?only\b|\b(?:only|just)\s+(?:explain|compare|review)\b|لا\s+(?:تغير|تغيّر|تعدل|تعدّل|تبني|تستورد)|بدون\s+تعديل',
    ).hasMatch(text);
    if (noChange || compare || explain) {
      return AttachmentIntent(
        compare ? AttachmentAction.compare : AttachmentAction.explain,
      );
    }
    final build = RegExp(
      r'\b(?:build|generate|create|make)\b|ابني|ابنِ|انشئ|أنشئ',
    ).hasMatch(text);
    final import = RegExp(
      r'\b(?:import|load|adopt)\b|استورد|استيراد',
    ).hasMatch(text);
    final edit = RegExp(
      r'\b(?:edit|modify|change|update|repair|fix|replace)\b|عد.?ل|اصلح|أصلح',
    ).hasMatch(text);
    if ([build, import, edit].where((value) => value).length > 1) {
      return const AttachmentIntent(
        AttachmentAction.unspecified,
        requiresClarification: true,
      );
    }
    if (build) return const AttachmentIntent(AttachmentAction.buildFrom);
    if (import) return const AttachmentIntent(AttachmentAction.import);
    if (edit) return const AttachmentIntent(AttachmentAction.edit);
    return const AttachmentIntent(
      AttachmentAction.unspecified,
      requiresClarification: true,
    );
  }
}
