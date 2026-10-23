/// Recognizes requests to learn or diagnose, rather than change a topology.
class NetworkingHelpReader {
  const NetworkingHelpReader._();

  static final _instruction = RegExp(
    r'\b(?:explain|teach|describe|clarify|troubleshoot|diagnose)\b|'
    r'\b(?:help\s+(?:me\s+)?(?:understand|with|troubleshoot)|'
    r'how\s+(?:to|do\s+i|can\s+i|should\s+i|does|do\s+we)|'
    r'walk\s+me\s+through|step[\s-]*by[\s-]*step|'
    r'(?:give|show)\s+me\s+(?:an?\s+)?(?:example|instructions|steps))\b',
  );
  /// A whole-message WH question ("what is ospf?"). Anchored both ends so a
  /// question riding behind a device inventory is NOT swallowed.
  static final _whQuestion = RegExp(
    r'^(?:what|why|which|where|when|who)\b[^!?.]*[?!.,]?$',
  );
  static final _symptom = RegExp(
    r"\b(?:can(?:not|'t)|unable\s+to|fails?\s+to)\s+"
    r'(?:ping|connect|reach|resolve|access|obtain|get)\b|'
    r"\b(?:no\s+internet|not\s+working|does(?:n't|\s+not)\s+work|"
    r'dropping\s+(?:packets|connections)|slow\s+(?:network|internet|wi[ -]?fi))\b',
  );
  static final _change = RegExp(
    r'^(?:(?:please|can\s+you|could\s+you|now)\s+)*'
    r'(?:add|remove|delete|replace|rename|change|update|use|enable|disable|'
    r'build|create|design|plan|make|configure|connect|set\s+up)\b',
  );
  static final _topic = RegExp(
    r'^(?:and\s+|what\s+about\s+)?(?:ospf|eigrp|bgp|stp|dhcp|dns|nat|'
    r'vlans?|subnetting|subnets?|ipv6|ssh|acls?|vpn|routing|port\s+security)'
    r'[\s?!.,]*$',
  );
  static final _followup = RegExp(
    r'^(?:please\s+)?(?:explain\s+(?:it\s+)?more|tell\s+me\s+more|'
    r'give\s+(?:me\s+)?(?:an?\s+)?example|show\s+(?:me\s+)?'
    r'(?:an?\s+)?example|what\s+(?:should\s+i\s+check\s+)?next|'
    r'what\s+does\s+that\s+mean|explain\s+(?:it|that)|'
    r'continue|go\s+on)[\s?!.,]*$',
  );

  static bool isFollowup(String text) => _followup.hasMatch(_normalize(text));

  static final _deviceCount = RegExp(
    r'\b\d{1,3}\s*(?:routers?|switches|switch|pcs?|servers?|laptops?|'
    r'printers?|firewalls?|phones?|tablets?|access\s+points?)\b',
  );

  static bool matches(String text) {
    final t = _normalize(text);
    if (t.isEmpty) return false;
    if (_followup.hasMatch(t)) return true;
    if (_deviceCount.hasMatch(t)) return false;
    if (_change.hasMatch(t)) return false;
    if (_instruction.hasMatch(t) || _symptom.hasMatch(t)) return true;
    if (_whQuestion.hasMatch(t)) return true;
    return _topic.hasMatch(t) ||
        RegExp(r'\b(?:instructions|guidance|advice)\s+only\b').hasMatch(t);
  }

  static String _normalize(String text) =>
      text.trim().toLowerCase().replaceAll('\u2019', "'");
}
