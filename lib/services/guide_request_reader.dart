/// Recognizes instructions for the standing plan, not a topic-specific how-to.
class GuideRequestReader {
  const GuideRequestReader._();

  static bool matches(String raw) {
    var text = raw.trim().toLowerCase().replaceAll('\u2019', "'");
    if (text.isEmpty || text.contains('\n')) return false;
    text = text.replaceAll(RegExp(r'[?!.,]+$'), '').trim();
    text = text.replaceFirst(RegExp(r'^(?:please|pls)\s+'), '');
    text = text.replaceFirst(RegExp(r'\s+please$'), '');
    return RegExp(
      r'^(?:how\s+(?:(?:do|can|could|should|would)\s+(?:i|we|you)|to)\s+'
      r'(?:build|make|create|configure|wire|cable|set\s+up|setup)\s+'
      r'(?:(?:the|my|our|this|current)\s+)?(?:it|this|that|network|plan|lab)|'
      r'how\s+(?:can|do|should)\s+(?:i|we)\s+set\s+(?:it|this|that)\s+up|'
      r'(?:give|show|send|write)\s+(?:me\s+)?(?:the\s+)?(?:build\s+)?'
      r'(?:steps|instructions|guide)(?:\s+for\s+(?:this|the\s+plan))?|'
      r'(?:walk|talk)\s+me\s+through\s+(?:it|this|the\s+(?:plan|build|network))|'
      r'(?:just\s+(?:the\s+)?|only\s+(?:the\s+)?)?'
      r'(?:instructions|steps|build\s+guide|configuration\s+steps)|'
      r'step[\s-]*by[\s-]*step|'
      r'build\s+(?:it|this|the\s+network)\s+without\s+(?:a\s+)?\.?pkt|'
      r'no\s+\.?pkt,?\s+just\s+tell\s+me\s+how)$',
    ).hasMatch(text);
  }
}
