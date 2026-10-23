/// Recognizes a pasted device running-config / startup-config in chat text.
///
/// When something breaks, people paste the whole `show run` output into the
/// chat - and that paste is neither a question nor a build brief. This
/// reader runs before intent parsing so the chat can offer a config review
/// instead of planning "22 interfaces" as 22 devices.
///
/// Two rules keep it honest:
///
/// * a single-line message never matches. Real configs are dozens of lines;
///   a one-line "hostname R1" is a command to type, not a paste.
/// * multi-line text must look like IOS, not like prose about a network:
///   either the canonical `show run` header ("Current configuration : N
///   bytes", "Building configuration...", or the echoed "show run" command)
///   or at least four lines that START with real config keywords. A plan
///   brief spread over lines ("...and OSPF\nbetween the routers") never
///   clears that bar because its lines do not start with the keywords.
class ConfigPasteReader {
  const ConfigPasteReader._();

  /// True when [text] is a pasted running/startup-config worth reviewing.
  static bool matches(String text) {
    // One line of chat is never a config, however convincing it sounds.
    if (!text.contains('\n')) return false;
    final lines = [for (final l in text.split('\n')) l.trim()];
    final nonEmpty = lines.where((l) => l.isNotEmpty).toList();
    // The `show run` header is proof by itself: nobody types "Current
    // configuration : 980 bytes" into a chat by hand.
    if (nonEmpty.any(_isRunHeader)) return true;
    var markers = 0;
    for (final line in lines) {
      // A lone "!" is the section separator IOS prints between blocks.
      if (line == '!' || _markers.any((p) => p.hasMatch(line))) markers++;
    }
    return markers >= 4;
  }

  /// The hostname from `hostname X`, or null when the paste has none.
  ///
  /// Lets the chat title the review ("Config review - R1") without a model.
  static String? deviceName(String text) {
    final m = RegExp(
      r'^\s*hostname\s+(\S+)',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(text);
    return m?.group(1);
  }

  /// The exact banners a `show running-config` / `show startup-config`
  /// paste carries - stronger evidence than any keyword count.
  static bool _isRunHeader(String line) =>
      RegExp(
        r'^current\s+configuration\s*:\s*\d+\s+bytes$',
        caseSensitive: false,
      ).hasMatch(line) ||
      RegExp(r'^building\s+configuration\s*\.+$', caseSensitive: false)
          .hasMatch(line) ||
      // The echoed command with its prompt ("R1#show running-config").
      RegExp(
        r'^[\w.@-]+[#>]\s*show\s+(?:running-config|run|startup-config|start)\b',
        caseSensitive: false,
      ).hasMatch(line);

  /// Lines that only a real config starts with. Anchored at the line start
  /// so prose mentioning a keyword mid-sentence ("the interface went down")
  /// never counts.
  static final List<RegExp> _markers = [
    RegExp(r'^hostname\s+\S+', caseSensitive: false),
    RegExp(r'^interface\s+\S+', caseSensitive: false),
    RegExp(r'^ip\s+address\s+\S+', caseSensitive: false),
    RegExp(r'^router\s+(?:ospf|eigrp|rip|bgp)\b', caseSensitive: false),
    RegExp(r'^vlan\s+\d+', caseSensitive: false),
    RegExp(r'^line\s+(?:vty|con|console|aux)\b', caseSensitive: false),
    RegExp(r'^crypto\s+\S+', caseSensitive: false),
    RegExp(r'^ip\s+route\s+\S+', caseSensitive: false),
    RegExp(r'^enable\s+(?:secret|password)\b', caseSensitive: false),
    RegExp(r'^switchport\b', caseSensitive: false),
    RegExp(r'^access-list\s+\S+', caseSensitive: false),
    RegExp(r'^banner\s+\S+', caseSensitive: false),
    RegExp(r'^username\s+\S+\s+(?:secret|password)\b', caseSensitive: false),
    RegExp(r'^service\s+password-encryption\b', caseSensitive: false),
    RegExp(r'^ip\s+domain(?:-name)?\s+\S+', caseSensitive: false),
    RegExp(r'^(?:no\s+)?shutdown\b', caseSensitive: false),
    RegExp(r'^version\s+\d', caseSensitive: false),
    RegExp(r'^aaa\s+new-model\b', caseSensitive: false),
  ];
}
