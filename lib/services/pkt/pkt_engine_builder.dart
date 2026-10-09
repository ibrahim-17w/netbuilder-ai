/// Offline .pkt generator: turn a NetBuilder plan into a Packet Tracer save,
/// on the device, with no sidecar.
///
/// This is a port of `sidecar/pkt_builder.py` - the plan is exactly what
/// `PacketTracerAdapter.autopilotPlan` produces (`create_nodes`,
/// `create_links`, `paste_cli`, `config_pcs`, `config_servers`), and the
/// library is the one `sidecar/pkt_template_build.py` extracted from real
/// Packet Tracer saves. What ends up inside the generated file:
///
/// * one `<DEVICE>` per planned node, cloned from the matching model template
///   with a fresh id, name, MACs, canvas position and (for routers/switches)
///   the compiled running config as `<RUNNINGCONFIG>` lines,
/// * one `<LINK>` per planned link, with both endpoints resolved to the port
///   names Packet Tracer derives from the module layout,
/// * the interface IP settings of every end device (PC/laptop/server/printer)
///   on the port that actually carries the link,
/// * the Services tab of every server (DHCP pools, DNS records, HTTP/HTTPS,
///   FTP/email accounts, the ACS/TACACS+ users and clients, syslog/NTP/TFTP,
///   SNMP), which lives inside the server's `<ENGINE>` block,
/// * a rebuilt Physical Workspace, so the leaves match the devices and Packet
///   Tracer never rejects the save as corrupted workspace data.
///
/// Everything the generator cannot know is reported in `warnings` instead of
/// being invented: an unknown model, a port the model does not have, a cable
/// kind the library has never seen. A run that produced warnings still
/// returns a file - the caller decides whether to show it as complete.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:xml/xml.dart' as xml;
import 'package:uuid/uuid.dart';

import 'template_library.dart';

// ---------------------------------------------------------------------------
// Vocabulary
// ---------------------------------------------------------------------------

/// Node types (the app's vocabulary) -> substrings of Packet Tracer's kind
/// text inside `<TYPE ...>Router</TYPE>`.
const Map<String, List<String>> _kindPatterns = {  'router': ['router'],
  'wireless-router': ['wirelessrouter', 'wireless router', 'homerouter'],
  'switch': ['switch', 'multilayerswitch', 'internetswitch'],
  'pc': ['pc', 'workstation'],
  'laptop': ['laptop'],
  'server': ['server'],
  'printer': ['printer'],
  'firewall': ['firewall', 'asa', 'securityappliance'],
  'wireless': ['accesspoint', 'wirelessaccesspoint', 'wireless'],
  'wlc': ['wirelesslancontroller', 'wlc'],
  'phone': ['ipphone', 'phone'],
  'modem': ['modem', 'dslmodem', 'cablemodem'],
  'tv': ['tv', 'smarttv'],
  'cloud': ['cloud'],
  'iot': ['iot', 'mcu', 'homegateway'],
  'tablet': ['tablet'],
  'smartphone': ['smartphone', 'cellphone', 'pda'],
};

/// Cable kind -> (link medium, cable type) as Packet Tracer names them.
const Map<String, (String, String)> _linkMediums = {
  'copper': ('eCopper', 'eStraightThrough'),
  'straight': ('eCopper', 'eStraightThrough'),
  'copper-cross': ('eCopper', 'eCrossOver'),
  'cross': ('eCopper', 'eCrossOver'),
  'crossover': ('eCopper', 'eCrossOver'),
  'serial': ('eSerial', 'eSerial'),
  'serial-dce': ('eSerial', 'eSerial'),
  'serial-dte': ('eSerial', 'eSerial'),
  'fiber': ('eFiber', 'eFiber'),
  'console': ('eConsole', 'eConsole'),
};

/// Copper LAN families a spare-port remap may use (never serial/wireless).
const List<String> _ethernetFamilies = [
  'fastethernet',
  'gigabitethernet',
  'ethernet',
];

/// Exec-mode lines the app types at the CLI but that must not live inside a
/// saved running config: Packet Tracer replays this text in config mode.
const Set<String> _nonConfigLines = {
  'write memory',
  'write',
  'wr',
  'copy running-config startup-config',
  'copy run start',
  'configure terminal',
  'conf t',
  'enable',
  'terminal length 0',
  'end',
};

/// ASA (Firewall-PT) interfaces that are not physical ports: an ASA-5505
/// routes through `interface Vlan1`, and Packet Tracer stores no `<PORT>`
/// for one. They are real config lines and must survive untouched.
final RegExp _virtualInterfaces =
    RegExp(r'^(vlan|bvi|management|inside|outside|dmz)[0-9]*$', caseSensitive: false);

/// A dot1Q sub-interface: `<parent-port>.<vlan>` (router-on-a-stick). The
/// parent is the hardware; the suffix is config on it.
final RegExp _subinterface = RegExp(r'^(\S+)\.(\d+)$');

final RegExp _positionRe = RegExp(r'^([a-z]+)((?:[0-9]+(?:/[0-9]+)*)?)$');
const Map<String, String> _portAliases = {
  'f': 'fastethernet',
  'fa': 'fastethernet',
  'fe': 'fastethernet',
  'g': 'gigabitethernet',
  'gi': 'gigabitethernet',
  'ge': 'gigabitethernet',
  'e': 'ethernet',
  'eth': 'ethernet',
  's': 'serial',
  'se': 'serial',
  'ser': 'serial',
  'w': 'wireless',
  'wlan': 'wireless',
};
const List<String> _portFamilies = [
  'fastethernet',
  'gigabitethernet',
  'ethernet',
  'serial',
  'fiber',
  'wireless',
];

// Fallback placement (a plan whose layout carries no positions): the `rows`
// drawing - one band per device kind, wrapped so no row runs off the canvas.
const int _rowTop = 60;
const int _bandStep = 190;
const int _rowStep = 130;
const int _devicePitch = 120;
const int _canvasWidth = 1400;
const int _xStart = 140;
const int _rowsPerRow = 8;
const int _defaultRowY = _rowTop + _bandStep;

// The service elements a server's <ENGINE> can carry.
const List<String> _serviceTags = [
  'NTP_SERVER',
  'HTTP_SERVER',
  'HTTPS_SERVER',
  'DNS_SERVER',
  'DHCP_SERVERS',
  'FTP_SERVER',
  'SYSLOG_SERVER',
  'ACS_SERVER',
  'EMAIL_SERVER',
  'TFTP_SERVER',
  'DHCPV6_SERVER_LIST',
  'IOE_USER_MANAGER',
  'IOX_VM_MANAGER',
  'REGISTRATION_SEVER',
  'SNMP_MANAGER',
];

// ---------------------------------------------------------------------------
// Port naming
// ---------------------------------------------------------------------------

/// 'g0/1' and 'GigabitEthernet0/1' become 'gigabitethernet0/1'.
String normalizePortName(String name) {
  final text = name.trim().toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
  final match = _positionRe.firstMatch(text);
  if (match == null) return text;
  final prefix = _portAliases[match.group(1)] ?? match.group(1)!;
  return prefix + (match.group(2) ?? '');
}

String _familyFromRequest(String want) {
  for (final family in _portFamilies) {
    if (want.startsWith(family)) return family;
  }
  return '';
}

/// Find the template port a plan/config name refers to.
///
/// Returns the port, plus a non-empty note when the name had to be
/// interpreted (bare family, or a slot remap). [taken] is the set of port
/// names this device has already given to another interface: a device has a
/// fixed number of ports, so the second of two names on a two-port model must
/// not land on the port the first one took.
({PktTemplatePort? port, String note}) resolvePort(
  PktTemplateDevice variant,
  String requested, {
  Set<String> taken = const <String>{},
}) {
  final want = normalizePortName(requested);
  if (want.isEmpty) return (port: null, note: '');
  final ports = variant.ports;
  final claimed = {for (final name in taken) name};
  var exactTaken = false;
  for (final port in ports) {
    if (port.name.isNotEmpty && normalizePortName(port.name) == want) {
      if (claimed.contains(port.name)) {
        // The name matches, but this device already gave that port to another
        // interface. Returning it anyway is how a router ends up with two
        // cables on one interface: one interface, two links, and the second
        // `interface` block overwrites the first.
        exactTaken = true;
        continue;
      }
      return (port: port, note: '');
    }
  }
  // A bare family ("f0", "eth0") means the first free port of it.
  for (final port in ports) {
    if (port.name.isNotEmpty && want == port.family) {
      if (claimed.contains(port.name)) continue;
      return (port: port, note: '$requested -> ${port.name} (first of family)');
    }
  }
  final family = _familyFromRequest(want);
  // Inside the copper Ethernet family the models are interchangeable: a plan
  // that says GigabitEthernet on a FastEthernet-only model is remapped. The
  // note keeps the remap visible.
  const families = {
    'ethernet': ['ethernet', 'fastethernet', 'gigabitethernet'],
    'fastethernet': ['fastethernet', 'ethernet', 'gigabitethernet'],
    'gigabitethernet': ['gigabitethernet', 'fastethernet', 'ethernet'],
  };
  final candidates = families[family] ?? (family.isEmpty ? <String>[] : [family]);
  for (final candidate in candidates) {
    for (final port in ports) {
      if (port.name.isEmpty || port.family != candidate) continue;
      if (claimed.contains(port.name)) continue;
      if (exactTaken) {
        return (
          port: port,
          note: '$requested -> ${port.name} '
              '($requested is already carrying a cable)',
        );
      }
      return (port: port, note: '$requested -> ${port.name} (slot remap)');
    }
  }
  return (port: null, note: '');
}

/// The port under exactly the name the plan spelled, or null.
///
/// Used to reserve a model's OWN interfaces before any name it does not have
/// is remapped onto a spare: the plan's real interfaces must keep the ports
/// they name, and only the invented ones may take what is left.
PktTemplatePort? exactPort(PktTemplateDevice variant, String spec) {
  final want = normalizePortName(spec);
  if (want.isEmpty || _subinterface.hasMatch(spec.trim())) return null;
  for (final port in variant.ports) {
    if (port.name.isNotEmpty && normalizePortName(port.name) == want) {
      return port;
    }
  }
  return null;
}

/// One device's claim table: each interface name resolved once, shared by the
/// config remap and the links, so a two-port router cannot put its WAN and
/// its LAN on one port.
class ResolvedPorts {
  final Map<String, PktTemplatePort> _byName = {};

  /// Reserve a port the model really has, under the name the plan spelled,
  /// without resolving (used to claim real interfaces before any invented
  /// name is remapped onto a spare).
  void claimExact(String key, PktTemplatePort port) {
    _byName.putIfAbsent(key, () => port);
  }

  ({PktTemplatePort? port, String note}) resolve(
    PktTemplateDevice variant,
    String spec,
  ) {
    final key = normalizePortName(spec);
    if (key.isEmpty) return (port: null, note: '');
    final cached = _byName[key];
    if (cached != null) return (port: cached, note: '');
    final taken = _byName.values.map((p) => p.name).toSet();
    final (port: port, note: note) = resolvePort(variant, spec, taken: taken);
    if (port != null) _byName[key] = port;
    return (port: port, note: note);
  }

  Iterable<PktTemplatePort> get values => _byName.values;
}

// ---------------------------------------------------------------------------
// Kind matching and template selection
// ---------------------------------------------------------------------------

bool _kindMatches(String kind, String nodeType) {
  final text = kind.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  final node = nodeType.trim().toLowerCase();
  final patterns = _kindPatterns[node] ?? [node];
  for (final pattern in patterns) {
    if (pattern.replaceAll(RegExp(r'[^a-z0-9]+'), '').isEmpty) continue;
    if (text.contains(pattern.replaceAll(RegExp(r'[^a-z0-9]+'), ''))) {
      return true;
    }
  }
  return false;
}

bool _kindTextMatches(String kind, String nodeType) {
  final text = kind.trim().toLowerCase().replaceAll(' ', '').replaceAll('-', '');
  final node = nodeType.trim().toLowerCase().replaceAll(' ', '');
  return text.isNotEmpty &&
      node.isNotEmpty &&
      (text == node || node.contains(text) || text.contains(node));
}

/// Reject a library record whose saved device block identifies another kind.
///
/// The manifest is data; a stale record can claim to be a model while
/// pointing at a block cloned from a different device. Packet Tracer may
/// reject that otherwise well-formed XML while loading its workspace.
Future<String> _templateIdentityMismatch(
  PktTemplateLibrary library,
  PktTemplateDevice entry,
) async {
  final String block;
  try {
    block = await library.blockFor(entry.file);
  } on PktBuildFailure {
    return 'template block is missing';
  }
  xml.XmlDocument document;
  try {
    document = xml.XmlDocument.parse(block);
  } catch (_) {
    return 'template block is not valid XML';
  }
  final root = document.rootElement;
  var deviceType = root.getElement('ENGINE')?.getElement('TYPE');
  deviceType ??= root.getElement('TYPE');
  if (deviceType == null) return 'template has no ENGINE/TYPE identity';

  String identity(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  final actualModel = deviceType.getAttribute('model') ?? '';
  final actualKind = deviceType.innerText.trim();
  final expectedModel = entry.model.trim();
  final expectedKind = entry.kind.trim();
  final mismatches = <String>[];
  if (identity(actualModel) != identity(expectedModel)) {
    mismatches.add(
      'model is ${actualModel.isEmpty ? '(empty)' : actualModel}, expected '
      '${expectedModel.isEmpty ? '(empty)' : expectedModel}',
    );
  }
  if (identity(actualKind) != identity(expectedKind)) {
    mismatches.add(
      'device kind is ${actualKind.isEmpty ? '(empty)' : actualKind}, '
      'expected ${expectedKind.isEmpty ? '(empty)' : expectedKind}',
    );
  }
  return mismatches.join('; ');
}

/// Pick the model template that best covers this node and its ports.
Future<(PktTemplateDevice?, List<String>)> selectVariant(
  PktTemplateLibrary library,
  Map<String, dynamic> node,
  List<String> wantedPorts,
) async {
  final nodeType = '${node['type'] ?? ''}'.trim().toLowerCase();
  final name = '${node['name'] ?? ''}';
  final wanted = [for (final p in wantedPorts) p];
  var candidates = [
    for (final entry in library.devices)
      if (_kindMatches(entry.kind, nodeType)) entry,
  ];
  if (candidates.isEmpty) {
    candidates = [
      for (final entry in library.devices)
        if (_kindTextMatches(entry.kind, nodeType)) entry,
    ];
  }
  final validCandidates = <PktTemplateDevice>[];
  final rejected = <String>[];
  for (final entry in candidates) {
    final mismatch = await _templateIdentityMismatch(library, entry);
    if (mismatch.isNotEmpty) {
      rejected.add('$name: ignored incompatible template ${entry.key}: '
          '$mismatch');
    } else {
      validCandidates.add(entry);
    }
  }
  candidates = validCandidates;
  if (candidates.isEmpty) {
    return (
      null,
      rejected +
          [
            '$name: no ${nodeType.isEmpty ? 'device' : nodeType} model has a '
                'valid template - node skipped',
          ],
    );
  }
  final modelHint = '${node['model'] ?? ''}'.trim().toLowerCase();

  int coverage(PktTemplateDevice entry) {
    var hits = 0;
    for (final port in wanted) {
      final (port: resolved, note: _) = resolvePort(entry, port);
      if (resolved != null) hits++;
    }
    return hits;
  }

  /// 1 when every requested interface gets its own physical port. The plan's
  /// cabling is only buildable if the hardware has a port per link.
  int fits(PktTemplateDevice entry) {
    if (wanted.isEmpty) return 1;
    final claimed = ResolvedPorts();
    for (final spec in wanted) {
      final (port: port, note: _) = claimed.resolve(entry, spec);
      if (port == null) return 0;
    }
    return 1;
  }

  bool hintFor(PktTemplateDevice entry) {
    final model = entry.model.toLowerCase();
    return modelHint.isNotEmpty &&
        (model == modelHint || model.startsWith(modelHint));
  }

  // Python's tuple key `(fits, coverage, hint, -len(ports))`, compared by
  // hand: fits dominates, then coverage, then the model hint, then fewer
  // ports wins.
  int compare(PktTemplateDevice a, PktTemplateDevice b) {
    final (fa, fb) = (fits(a), fits(b));
    if (fa != fb) return fa.compareTo(fb);
    final (ca, cb) = (coverage(a), coverage(b));
    if (ca != cb) return ca.compareTo(cb);
    final (ha, hb) = (hintFor(a), hintFor(b));
    if (ha != hb) return ha == true ? 1 : -1;
    return b.ports.length.compareTo(a.ports.length); // fewer ports wins
  }

  PktTemplateDevice best = candidates.first;
  for (final entry in candidates.skip(1)) {
    if (compare(entry, best) > 0) best = entry;
  }
  final notes = List<String>.from(rejected);
  final missing = <String>[];
  for (final port in wanted) {
    final (port: resolved, note: _) = resolvePort(best, port);
    if (resolved == null) missing.add(port);
  }
  if (missing.isNotEmpty) {
    notes.add('$name: template ${best.key} has no port for '
        '${missing.join(', ')}');
  }
  if (modelHint.isNotEmpty && !best.model.toLowerCase().contains(modelHint)) {
    // Say *why*, not just that: the hinted model usually exists and was
    // passed over because it has no port for one of the requested
    // interfaces.
    PktTemplateDevice? hinted;
    for (final entry in candidates) {
      if (entry.model.toLowerCase().startsWith(modelHint)) {
        hinted = entry;
        break;
      }
    }
    var miss = <String>[];
    if (hinted != null) {
      final claimed = ResolvedPorts();
      for (final port in wanted) {
        final (port: resolved, note: _) = claimed.resolve(hinted, port);
        if (resolved == null) miss.add(port);
      }
    }
    final reason = miss.isNotEmpty
        ? ' (its template has no port for ${miss.join(', ')})'
        : '';
    notes.add('$name: used ${best.model} instead of $modelHint$reason');
  }
  return (best, notes);
}

// ---------------------------------------------------------------------------
// Block surgery
// ---------------------------------------------------------------------------

String _esc(String text) => xmlSafeText(text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;'));

/// Match `<TAG ...>` / `<TAG .../>` (or the closing form), tolerating
/// attributes: Packet Tracer writes attributes on some fields - `<NAME
/// translate="true">` always - so a matcher that only knows the plain form
/// silently skips a tag that is really there.
RegExp _tagPattern(String tag, {bool closing = false}) {
  final attrs = r"((?:\s+[^>\s/]+(?:\s*=\s*(?:""[^""]*""|'[^']*'))?)*)";
  final name = RegExp.escape(tag);
  return RegExp('<${closing ? '/' : ''}$name$attrs\\s*/?>');
}

bool _hasTag(String block, String tag) =>
    _tagPattern(tag).hasMatch(block);

/// Replace the first TAG element's text, keeping its own attributes.
/// Set [tag] inside [block], creating the element when it is absent.
///
/// [_setTag] deliberately leaves a block untouched when the tag is not there:
/// a device block's own tags (RUNNINGCONFIG, SYSCONTACT) are PT-authored and
/// must not be invented. A `<PORT>`'s `<NAME>` is the opposite - a port the
/// source save never named NEEDS one, or the cable that references it points
/// at nothing. So the insert happens only where it is asked for, never as a
/// blanket default.
String _setTagOrInsert(String block, String tag, String value) {
  final out = _setTag(block, tag, value);
  if (!identical(out, block)) return out;
  final opener = RegExp('<PORT(?:\\s[^>]*)?>');
  final at = opener.firstMatch(block);
  if (at == null) return block;
  final insertAt = at.end;
  return '${block.substring(0, insertAt)}<$tag>${_esc(value)}</$tag>'
      '${block.substring(insertAt)}';
}

String _setTag(String block, String tag, String value) {
  final name = RegExp.escape(tag);
  final attrs = r"((?:\s+[^>\s/]+(?:\s*=\s*(?:""[^""]*""|'[^']*'))?)*)";
  final pattern = RegExp(
    '<$name$attrs\\s*/>|<$name$attrs\\s*>.*?</$name>',
  );
  var replaced = false;
  final out = block.replaceFirstMapped(pattern, (m) {
    replaced = true;
    // The captured attributes keep their leading whitespace - they are
    // spliced between the tag name and `>`, so `<PHYSICAL translate="true">`
    // stays `<PHYSICAL translate="true">`.
    final attributes = m.group(1) ?? m.group(2) ?? '';
    return '<$tag$attributes>${_esc(value)}</$tag>';
  });
  return replaced ? out : block;
}

String _replaceFirst(String source, Pattern pattern, String replacement) =>
    // replaceFirstMapped, not replaceFirst: a plain-string replacement would
    // interpret `$1`-style group references, and config text legally contains
    // `$`.
    source.replaceFirstMapped(pattern, (_) => replacement);

String _setName(String block, String name) {
  var out = _replaceFirst(
    block,
    RegExp(r'<NAME translate="true">[^<]*</NAME>'),
    '<NAME translate="true">${_esc(name)}</NAME>',
  );
  // The CLI hostname is identity too: a generated device must never inherit
  // the template source's stale hostname either.
  out = _replaceFirst(
    out,
    RegExp(r'<SYS_NAME>[^<]*</SYS_NAME>'),
    '<SYS_NAME>${_esc(name)}</SYS_NAME>',
  );
  return out;
}

String _setRefId(String block, int ref) {
  final value = '<SAVE_REF_ID>save-ref-id:$ref</SAVE_REF_ID>';
  if (_hasTag(block, 'SAVE_REF_ID')) {
    return _replaceFirst(
      block,
      RegExp(r'<SAVE_REF_ID(?:\s[^>]*)?>[^<]*</SAVE_REF_ID>'),
      value,
    );
  }
  final close = block.indexOf('</ENGINE>');
  if (close >= 0) {
    return '${block.substring(0, close)}   $value\n  ${block.substring(close)}';
  }
  final match = RegExp(r'<DEVICE(?:\s[^>]*)?>').firstMatch(block);
  if (match == null) return block;
  return '${block.substring(0, match.end)}\n   $value${block.substring(match.end)}';
}

/// Byte spans of the block's own `<PORT>` elements, in document order.
/// Depth-aware so a port nested inside another port's module tree can never
/// be mistaken for a sibling. Port of `pkt_template_build.iter_port_spans`.
List<(int, int)> iterPortSpans(String block) {
  final spans = <(int, int)>[];
  final tagRe = RegExp(r'</?PORT(?=[\s/>])[^>]*>');
  var depth = 0;
  int? start;
  for (final match in tagRe.allMatches(block)) {
    final tag = match.group(0)!;
    if (tag.startsWith('</')) {
      depth--;
      if (depth <= 0 && start != null) {
        spans.add((start, match.end));
        start = null;
        depth = depth < 0 ? 0 : depth;
      }
      continue;
    }
    if (tag.endsWith('/>') || tag == '<PORT />') {
      if (depth == 0) spans.add((match.start, match.end));
      continue;
    }
    if (depth == 0) start = match.start;
    depth++;
  }
  if (start != null) spans.add((start, block.length));
  return spans;
}

String _macFor(String seed, int index) {
  final digest =
      crypto.sha1.convert(utf8.encode('$seed:$index')).bytes;
  final first = (digest[0] | 0x02) & 0xFF;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();
  return '${hex(first)}${hex(digest[1])}.${hex(digest[2])}${hex(digest[3])}.'
      '${hex(digest[4])}${hex(digest[5])}';
}

String _setMacs(String block, String seed) {
  final spans = iterPortSpans(block);
  if (spans.isEmpty) return block;
  final out = StringBuffer();
  var cursor = 0;
  for (var index = 0; index < spans.length; index++) {
    final (start, end) = spans[index];
    out.write(block.substring(cursor, start));
    final mac = _macFor(seed, index);
    final port = block
        .substring(start, end)
        .replaceAllMapped(
          RegExp(r'<(MACADDRESS|BIA)>[^<]*</\1>'),
          (m) => '<${m.group(1)}>$mac</${m.group(1)}>',
        );
    out.write(port);
    cursor = end;
  }
  out.write(block.substring(cursor));
  return out.toString();
}

String _setPosition(String block, int x, int y) {
  final match = RegExp(r'<LOGICAL>.*?</LOGICAL>', dotAll: true)
      .firstMatch(block);
  if (match == null) return block;
  final logical = match.group(0)!;
  var fixed = logical.replaceFirst(
    RegExp(r'<X>[^<]*</X>'),
    '<X>$x</X>',
  );
  fixed = fixed.replaceFirst(RegExp(r'<Y>[^<]*</Y>'), '<Y>$y</Y>');
  return block.substring(0, match.start) +
      fixed +
      block.substring(match.end);
}

String _setConfigTag(String block, String tag, List<String> lines) {
  if (!_hasTag(block, tag)) return block;
  final String replacement;
  if (lines.isNotEmpty) {
    final body = lines
        .map((line) => '      <LINE>${_esc(line)}</LINE>')
        .join('\n');
    replacement = '<$tag>\n$body\n     </$tag>';
  } else {
    replacement = '<$tag/>';
  }
  final pattern = RegExp(
    '<$tag(?:\\s[^>]*)?>.*?</$tag>|<$tag(?:\\s[^>]*)?/>',
    dotAll: true,
  );
  return block.replaceFirstMapped(pattern, (_) => replacement);
}

/// The plan's config becomes both the running and the startup config.
///
/// A generated device has never run `write memory`, and every cloned block
/// still carries the STARTUPCONFIG of the save it came from - which holds the
/// *source* device's hostname, banners and password hashes. Leaving that in
/// place means a generated R2 can answer `show startup-config` with R1's
/// config and its secrets, so the plan's text is written to both.
String _setConfig(String block, List<String> lines) {
  final out = _setConfigTag(block, 'RUNNINGCONFIG', lines);
  return _setConfigTag(out, 'STARTUPCONFIG', lines);
}

String _patchPort(String block, int portIndex, Map<String, String> fields) {
  final spans = iterPortSpans(block);
  if (portIndex < 0 || portIndex >= spans.length) return block;
  final (start, end) = spans[portIndex];
  var port = block.substring(start, end);
  fields.forEach((tag, value) {
    // A field the block does not carry is a field Packet Tracer did not give
    // this model, and inventing one is worse than leaving it out - so these
    // stay replace-only. The port NAME is the one thing that must be created
    // when missing, and it has its own stamp below.
    port = _setTag(port, tag, value);
  });
  return block.substring(0, start) + port + block.substring(end);
}

/// Write [portName] onto the port at [portIndex], creating the `<NAME>`
/// element when the source block has none.
///
/// Every access point is that case: Packet Tracer names the port from the
/// host module and never writes it into the save, so the block has no
/// `<NAME>` at all. A LINK block references its ports by name, so a cable
/// pointing at `FastEthernet0` resolves to nothing and the whole link is
/// dropped - which is how a plan that SW1plumbed to an AP came out with the
/// AP floating, cabled to nothing.
String _stampPortName(String block, int portIndex, String portName) {
  final spans = iterPortSpans(block);
  if (portIndex < 0 || portIndex >= spans.length) return block;
  final (start, end) = spans[portIndex];
  final port = _setTagOrInsert(
    block.substring(start, end),
    'NAME',
    portName,
  );
  return block.substring(0, start) + port + block.substring(end);
}

// ---------------------------------------------------------------------------
// Config text helpers
// ---------------------------------------------------------------------------

(List<String>, List<String>) _sanitizeConfigLines(String text) {
  final lines = <String>[];
  final dropped = <String>[];
  for (final raw
      in text.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.replaceFirst(RegExp(r'\s+$'), '');
    final stripped = line.trim();
    if (stripped.isEmpty) {
      lines.add('!');
      continue;
    }
    if (_nonConfigLines.contains(stripped.toLowerCase())) {
      dropped.add(stripped);
      continue;
    }
    lines.add(stripped);
  }
  while (lines.isNotEmpty && lines.last == '!') {
    lines.removeLast();
  }
  return (lines, dropped);
}

List<String> _interfaceLines(List<String> lines) {
  final names = <String>[];
  for (final line in lines) {
    final match =
        RegExp(r'^interface\s+(\S+)\s*$', caseSensitive: false).firstMatch(line);
    if (match != null) {
      final name = match.group(1)!;
      // A dot1Q sub-interface rides on its parent's hardware, so it must not
      // claim a port of its own; a virtual interface (an ASA's Vlan1) has no
      // port to claim either.
      if (_subinterface.hasMatch(name)) continue;
      if (_virtualInterfaces.hasMatch(name)) continue;
      names.add(name);
      continue;
    }
    final range = RegExp(r'^interface\s+range\s+(\S+)\s*-\s*(\S+)\s*$',
            caseSensitive: false)
        .firstMatch(line);
    if (range != null) {
      names.add(range.group(1)!);
      // `interface range f0/2 - 24` names the second end as a bare number:
      // it is a range boundary, not a port this device must have, so only a
      // fully qualified end is claimed.
      final last = range.group(2)!;
      if (_familyFromRequest(normalizePortName(last)).isNotEmpty) {
        names.add(last);
      }
    }
  }
  return names;
}

/// Rewrite interface names to the ports this model really has.
///
/// [resolved] is shared with the link resolution for the same device, so the
/// config's interfaces and the cables land on the same ports.
(List<String>, List<String>) _remapConfigInterfaces(
  PktTemplateDevice variant,
  List<String> lines,
  ResolvedPorts resolved,
) {
  final notes = <String>[];
  final out = <String>[];
  for (var line in lines) {
    final sub = RegExp(r'^interface\s+(\S+?)\.(\d+)\s*$', caseSensitive: false)
        .firstMatch(line);
    if (sub != null) {
      // Sub-interface: rewrite only the parent to the port this model really
      // has and keep the VLAN suffix. The parent resolution is shared with
      // the links, so the trunk and the sub-interfaces land on the same
      // physical port.
      final base = sub.group(1)!;
      if (!_virtualInterfaces.hasMatch(base)) {
        final (port: port, note: _) = resolved.resolve(variant, base);
        if (port != null) {
          line = 'interface ${port.name}.${sub.group(2)}';
        }
      }
      out.add(line);
      continue;
    }
    final match =
        RegExp(r'^interface\s+(\S+)\s*$', caseSensitive: false).firstMatch(line);
    if (match != null) {
      final requested = match.group(1)!;
      if (_virtualInterfaces.hasMatch(requested)) {
        out.add(line);
        continue;
      }
      final (port: port, note: note) = resolved.resolve(variant, requested);
      if (port != null) {
        if (note.isNotEmpty) notes.add('config: $note');
        line = 'interface ${port.name}';
      } else if (_familyFromRequest(normalizePortName(requested))
          .isNotEmpty) {
        notes.add('config references $requested, which ${variant.key} does '
            'not have');
      }
      out.add(line);
      continue;
    }
    final range = RegExp(r'^interface\s+range\s+(\S+)\s*-\s*(\S+)\s*$',
            caseSensitive: false)
        .firstMatch(line);
    if (range != null) {
      final (port: first, note: _) = resolved.resolve(variant, range.group(1)!);
      final (port: last, note: _) = resolved.resolve(variant, range.group(2)!);
      if (first != null && last != null) {
        line = 'interface range ${first.name} - ${last.name}';
      }
      out.add(line);
      continue;
    }
    out.add(line);
  }
  return (out, notes);
}

/// Config lines grouped by interface, subcommands in order.
Map<String, List<String>> _interfaceBlocks(List<String> lines) {
  final blocks = <String, List<String>>{};
  var current = '';
  for (final line in lines) {
    final match =
        RegExp(r'^interface\s+(\S+)\s*$', caseSensitive: false).firstMatch(line);
    if (match != null) {
      current = match.group(1)!;
      blocks.putIfAbsent(current, () => <String>[]);
      continue;
    }
    if (current.isNotEmpty) blocks[current]!.add(line);
  }
  return blocks;
}

/// The `clock rate N` configured on one interface, if any.
String _clockRateFor(List<String> lines, String portName) {
  final wanted = normalizePortName(portName);
  var current = '';
  for (final line in lines) {
    final match =
        RegExp(r'^interface\s+(\S+)\s*$', caseSensitive: false).firstMatch(line);
    if (match != null) {
      current = normalizePortName(match.group(1)!);
      continue;
    }
    final clock =
        RegExp(r'^clock rate\s+(\d+)\s*$', caseSensitive: false).firstMatch(line);
    if (clock != null && current == wanted) return clock.group(1)!;
  }
  return '';
}

// ---------------------------------------------------------------------------
// Stable identity
// ---------------------------------------------------------------------------

int _refId(String seed, Set<int> used) {
  final digest = crypto.sha256.convert(utf8.encode(seed)).bytes;
  var ref = 0;
  for (var i = 0; i < 8; i++) {
    ref |= digest[i] << (56 - 8 * i);
  }
  ref &= 0x7FFFFFFFFFFFFFFF;
  var guard = 0;
  while ((ref == 0 || used.contains(ref)) && guard < 64) {
    ref = ((ref * 6364136223846793005 + 1442695040888963407) &
            0x7FFFFFFFFFFFFFFF);
    guard++;
  }
  used.add(ref);
  return ref;
}

/// A Packet Tracer UUID string (UUIDv5, braces included) that is unique and
/// stable per device.
String _stableGuid(List<String> parts) {
  final seed = 'netbuilder-pkt:${parts.join(':')}';
  final value = const Uuid().v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8', seed);
  return '{$value}';
}

// ---------------------------------------------------------------------------
// Links
// ---------------------------------------------------------------------------

(PktTemplateLink?, String) _pickLinkTemplate(
  PktTemplateLibrary library,
  String cable,
) {
  final (medium, cableType) =
      _linkMediums[cable.trim().toLowerCase()] ?? ('eCopper', 'eStraightThrough');
  for (final entry in library.links) {
    if (entry.type == medium && entry.cable == cableType) return (entry, '');
  }
  for (final entry in library.links) {
    if (entry.type == medium) return (entry, '');
  }
  // A console link cannot be built offline, and the reason is deeper than one
  // missing XML file: the template library was extracted from real saves, and
  // neither its link list nor any device template carries a console cable or a
  // Console/RS232 port, so the link's endpoints could not be resolved anyway.
  // Say what IS possible instead of a bare "not found" - the autopilot engine
  // wires console cables in the Packet Tracer window itself (it clicks the
  // Console entry in the Connections palette), and so can the user by hand.
  if (medium == 'eConsole') {
    return (
      null,
      'no console cable template in the library, and no device template '
          'carries a Console/RS232 port to cable it to - an offline file '
          'cannot carry this link; wire the console cable in Packet Tracer '
          'itself (the autopilot engine can click it from the Connections '
          'palette)'
    );
  }
  return (null, medium == 'eCopper' ? '' : 'no $medium cable template in the '
      'library');
}

/// A free copper Ethernet port for [device], or ''.
///
/// [usedPorts] records every port already claimed by a link or a config
/// interface. Only link-capable families are offered (never a serial or
/// wireless port for a copper link), in template order.
String _spareEthernetPort(
  Set<(String, String)> usedPorts,
  String device,
  List<PktTemplatePort> ports,
) {
  final taken = <String>{
    for (final (dev, port) in usedPorts)
      if (dev == device) port,
  };
  for (final port in ports) {
    if (port.name.isEmpty || !_ethernetFamilies.contains(port.family)) {
      continue;
    }
    if (!taken.contains(port.name)) return port.name;
  }
  return '';
}

String? _buildLink({
  required PktTemplateLink template,
  required String templateBlock,
  required Map<String, dynamic> link,
  required Map<String, int> refs,
  required Map<(String, String), String> portNames,
  required List<String> warnings,
  required Map<(String, String), String> dcePorts,
  required Set<(String, String)> usedPorts,
  required Map<String, PktTemplateDevice> variants,
}) {
  final nameA = '${link['a'] ?? ''}';
  final nameB = '${link['b'] ?? ''}';
  if (!refs.containsKey(nameA) || !refs.containsKey(nameB)) {
    warnings.add('link $nameA-$nameB: endpoint was skipped');
    return null;
  }
  final requestedCable = '${link['cable'] ?? 'copper'}';
  final block = templateBlock;
  if (block.isEmpty) {
    warnings.add('link $nameA-$nameB: template block missing');
    return null;
  }
  final keyA = (nameA, '${link['aIf'] ?? ''}');
  final keyB = (nameB, '${link['bIf'] ?? ''}');
  var portA = portNames[keyA];
  var portB = portNames[keyB];
  // A copper LAN whose interface could not be resolved can fall back to a
  // free Ethernet port - a LAN on another Ethernet slot is still a LAN.
  // Serial, fiber, and console links must retain their requested medium.
  final (medium, _) =
      _linkMediums[requestedCable.trim().toLowerCase()] ?? ('eCopper', '');
  final allowEthernetRemap = medium == 'eCopper';
  if (allowEthernetRemap && portA == null) {
    final spare = _spareEthernetPort(
      usedPorts,
      nameA,
      variants[nameA]?.ports ?? const <PktTemplatePort>[],
    );
    if (spare.isNotEmpty) {
      portA = spare;
      portNames[keyA] = spare;
      warnings.add('link $nameA-$nameB: ${link['aIf']} not usable on $nameA; '
          'cabled on $spare (spare-port remap)');
    }
  }
  if (allowEthernetRemap && portB == null) {
    final spare = _spareEthernetPort(
      usedPorts,
      nameB,
      variants[nameB]?.ports ?? const <PktTemplatePort>[],
    );
    if (spare.isNotEmpty) {
      portB = spare;
      portNames[keyB] = spare;
      warnings.add('link $nameA-$nameB: ${link['bIf']} not usable on $nameB; '
          'cabled on $spare (spare-port remap)');
    }
  }
  if (portA == null) {
    warnings.add('link $nameA-$nameB: ${link['aIf']} not usable on $nameA');
    return null;
  }
  if (portB == null) {
    warnings.add('link $nameA-$nameB: ${link['bIf']} not usable on $nameB');
    return null;
  }
  var out = block;
  out = _replaceFirst(
    out,
    RegExp(r'<FROM>[^<]*</FROM>'),
    '<FROM>save-ref-id:${refs[nameA]}</FROM>',
  );
  out = _replaceFirst(
    out,
    RegExp(r'<PORT>[^<]*</PORT>'),
    '<PORT>${_esc(portA)}</PORT>',
  );
  out = _replaceFirst(
    out,
    RegExp(r'<TO>[^<]*</TO>'),
    '<TO>save-ref-id:${refs[nameB]}</TO>',
  );
  // Second <PORT> belongs to the TO side.
  final toPort = RegExp(r'<TO>[^<]*</TO>\s*<PORT>[^<]*</PORT>').firstMatch(out);
  if (toPort != null) {
    final segment = toPort.group(0)!;
    final fixed = segment.replaceFirst(
      RegExp(r'<PORT>[^<]*</PORT>'),
      '<PORT>${_esc(portB)}</PORT>',
    );
    out = out.substring(0, toPort.start) +
        fixed +
        out.substring(toPort.end);
  }
  out = out.replaceAllMapped(
    RegExp(r'<([A-Z_]*MEM_ADDR)>[^<]*</\1>'),
    (m) => '<${m.group(1)}>0</${m.group(1)}>',
  );
  // A serial link records which end is DCE. That is only knowable from the
  // `clock rate` the plan's config gave one of the two ports; without it the
  // stale pointer to a foreign device must go, not stay.
  final dceSide = dcePorts.containsKey((nameA, portA))
      ? 'a'
      : (dcePorts.containsKey((nameB, portB)) ? 'b' : '');
  if (dceSide.isNotEmpty) {
    final (dceName, dcePort) =
        dceSide == 'a' ? (nameA, portA) : (nameB, portB);
    out = _replaceFirst(
      out,
      RegExp(r'<DCEDEV>[^<]*</DCEDEV>'),
      '<DCEDEV>save-ref-id:${refs[dceName]}</DCEDEV>',
    );
    out = _replaceFirst(
      out,
      RegExp(r'<DCEPORT>[^<]*</DCEPORT>'),
      '<DCEPORT>${_esc(dcePort)}</DCEPORT>',
    );
  } else if (out.contains('<DCEDEV>')) {
    out = out.replaceAllMapped(
      RegExp(r'<DCEDEV>[^<]*</DCEDEV>\s*'),
      (_) => '',
    );
    out = out.replaceAllMapped(
      RegExp(r'<DCEPORT>[^<]*</DCEPORT>\s*'),
      (_) => '',
    );
    warnings.add('link $nameA-$nameB: the plan gave neither end a clock rate, '
        'so the serial link has no DCE side');
  }
  // The template's cable kind may differ from the one the plan asked for (a
  // crossover on the straight-through block is the same structure).
  final (_, wantedCable) =
      _linkMediums[requestedCable.trim().toLowerCase()] ?? ('', '');
  if (wantedCable.isNotEmpty &&
      template.cable.isNotEmpty &&
      template.cable != wantedCable) {
    final cableSegment =
        RegExp(r'<CABLE>.*?</CABLE>', dotAll: true).firstMatch(out);
    if (cableSegment != null) {
      final fixed = cableSegment.group(0)!.replaceFirst(
            RegExp(r'<TYPE>[^<]*</TYPE>'),
            '<TYPE>$wantedCable</TYPE>',
          );
      out = out.substring(0, cableSegment.start) +
          fixed +
          out.substring(cableSegment.end);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Plan sections
// ---------------------------------------------------------------------------

class _PlanSections {
  final List<Map<String, dynamic>> nodes = [];
  final List<Map<String, dynamic>> links = [];
  final Map<String, String> configs = {};
  final Map<String, Map<String, dynamic>> pcs = {};
  final Map<String, dynamic> servers = {};
}

_PlanSections _planSections(Map<String, dynamic> plan) {
  final sections = _PlanSections();
  final steps = (plan['steps'] as List?) ?? const <dynamic>[];
  for (final step in steps) {
    if (step is! Map) continue;
    switch ('${step['action'] ?? ''}') {
      case 'create_nodes':
        for (final node in (step['nodes'] as List?) ?? const <dynamic>[]) {
          if (node is Map) {
            sections.nodes.add(Map<String, dynamic>.from(node));
          }
        }
      case 'create_links':
        for (final link in (step['links'] as List?) ?? const <dynamic>[]) {
          if (link is Map) {
            sections.links.add(Map<String, dynamic>.from(link));
          }
        }
      case 'paste_cli':
        ((step['configs'] as Map?) ?? const {}).forEach((key, value) {
          sections.configs['$key'] = '$value';
        });
      case 'config_pcs':
        ((step['pcs'] as Map?) ?? const {}).forEach((key, value) {
          if (value is Map) {
            sections.pcs['$key'] = Map<String, dynamic>.from(value);
          }
        });
      case 'config_servers':
        ((step['servers'] as Map?) ?? const {}).forEach((key, value) {
          sections.servers['$key'] = value;
        });
    }
  }
  return sections;
}

// ---------------------------------------------------------------------------
// Services tab (DHCP / DNS / HTTP / AAA / FTP / email / syslog / NTP)
// ---------------------------------------------------------------------------

String _flag(bool on) => on ? '1' : '0';

String _serverType(Object? value) {
  final text = '${value ?? ''}'.trim().toUpperCase();
  return text.contains('RADIUS') ? 'RADIUS' : 'TACACS';
}

String _indexed(String tag, int index, String value) =>
    '<$tag$index>${_svc(value)}</$tag$index>';

String _svc(String text) => _esc(text);

/// Network address and last usable address for a pool start + mask.
(String, String) _netAndLastIp(String ip, String mask) {
  final parts = ip.split('.').map((p) => int.tryParse(p)).toList();
  final bits = mask.split('.').map((p) => int.tryParse(p)).toList();
  if (parts.length != 4 || bits.length != 4) return (ip, ip);
  if (parts.any((p) => p == null) || bits.any((p) => p == null)) {
    return (ip, ip);
  }
  final net = [
    for (var i = 0; i < 4; i++) parts[i]! & bits[i]!,
  ];
  final last = [
    for (var i = 0; i < 4; i++) net[i] + (255 - bits[i]!),
  ];
  last[3] = last[3] - 1 >= net[3] ? last[3] - 1 : net[3];
  return (net.join('.'), last.join('.'));
}

Map<String, String> _serviceElements(
  Map<String, dynamic> services,
  String portName,
  Map<String, dynamic> report,
  List<String> notes,
) {
  Map<String, dynamic> planFor(String role) {
    final value = services[role];
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  final out = <String, String>{};

  // --- HTTP / HTTPS -------------------------------------------------------
  // Every panel is rewritten even when the plan does not ask for it, so a
  // template's leftover state can never ship inside a generated file.
  final http = planFor('http');
  out['HTTP_SERVER'] = '<HTTP_SERVER><ENABLED>${_flag(http.isNotEmpty)}'
      '</ENABLED><USERNAME>${_svc('${http['username'] ?? ''}')}</USERNAME>'
      '<PASSWORD>${_svc('${http['password'] ?? ''}')}</PASSWORD>'
      '</HTTP_SERVER>';
  out['HTTPS_SERVER'] = '<HTTPS_SERVER><HTTPSENABLED>'
      '${_flag(http['https'] == true || '${http['https'] ?? ''}' == 'true')}'
      '</HTTPSENABLED></HTTPS_SERVER>';
  if (http.isNotEmpty) {
    report['http'] = {
      'on': true,
      'https': http['https'] == true || '${http['https'] ?? ''}' == 'true',
    };
  }

  // --- DNS ----------------------------------------------------------------
  final rows = <String>[];
  for (final record in (planFor('dns')['records'] as List?) ??
      const <dynamic>[]) {
    if (record is! Map) continue;
    final name = '${record['name'] ?? ''}'.trim();
    final address = '${record['address'] ?? ''}'.trim();
    if (name.isEmpty || address.isEmpty) continue;
    rows.add('<RESOURCE-RECORD><TYPE>A-REC</TYPE><NAME>${_svc(name)}'
        '</NAME><TTL>86400</TTL><IPADDRESS>${_svc(address)}'
        '</IPADDRESS></RESOURCE-RECORD>');
  }
  out['DNS_SERVER'] = '<DNS_SERVER><ENABLED>${_flag(rows.isNotEmpty)}'
      '</ENABLED><NAMESERVER-DATABASE>${rows.join()}'
      '</NAMESERVER-DATABASE></DNS_SERVER>';
  if (rows.isNotEmpty) {
    report['dns'] = {'records': rows.length};
  }

  // --- DHCP ---------------------------------------------------------------
  final dhcp = planFor('dhcp');
  final poolsRaw = dhcp['pools'] is List
      ? (dhcp['pools'] as List)
      : (('${dhcp['startIp'] ?? ''}').isNotEmpty ? [dhcp] : const <dynamic>[]);
  final poolRows = <String>[];
  final seen = <String>{};
  var poolIndex = 0;
  for (final pool in poolsRaw) {
    if (pool is! Map) continue;
    final start = '${pool['startIp'] ?? ''}';
    final mask = '${pool['mask'] ?? '255.255.255.0'}';
    if (start.isEmpty) continue;
    final (network, end) = _netAndLastIp(start, mask);
    var poolName = '${pool['poolName'] ?? ''}'.trim();
    if (poolName.isEmpty) poolName = 'pool${poolIndex + 1}';
    if (seen.contains(poolName)) poolName = '${poolName}_${poolIndex + 1}';
    seen.add(poolName);
    poolRows.add('<POOL><NAME>${_svc(poolName)}</NAME><NETWORK>'
        '${_svc(network)}</NETWORK><MASK>${_svc(mask)}</MASK>'
        '<DEFAULT_ROUTER>${_svc('${pool['gateway'] ?? '0.0.0.0'}')}'
        '</DEFAULT_ROUTER><TFTP_ADDRESS>0.0.0.0</TFTP_ADDRESS>'
        '<START_IP>${_svc(start)}</START_IP><END_IP>${_svc(end)}</END_IP>'
        '<DNS_SERVER>${_svc('${pool['dnsServer'] ?? '0.0.0.0'}')}'
        '</DNS_SERVER><MAX_USERS>${_svc('${pool['maxUsers'] ?? '100'}')}'
        '</MAX_USERS><DOMAIN_NAME/><DHCP_POOL_LEASES/>'
        '<LEASE_TIME>86400000</LEASE_TIME>'
        '<WLC_ADDRESS>0.0.0.0</WLC_ADDRESS></POOL>');
    poolIndex++;
  }
  out['DHCP_SERVERS'] = '<DHCP_SERVERS><ASSOCIATED_PORTS><ASSOCIATED_PORT>'
      '<NAME>${_svc(portName)}</NAME><DHCP_SERVER><ENABLED>'
      '${_flag(poolRows.isNotEmpty)}</ENABLED><POOLS>${poolRows.join()}'
      '</POOLS><DHCP_RESERVATIONS/><AUTOCONFIG/></DHCP_SERVER>'
      '</ASSOCIATED_PORT></ASSOCIATED_PORTS></DHCP_SERVERS>';
  if (poolRows.isNotEmpty) {
    report['dhcp'] = {'pools': poolRows.length};
  }

  // --- AAA (the PT ACS server: TACACS+/RADIUS users and clients) ----------
  final aaa = planFor('aaa');
  final users = [
    for (final u in (aaa['users'] as List?) ?? const <dynamic>[])
      if (u is Map && '${u['username'] ?? ''}'.isNotEmpty)
        Map<String, dynamic>.from(u),
  ];
  final clients = [
    for (final c in (aaa['clients'] as List?) ?? const <dynamic>[])
      if (c is Map &&
          ('${c['hostIp'] ?? ''}'.isNotEmpty || '${c['ip'] ?? ''}'.isNotEmpty))
        Map<String, dynamic>.from(c),
  ];
  for (final c in clients) {
    if ('${c['hostIp'] ?? ''}'.isEmpty) c['hostIp'] = c['ip'];
  }
  final userRows = [
    for (final u in users)
      '<USER><NAME>${_svc('${u['username']}')}</NAME><PASSWORD>'
      '${_svc('${u['password'] ?? ''}')}</PASSWORD><DESCRIPTION>'
      '${_svc('${u['description'] ?? ''}')}</DESCRIPTION></USER>',
  ];
  final clientRows = [
    for (final c in clients)
      '<CLIENT><HOST_IP>${_svc('${c['hostIp']}')}</HOST_IP><KEY>'
      '${_svc('${c['key'] ?? ''}')}</KEY><DESCRIPTION>'
      '${_svc('${c['description'] ?? c['name'] ?? ''}')}</DESCRIPTION>'
      '<SERVER_TYPE>${_svc(_serverType(c['serverType'] ?? c['type']))}'
      '</SERVER_TYPE></CLIENT>',
  ];
  // Packet Tracer leaves AAA *Off* and its tab empty unless the server has
  // at least one account and one client.
  final aaaOn = aaa.isNotEmpty &&
      aaa['enabled'] != false &&
      (userRows.isNotEmpty || clientRows.isNotEmpty);
  var authPort = '${aaa['authPort'] ?? ''}'.trim();
  if (!RegExp(r'^\d+$').hasMatch(authPort)) authPort = '1645';
  out['ACS_SERVER'] = '<ACS_SERVER><ENABLED>${_flag(aaaOn)}</ENABLED><USERS>'
      '${userRows.join()}</USERS><ACS_CLIENTS>${clientRows.join()}'
      '</ACS_CLIENTS><RADIUS_SETTINGS><AUTH_PORT>${_svc(authPort)}'
      '</AUTH_PORT></RADIUS_SETTINGS></ACS_SERVER>';
  if (aaa.isNotEmpty) {
    report['aaa'] = {
      'on': aaaOn,
      'users': userRows.length,
      'clients': clientRows.length,
      'serverType': _serverType(
        clients.isNotEmpty ? clients.first['serverType'] : '',
      ),
      'authPort': authPort,
    };
    if (users.isEmpty) {
      notes.add('AAA is enabled on the server but the plan names no user, so '
          'no login can succeed until one is added');
    }
    if (clients.isEmpty) {
      notes.add('AAA is enabled but the plan names no client router, so the '
          'router IP and shared key are missing from the server');
    }
  }

  // --- DHCPv6 -------------------------------------------------------------
  final v6 = planFor('dhcpv6');
  final pools6 = [
    for (final p in (v6['pools'] as List?) ?? const <dynamic>[])
      if (p is Map) Map<String, dynamic>.from(p),
  ];
  final names6 = <String>[];
  final pool6Rows = <String>[];
  for (var index = 0; index < pools6.length; index++) {
    final pool = pools6[index];
    final prefix = '${pool['prefix'] ?? ''}'.trim();
    if (prefix.isEmpty) continue;
    var name = '${pool['poolName'] ?? ''}'.trim();
    if (name.isEmpty) name = 'pool${index + 1}';
    if (names6.contains(name)) name = '${name}_${index + 1}';
    names6.add(name);
    final length = '${pool['prefixLength'] ?? ''}'.trim();
    final len = length.isEmpty ? '64' : length;
    final cidr = '$prefix/$len';
    pool6Rows.add('<DHCPV6_POOL><POOL_NAME>${_svc(name)}</POOL_NAME>'
        '<DNS_SERVER>${_svc('${pool['dnsServer'] ?? ''}')}</DNS_SERVER>'
        '<DOMAIN_NAME>${_svc('${pool['domainName'] ?? ''}')}</DOMAIN_NAME>'
        '<PORT_NAME>${_svc(portName)}</PORT_NAME><STATIC_PDS/>'
        '<ADDRESS_PREFIXES><ADDRESS_PREFIX><PREFIX_ID>${_svc(cidr)}'
        '</PREFIX_ID><DHCPV6_PREFIX_DELEGATION><PREFIX_ID>${_svc(cidr)}'
        '</PREFIX_ID><PREFIX_POOL_NAME>${_svc(name)}</PREFIX_POOL_NAME>'
        '<VALID_LIFETIME>2592000</VALID_LIFETIME>'
        '<PREFERRED_LIFETIME>604800</PREFERRED_LIFETIME>'
        '<PREFIX_LENGTH>${_svc(len)}</PREFIX_LENGTH><PREFIX>${_svc(prefix)}'
        '</PREFIX></DHCPV6_PREFIX_DELEGATION></ADDRESS_PREFIX>'
        '</ADDRESS_PREFIXES></DHCPV6_POOL>');
  }
  var port6 = '';
  if (pool6Rows.isNotEmpty) {
    port6 = '<ASSOCIATED_PORTS><ASSOCIATED_PORT><PORT_NAME>'
        '${_svc(portName)}</PORT_NAME><DHCPV6_SERVER>'
        '<DHCPV6_SERVER_PORT_DATA><ENABLED>1</ENABLED>'
        '<RAPID_COMMIT>0</RAPID_COMMIT><HINT>0</HINT><POOL_NAME>'
        '${_svc(names6.first)}</POOL_NAME>'
        '<INITIAL_ADVERTISE_TIME></INITIAL_ADVERTISE_TIME>'
        '<LAST_ADVERTISE_TIME></LAST_ADVERTISE_TIME>'
        '<ADVERTISE_MSG_COUNT>0</ADVERTISE_MSG_COUNT>'
        '<INITIAL_REPLY_TIME></INITIAL_REPLY_TIME>'
        '<LAST_REPLY_TIME></LAST_REPLY_TIME>'
        '<REPLY_MSG_COUNT>0</REPLY_MSG_COUNT>'
        '</DHCPV6_SERVER_PORT_DATA><BINDING_TABLE/></DHCPV6_SERVER>'
        '</ASSOCIATED_PORT></ASSOCIATED_PORTS>';
  }
  out['DHCPV6_SERVER_LIST'] = '<DHCPV6_SERVER_LIST>$port6<DHCPv6_POOLS>'
      '${pool6Rows.join()}</DHCPv6_POOLS><IPv6_LOCAL_POOLS/>'
      '</DHCPV6_SERVER_LIST>';
  if (pool6Rows.isNotEmpty) {
    report['dhcpv6'] = {'pools': pool6Rows.length};
  }

  // --- FTP / email --------------------------------------------------------
  final ftp = planFor('ftp');
  final accounts = [
    for (final a in (ftp['users'] as List?) ?? const <dynamic>[])
      if (a is Map && '${a['username'] ?? ''}'.isNotEmpty)
        Map<String, dynamic>.from(a),
  ];
  final ftpRows = [
    for (final a in accounts)
      '<ACCOUNT><USERNAME>${_svc('${a['username']}')}</USERNAME><PASSWORD>'
      '${_svc('${a['password'] ?? ''}')}</PASSWORD><PERMISSIONS>'
      '${_svc('${a['permissions'] ?? 'RWDNL'}')}</PERMISSIONS></ACCOUNT>',
  ];
  out['FTP_SERVER'] = '<FTP_SERVER><ENABLED>${_flag(ftp.isNotEmpty)}'
      '</ENABLED><USER_ACCOUNT_MNGR>${ftpRows.join()}'
      '</USER_ACCOUNT_MNGR></FTP_SERVER>';
  if (ftp.isNotEmpty) {
    report['ftp'] = {'on': true, 'accounts': ftpRows.length};
  }

  // The mail panel stores each mailbox as indexed elements (USER0,
  // PASSWORD0, NO_OF_MAILS0) and NO_OF_USERS has to match the count.
  final email = planFor('email');
  final mailUsers = [
    for (final u in (email['users'] as List?) ?? const <dynamic>[])
      if (u is Map && '${u['username'] ?? ''}'.isNotEmpty)
        Map<String, dynamic>.from(u),
  ];
  final mailboxes = StringBuffer();
  for (var index = 0; index < mailUsers.length; index++) {
    final user = mailUsers[index];
    mailboxes
      ..write(_indexed('USER', index, '${user['username']}'))
      ..write(_indexed('PASSWORD', index, '${user['password'] ?? ''}'))
      ..write(_indexed('NO_OF_MAILS', index, '0'));
  }
  final emailOn = email.isNotEmpty && email['enabled'] != false;
  out['EMAIL_SERVER'] = '<EMAIL_SERVER><SMTP_ENABLED>${_flag(emailOn)}'
      '</SMTP_ENABLED><SMTP_DOMAIN>${_svc('${email['domain'] ?? ''}')}'
      '</SMTP_DOMAIN><POP3_ENABLED>${_flag(emailOn)}</POP3_ENABLED>'
      '<FORWARD_MAIL>${_flag(email['forward'] == true)}</FORWARD_MAIL>'
      '<NO_OF_USERS>${_svc('${mailUsers.length}')}</NO_OF_USERS>'
      '$mailboxes</EMAIL_SERVER>';
  if (email.isNotEmpty) {
    report['email'] = {
      'on': emailOn,
      'domain': '${email['domain'] ?? ''}',
      'users': mailUsers.length,
    };
  }

  // --- IoT registration server and VM manager -----------------------------
  final iot = planFor('iot');
  final iotUsers = [
    for (final u in (iot['users'] as List?) ?? const <dynamic>[])
      if (u is Map && '${u['username'] ?? ''}'.isNotEmpty)
        Map<String, dynamic>.from(u),
  ];
  final iotRows = [
    for (final u in iotUsers)
      '<USER><NAME>${_svc('${u['username']}')}</NAME><PASSWORD>'
      '${_svc('${u['password'] ?? ''}')}</PASSWORD><DEVICES/>'
      '<IOE_CONDITIONS/><IOE_RULES/></USER>',
  ];
  out['IOE_USER_MANAGER'] = '<IOE_USER_MANAGER><USERS>${iotRows.join()}'
      '</USERS></IOE_USER_MANAGER>';
  if (iot.isNotEmpty) {
    final registration = iot['registration'] != false;
    out['REGISTRATION_SEVER'] = '<REGISTRATION_SEVER>'
        '${registration ? 'true' : 'false'}</REGISTRATION_SEVER>';
    report['iot'] = {'users': iotRows.length, 'registration': registration};
  }
  final vm = planFor('vm');
  final vms = [
    for (final v in (vm['vms'] as List?) ?? const <dynamic>[])
      if (v is Map && '${v['id'] ?? ''}'.isNotEmpty)
        Map<String, dynamic>.from(v),
  ];
  final vmRows = [
    for (final v in vms)
      '<VM><VM_ID>${_svc('${v['id']}')}</VM_ID><VM_PATH>'
      '${_svc('${v['path'] ?? v['id']}')}</VM_PATH><VM_STATUS>'
      '${_svc('${v['status'] ?? '1'}')}</VM_STATUS></VM>',
  ];
  out['IOX_VM_MANAGER'] = '<IOX_VM_MANAGER><VMS>${vmRows.join()}</VMS>'
      '</IOX_VM_MANAGER>';
  if (vm.isNotEmpty) {
    report['vm'] = {'vms': vmRows.length};
  }

  // --- RADIUS EAP (wireless client authentication) ------------------------
  final eap = planFor('radiusEap');
  final methods = [
    for (final m in (eap['methods'] as List?) ?? const <dynamic>[])
      if ('$m'.trim().isNotEmpty) '$m'.trim().toUpperCase(),
  ];
  if (methods.isNotEmpty) {
    final eapRows = [
      for (final m in methods) '<EAP_METHOD><NAME>${_svc(m)}</NAME></EAP_METHOD>',
    ];
    out['EAP_METHODS'] = '<EAP_METHODS>${eapRows.join()}</EAP_METHODS>';
    report['radiusEap'] = {'methods': methods};
  }

  // --- one-switch services ------------------------------------------------
  for (final entry in [
    ('syslog', 'SYSLOG_SERVER'),
    ('ntp', 'NTP_SERVER'),
    ('tftp', 'TFTP_SERVER'),
  ]) {
    final (role, tag) = entry;
    final plan = planFor(role);
    final on = plan.isNotEmpty && plan['enabled'] != false;
    if (tag == 'NTP_SERVER') {
      // The panel's authentication fields are real state; the server list is
      // a live NTP client list and is left empty on purpose.
      out[tag] = '<NTP_SERVER><ENABLED>${_flag(on)}</ENABLED>'
          '<ENABLED_SERVER_AUTHENTICATE>'
          '${_flag(plan['authenticate'] == true)}'
          '</ENABLED_SERVER_AUTHENTICATE><KEY>${_svc('${plan['key'] ?? '0'}')}'
          '</KEY><MD5PASSWORD>${_svc('${plan['md5Password'] ?? ''}')}'
          '</MD5PASSWORD><SERVER_IP_LIST/></NTP_SERVER>';
    } else {
      out[tag] = '<$tag><ENABLED>${_flag(on)}</ENABLED></$tag>';
    }
    if (on) report[role] = {'on': true};
  }

  // --- SNMP ---------------------------------------------------------------
  final snmp = planFor('snmp');
  final snmpOn = snmp.isNotEmpty && snmp['enabled'] != false;
  out['SNMP_MANAGER'] = '<SNMP_MANAGER><AGENT_IP>'
      '${_svc('${snmp['agentIp'] ?? '0.0.0.0'}')}</AGENT_IP><AGENT_PORT>'
      '${_svc('${snmp['agentPort'] ?? '161'}')}</AGENT_PORT><MANAGER_PORT>'
      '${_svc('${snmp['managerPort'] ?? '161'}')}</MANAGER_PORT>'
      '<READ_COMMUNITY>${_svc(snmpOn ? '${snmp['readCommunity'] ?? ''}' : '')}'
      '</READ_COMMUNITY><WRITE_COMMUNITY>'
      '${_svc(snmpOn ? '${snmp['writeCommunity'] ?? ''}' : '')}'
      '</WRITE_COMMUNITY><SNMP_VERSION>${_svc('${snmp['version'] ?? '1'}')}'
      '</SNMP_VERSION></SNMP_MANAGER>';
  if (snmpOn) {
    report['snmp'] = {
      'on': true,
      'readCommunity': '${snmp['readCommunity'] ?? ''}',
    };
  }
  return out;
}

/// Wireless (SSID / WEP / WPA-PSK) - schema verified against real saves by
/// the sidecar: every AP / home-router ENGINE carries a WIRELESS_SERVER >
/// WIRELESS_COMMON block, and wireless endpoints carry the mirrored
/// WIRELESS_PROFILE.
Map<String, String> _wirelessElements(
  Map<String, dynamic> services,
  Map<String, dynamic> report,
  List<String> notes,
) {
  final wl = services['wireless'];
  if (wl is! Map) return {};
  final ssid = '${wl['ssid'] ?? ''}'.trim();
  if (ssid.isEmpty) return {};

  String common(String sub) => '<WIRELESS_COMMON>\r\n'
      '       <NETWORK_MODE>7</NETWORK_MODE>\r\n'
      '       <SSID>${_esc(ssid)}</SSID>\r\n'
      '       <ENCRYPT_TYPE>$sub</ENCRYPT_TYPE>\r\n'
      '       <AUTHEN_TYPE>$sub</AUTHEN_TYPE>\r\n'
      '       <RADIO_BAND>0</RADIO_BAND>\r\n'
      '       <WIDE_CHANNEL>0</WIDE_CHANNEL>\r\n'
      '       <STANDARD_CHANNEL>0</STANDARD_CHANNEL>\r\n'
      '       <STANDARD_CHANNEL5G>112</STANDARD_CHANNEL5G>\r\n'
      '      </WIRELESS_COMMON>\r\n';

  var code = '0';
  var wep = '${wl['wep'] ?? ''}';
  if ('${wl['wpa2'] ?? ''}'.toLowerCase() == '1' ||
      '${wl['wpa2'] ?? ''}'.toLowerCase() == 'true' ||
      '${wl['psk'] ?? ''}'.isNotEmpty) {
    // PT's WPA2-PSK pairing is not reproducible from harvested saves; the
    // SSID is written and the pairing reported as manual-step.
    report['wireless'] = {
      'ssid': ssid,
      'wpa2': true,
      'verification': 'manual_step',
    };
    notes.add('wireless: WPA2-PSK must be confirmed in the device GUI; the '
        'SSID is set');
  } else if ('${wl['wep'] ?? ''}'.trim().isNotEmpty) {
    code = '1';
    wep = '${wl['wep']}';
    report['wireless'] = {
      'ssid': ssid,
      'wep': true,
      'verification': 'state_only',
    };
  } else {
    report['wireless'] = {
      'ssid': ssid,
      'open': true,
      'verification': 'state_only',
    };
  }

  var apBody = '<WIRELESS_SERVER>\r\n      ${common(code)}'
      '      <SSID_BROADCAST_ENABLED>'
      '${(wl['broadcast'] ?? true) == false ? '0' : '1'}'
      '</SSID_BROADCAST_ENABLED>\r\n'
      '      <MAC_FILTER_ENABLED>0</MAC_FILTER_ENABLED>\r\n'
      '      <ALLOW_ACCESS>0</ALLOW_ACCESS>\r\n'
      '     </WIRELESS_SERVER>\r\n';
  if (wep.isNotEmpty) {
    apBody += '      <WEP_KEY>${_esc(wep)}</WEP_KEY>\r\n';
  }

  final clientBody = '<WIRELESS_CLIENT>\r\n         ${common(code)}'
      '         <PROFILES>\r\n'
      '          <WIRELESS_PROFILE>\r\n'
      '           <NAME>${_esc(ssid)}</NAME>\r\n'
      '           <SSID>${_esc(ssid)}</SSID>\r\n'
      '           <NETWORK_TYPE>7</NETWORK_TYPE>\r\n'
      '           <RADIO_BAND>0</RADIO_BAND>\r\n'
      '           <AUTHEN_TYPE>$code</AUTHEN_TYPE>\r\n'
      '           <ENCRYPT_TYPE>$code</ENCRYPT_TYPE>\r\n'
      '           <WEP_KEY>${_esc(wep)}</WEP_KEY>\r\n'
      '           <WPA_EAP_USERID></WPA_EAP_USERID>\r\n'
      '           <WPA_EAP_PASSWORD></WPA_EAP_PASSWORD>\r\n'
      '           <DHCP_ENABLED>1</DHCP_ENABLED>\r\n'
      '           <DHCPV6_ENABLED>1</DHCPV6_ENABLED>\r\n'
      '           <IP_ADDRESS/>\r\n'
      '          </WIRELESS_PROFILE>\r\n'
      '         </PROFILES>\r\n'
      '        </WIRELESS_CLIENT>\r\n';
  return {'WIRELESS_SERVER': apBody, 'WIRELESS_CLIENT': clientBody};
}

/// Span of the first `<TAG>...</TAG>`, or of a self-closing `<TAG/>`.
(int, int)? _elementSpan(String block, String tag) {
  final match = RegExp('<${RegExp.escape(tag)}(?:\\s[^>]*)?>').firstMatch(block);
  if (match == null) return null;
  if (match.group(0)!.endsWith('/>')) return (match.start, match.end);
  final close = block.indexOf('</$tag>', match.end);
  if (close < 0) return null;
  return (match.start, close + tag.length + 3);
}

(String, List<String>, Map<String, dynamic>) _applyServices(
  String block,
  PktTemplateDevice variant,
  Map<String, dynamic> services,
) {
  final report = <String, dynamic>{};
  final notes = <String>[];
  final wireless = _wirelessElements(services, report, notes);
  var span = _elementSpan(block, 'ENGINE');
  if (span == null) {
    // Wireless lives outside the ENGINE for some devices (the AP's own GUI
    // schema), so still apply the wireless blocks before bailing.
    if (wireless.isNotEmpty) {
      var out = block;
      wireless.forEach((tag, body) {
        final tagSpan = _elementSpan(out, tag);
        if (tagSpan != null) {
          out = out.substring(0, tagSpan.$1) + body + out.substring(tagSpan.$2);
        }
      });
      return (out, notes, report);
    }
    return (block, notes, report);
  }
  var head = block.substring(0, span.$1);
  var engine = block.substring(span.$1, span.$2);
  var tail = block.substring(span.$2);
  if (wireless.isNotEmpty) {
    // Wireless spans the whole device, not just the ENGINE slice.
    var out = block;
    wireless.forEach((tag, body) {
      final whole = _elementSpan(out, tag);
      if (whole != null) {
        out = out.substring(0, whole.$1) + body + out.substring(whole.$2);
      }
    });
    span = _elementSpan(out, 'ENGINE');
    if (span == null) return (out, notes, report);
    head = out.substring(0, span.$1);
    engine = out.substring(span.$1, span.$2);
    tail = out.substring(span.$2);
  }
  final hasAnyService =
      _serviceTags.any((tag) => engine.contains('<$tag>'));
  if (!hasAnyService) {
    return (head + engine + tail, notes, report);
  }
  var portName = '';
  for (final port in variant.ports) {
    if (_ethernetFamilies.contains(port.family)) {
      portName = port.name;
      break;
    }
  }
  _serviceElements(services, portName, report, notes).forEach((tag, body) {
    final tagSpan = _elementSpan(engine, tag);
    if (tagSpan != null) {
      engine = engine.substring(0, tagSpan.$1) +
          body +
          engine.substring(tagSpan.$2);
      return;
    }
    // The template came from a save where this service was never configured,
    // so there is no element to rewrite. Insert it before the closing
    // </ENGINE> instead - skipping it left the service silently off.
    final close = engine.lastIndexOf('</ENGINE>');
    if (close < 0) {
      notes.add('$tag: the device template has nowhere to put this service, '
          'so it was left unset');
      return;
    }
    engine = engine.substring(0, close) + body + engine.substring(close);
  });
  return (head + engine + tail, notes, report);
}

// ---------------------------------------------------------------------------
// Physical workspace
// ---------------------------------------------------------------------------

String _findFirstText(xml.XmlElement scope, String name) {
  final element = _findFirst(scope, name);
  return element?.innerText.trim() ?? '';
}

/// First descendant element with [name] - ET's `find('.//NAME')` semantics.
xml.XmlElement? _findFirst(xml.XmlElement scope, String name) {
  for (final e in scope.descendantElements) {
    if (e.name.local == name) return e;
  }
  return null;
}

/// The text of a direct-child element - ET's `findtext("TYPE")` semantics.
/// The physical workspace nests NODE inside NODE, so a descendant search
/// would read a child leaf's fields as its ancestor's.
String _childText(xml.XmlElement scope, String name) =>
    scope.getElement(name)?.innerText.trim() ?? '';

String _setPhysicalIdentity({
  required String block,
  required String name,
  required String physicalPath,
  required String parentPath,
  required String containerId,
  required int x,
  required int y,
  required String identity,
}) {
  var out = _setTag(block, 'PHYSICAL', physicalPath);
  final cpur =
      RegExp(r'<PHYSICAL_CPUR>.*?</PHYSICAL_CPUR>', dotAll: true)
          .firstMatch(out);
  if (cpur == null) {
    throw PktBuildFailure('$name: device template has no PHYSICAL_CPUR data');
  }
  var chunk = cpur.group(0)!;
  // Most models keep the immediate container in its own field, but many
  // templates have no CONTAINER_ID at all and write the whole ancestry into
  // PARENT_PATH instead. Adding a field a model never carries would be
  // guessing at its schema, so the joined path is written in that case and
  // the container is the path's last element.
  final fields = _hasTag(chunk, 'CONTAINER_ID')
      ? <String, String>{
          'PARENT_PATH': parentPath,
          'CONTAINER_ID': containerId,
          'X': '$x',
          'Y': '$y',
        }
      : <String, String>{
          'PARENT_PATH': [parentPath, containerId]
              .where((part) => part.isNotEmpty)
              .join(','),
          'X': '$x',
          'Y': '$y',
        };
  fields.forEach((tag, value) {
    if (!_hasTag(chunk, tag)) {
      throw PktBuildFailure('$name: physical workspace is missing $tag');
    }
    chunk = _setTag(chunk, tag, value);
  });
  // This field is present in most PT-authored devices but absent in some
  // models (for example Server-PT). Preserve that model-specific schema.
  if (_hasTag(chunk, 'ORIGINAL_DEVICE_UUID')) {
    chunk = _setTag(chunk, 'ORIGINAL_DEVICE_UUID', identity);
  }
  return out.substring(0, cpur.start) +
      chunk +
      out.substring(cpur.end);
}

/// Recreate physical device leaves so the workspace matches the output.
///
/// Packet Tracer stores physical devices twice: a TYPE=6 leaf in the global
/// PHYSICALWORKSPACE tree, and a comma-separated ancestry path in each
/// DEVICE/WORKSPACE/PHYSICAL. Reusing device templates without rebuilding
/// both sides leaves stale, duplicated, or foreign UUIDs and Packet Tracer
/// rejects the save as corrupted Physical Workspace data.
(String, List<String>) _rebuildPhysicalWorkspace({
  required String skeleton,
  required List<String> deviceBlocks,
  required List<Map<String, dynamic>> deviceReport,
  required String project,
  required List<String> notes,
}) {
  final match = RegExp(
    r'<PHYSICALWORKSPACE(?:\s[^>]*)?>.*?</PHYSICALWORKSPACE>',
    dotAll: true,
  ).firstMatch(skeleton);
  final hasDevicePaths = deviceBlocks.any((b) => _hasTag(b, 'PHYSICAL'));
  if (match == null) {
    if (hasDevicePaths) {
      throw const PktBuildFailure(
        'the device templates contain Physical Workspace paths but the '
        'skeleton has no PHYSICALWORKSPACE',
      );
    }
    return (skeleton, deviceBlocks);
  }
  if (deviceBlocks.length != deviceReport.length) {
    throw const PktBuildFailure(
      'device report does not match the generated devices',
    );
  }

  xml.XmlDocument workspace;
  try {
    workspace = xml.XmlDocument.parse(match.group(0)!);
  } catch (e) {
    throw PktBuildFailure('invalid PHYSICALWORKSPACE template: $e');
  }
  final root = workspace.rootElement;

  // Index real container ancestry and keep a PT-authored type-6 example for
  // each likely destination (rack for network equipment, office for hosts).
  final containers = <Map<String, dynamic>>[];
  final prototypes = <String, xml.XmlElement>{};

  void walk(xml.XmlElement node, List<String> ancestorPath) {
    final kind = _childText(node, 'TYPE');
    final nodeUuid = _childText(node, 'UUID_STR');
    final path = [
      ...ancestorPath,
      if (nodeUuid.isNotEmpty) nodeUuid,
    ];
    final children = node.getElement('CHILDREN');
    if (kind == '6') {
      if (ancestorPath.isNotEmpty) {
        prototypes.putIfAbsent(ancestorPath.last, () => node);
      }
      return;
    }
    if (['0', '1', '2', '3', '4'].contains(kind) && children != null) {
      containers.add({
        'node': node,
        'type': kind,
        'uuid': nodeUuid,
        'path': path,
      });
    }
    if (children != null) {
      for (final child in children.childElements) {
        if (child.name.local == 'NODE') walk(child, path);
      }
    }
  }

  for (final node in root.childElements) {
    if (node.name.local == 'NODE') walk(node, <String>[]);
  }

  if (containers.isEmpty) {
    throw const PktBuildFailure(
      'PHYSICALWORKSPACE has no usable device containers',
    );
  }

  // Keep the first PT-authored leaf of each direct container as a cloning
  // prototype, then clear every old device leaf (the network is replaced).
  void clearDeviceLeaves(xml.XmlElement node) {
    final children = node.getElement('CHILDREN');
    if (children == null) return;
      final doomed = <xml.XmlNode>[];
      for (final child in children.childElements) {
        if (child.name.local != 'NODE') continue;
        if (_childText(child, 'TYPE') == '6') {
          doomed.add(child);
        } else {
          clearDeviceLeaves(child);
        }
      }
      for (final node in doomed) {
        children.children.remove(node);
      }
  }

    for (final node in root.childElements) {
      if (node.name.local == 'NODE') clearDeviceLeaves(node);
    }
    final usedUuids = <String>{
      for (final e in root.descendantElements)
        if (e.name.local == 'UUID_STR') e.innerText.trim(),
    };
    final usedNames = <String>{};
    final perContainer = <String, int>{};
    final rebuiltBlocks = <String>[];

    for (var index = 0; index < deviceBlocks.length; index++) {
      var block = deviceBlocks[index];
      final report = deviceReport[index];
      final name = '${report['name'] ?? ''}'.trim();
      final kind = '${report['type'] ?? ''}'.trim().toLowerCase();
      if (!block.contains('<PHYSICAL_CPUR')) {
        // Packet Tracer's own sample labs save a few models with no
        // physical-workspace data at all. Such a block has nowhere to point a
        // physical leaf, so it is placed in the Logical workspace only: the
        // file stays valid and the device is still fully cabled and
        // configured.
        if (_hasTag(block, 'PHYSICAL')) {
          block = _setTag(block, 'PHYSICAL', '');
        }
        rebuiltBlocks.add(block);
        notes.add('$name: its saved model has no physical-workspace data; the '
            'device is placed in the Logical workspace only');
        continue;
      }
      if (name.isEmpty) {
        throw const PktBuildFailure(
          'a generated device has no name for its physical workspace entry',
        );
      }
      if (usedNames.contains(name)) {
        throw PktBuildFailure(
          'duplicate device name in Physical Workspace: $name',
        );
      }
      usedNames.add(name);
      final wantRack = ['router', 'switch', 'firewall', 'wireless-router']
          .contains(kind);
      final preferredType = wantRack ? '4' : '2';
      var candidates = [
        for (final c in containers)
          if (c['type'] == preferredType && '${c['uuid']}'.isNotEmpty) c,
      ];
      if (candidates.isEmpty) {
        final fallbackTypes =
            wantRack ? ['2', '3', '1', '0'] : ['3', '4', '1', '0'];
        for (final fallbackType in fallbackTypes) {
          candidates = [
            for (final c in containers)
              if (c['type'] == fallbackType && '${c['uuid']}'.isNotEmpty) c,
          ];
          if (candidates.isNotEmpty) break;
        }
      }
      if (candidates.isEmpty) {
        throw const PktBuildFailure(
          'no compatible physical container has a UUID in PHYSICALWORKSPACE',
        );
      }
      final container = candidates.first;
      final containerUuid = '${container['uuid']}';
      final path = (container['path'] as List<String>);
      if (path.any((part) => part.isEmpty)) {
        throw PktBuildFailure(
          '$name: physical container ancestry has a missing UUID',
        );
      }
      var prototype = prototypes[containerUuid];
      prototype ??= prototypes.values.isEmpty ? null : prototypes.values.first;
      if (prototype == null) {
        throw const PktBuildFailure(
          'PHYSICALWORKSPACE has no PT-authored device leaf to clone',
        );
      }

      final slot = perContainer[containerUuid] ?? 0;
      perContainer[containerUuid] = slot + 1;
      final int px;
      final int py;
      if (wantRack) {
        px = 4 + slot * 4;
        py = 0;
      } else {
        px = 86 + slot * 86;
        py = 215 + (slot ~/ 8) * 86;
      }

      var leafUuid = _stableGuid([project, name, '$index', 'physical-leaf']);
      var suffix = 1;
      while (usedUuids.contains(leafUuid)) {
        leafUuid = _stableGuid(
            [project, name, '$index', 'physical-leaf-$suffix']);
        suffix++;
      }
      usedUuids.add(leafUuid);
      final leaf = prototype.copy();

      void setChildText(String tag, String value) {
        var element = leaf.getElement(tag);
        if (element == null) {
          element = xml.XmlElement(xml.XmlName.parts(tag));
          leaf.children.add(element);
        }
        if (tag == 'NAME') {
          // ET's setdefault: an existing translate attribute keeps its value.
          if (!element.attributes.any((a) => a.name.local == 'translate')) {
            element.attributes
                .add(xml.XmlAttribute(xml.XmlName.parts('translate'), 'true'));
          }
        }
        element.children.removeWhere((n) => n is xml.XmlText);
        element.children.add(xml.XmlText(value));
      }

    setChildText('NAME', name);
    setChildText('UUID_STR', leafUuid);
    setChildText('X', '$px');
    setChildText('Y', '$py');

    final childrenNode = container['node'] as xml.XmlElement;
    var children = childrenNode.getElement('CHILDREN');
    if (children == null) {
      children = xml.XmlElement(xml.XmlName.parts('CHILDREN'));
      childrenNode.children.add(children);
    }
    children.children.add(leaf);

    final physicalPath = [...path, leafUuid].join(',');
    final parentPath = path.sublist(0, path.length - 1).join(',');
    final identity =
        _stableGuid([project, name, '$index', 'device-identity']);
    rebuiltBlocks.add(_setPhysicalIdentity(
      block: block,
      name: name,
      physicalPath: physicalPath,
      parentPath: parentPath,
      containerId: containerUuid,
      x: px,
      y: py,
      identity: identity,
    ));
  }

  final pwsXml = root.toXmlString(pretty: false);
  return (
    skeleton.substring(0, match.start) +
        pwsXml +
        skeleton.substring(match.end),
    rebuiltBlocks,
  );
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

void _validate(String xmlText, Map<String, int> refs) {
  xml.XmlDocument document;
  try {
    document = xml.XmlDocument.parse(xmlText);
  } catch (e) {
    throw PktBuildFailure('generated XML does not parse: $e');
  }
  final ids = [
    for (final m
        in RegExp(r'<SAVE_REF_ID>save-ref-id:(\d+)</SAVE_REF_ID>')
            .allMatches(xmlText))
      m.group(1)!,
  ];
  if (ids.length != ids.toSet().length) {
    throw const PktBuildFailure('generated file has duplicate device ids');
  }
  final present = {for (final id in ids) int.parse(id)};
  refs.forEach((name, ref) {
    if (!present.contains(ref)) {
      throw PktBuildFailure(
        '$name: its device id is missing from the generated document',
      );
    }
  });
  for (final m in RegExp(r'<(FROM|TO)>save-ref-id:(\d+)</(FROM|TO)>')
      .allMatches(xmlText)) {
    if (!present.contains(int.parse(m.group(2)!))) {
      throw const PktBuildFailure(
        'a link points at a device that is not in the generated document',
      );
    }
  }
  _validatePhysicalWorkspace(document);
}

void _validatePhysicalWorkspace(xml.XmlDocument document) {
  xml.XmlElement? workspace;
  for (final e in document.rootElement.descendantElements) {
    if (e.name.local == 'PHYSICALWORKSPACE') {
      workspace = e;
      break;
    }
  }
  if (workspace == null) {
    // Small synthetic fixtures can omit Packet Tracer's PWS block.
    return;
  }

  final leaves = <String, String>{};
  final pathByUuid = <String, List<String>>{};

  void indexPaths(xml.XmlElement node, List<String> ancestors) {
    final nodeUuid = _childText(node, 'UUID_STR');
    final path = [...ancestors, if (nodeUuid.isNotEmpty) nodeUuid];
    if (nodeUuid.isNotEmpty) {
      if (pathByUuid.containsKey(nodeUuid)) {
        throw PktBuildFailure(
          'duplicate Physical Workspace UUID: $nodeUuid',
        );
      }
      pathByUuid[nodeUuid] = path;
    }
    final children = node.getElement('CHILDREN');
    if (children != null) {
      for (final child in children.childElements) {
        if (child.name.local == 'NODE') indexPaths(child, path);
      }
    }
  }

  for (final node in workspace.childElements) {
    if (node.name.local == 'NODE') indexPaths(node, <String>[]);
  }
  for (final node in workspace.descendantElements) {
    if (node.name.local != 'NODE') continue;
    if (_childText(node, 'TYPE') != '6') continue;
    final nodeUuid = _childText(node, 'UUID_STR');
    final name = _childText(node, 'NAME');
    if (nodeUuid.isEmpty || name.isEmpty) {
      throw const PktBuildFailure(
        'a Physical Workspace device leaf has no name or UUID',
      );
    }
    if (leaves.containsKey(nodeUuid)) {
      throw PktBuildFailure('duplicate Physical Workspace UUID: $nodeUuid');
    }
    leaves[nodeUuid] = name;
  }
  if (leaves.values.toSet().length != leaves.length) {
    throw const PktBuildFailure(
      'duplicate device names in Physical Workspace leaves',
    );
  }

  final allUuids = <String>{
    for (final e in workspace.descendantElements)
      if (e.name.local == 'UUID_STR' && e.innerText.trim().isNotEmpty)
        e.innerText.trim(),
  };
  final devices = <xml.XmlElement>[];
  for (final e in document.rootElement.descendantElements) {
    if (e.name.local == 'DEVICES') {
      for (final d in e.childElements) {
        if (d.name.local == 'DEVICE') devices.add(d);
      }
    }
  }
  final deviceNames = <String>{
    for (final device in devices)
      if (_findFirstText(device, 'NAME').isNotEmpty)
        _findFirstText(device, 'NAME'),
  };
  // A device whose saved model carries no Physical Workspace data is placed
  // in the Logical workspace only, so it is expected to have no leaf.
  final logicalOnly = <String>{
    for (final device in devices)
      if (_findFirst(device, 'WORKSPACE')
                  ?.getElement('PHYSICAL')
                  ?.innerText
                  .trim()
                  .isEmpty ??
              true)
        if (_findFirstText(device, 'NAME').isNotEmpty)
          _findFirstText(device, 'NAME'),
  };
  final expected = deviceNames.difference(logicalOnly);
  // Python's `set != set` compares contents; Dart's `==` is identity, so the
  // comparison is structural by hand.
  final leafNames = leaves.values.toSet();
  final sameLeaves = leafNames.length == expected.length &&
      leafNames.every(expected.contains);
  if (!sameLeaves) {
    final stale = leafNames.difference(expected).toList()..sort();
    final missing = expected.difference(leafNames).toList()..sort();
    final details = <String>[];
    if (stale.isNotEmpty) details.add('stale=${stale.join(', ')}');
    if (missing.isNotEmpty) details.add('missing=${missing.join(', ')}');
    throw PktBuildFailure(
      'Physical Workspace leaves do not match network devices '
      '(${details.join('; ')})',
    );
  }
  for (final device in devices) {
    final name = _findFirstText(device, 'NAME');
    final physicalElement =
        _findFirst(device, 'WORKSPACE')?.getElement('PHYSICAL');
    final physical = physicalElement?.innerText.trim() ?? '';
    if (physical.isEmpty) {
      // Such a device is in the Logical workspace only, which is a valid
      // file, but it must not still carry the template's ancestry fields.
      if (_findFirst(device, 'WORKSPACE')
                  ?.getElement('PHYSICAL_CPUR') !=
              null) {
        throw PktBuildFailure(
          '${name.isEmpty ? 'device' : name} has Physical Workspace data '
          'but no leaf path',
        );
      }
      continue;
    }
    final path = [
      for (final part in physical.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    final unresolved = [
      for (final part in path)
        if (!allUuids.contains(part)) part,
    ];
    if (unresolved.isNotEmpty) {
      throw PktBuildFailure(
        '${name.isEmpty ? 'device' : name} has unresolved Physical Workspace '
        'UUID(s): ${unresolved.join(', ')}',
      );
    }
    if (path.isEmpty || !leaves.containsKey(path.last)) {
      throw PktBuildFailure(
        '${name.isEmpty ? 'device' : name} does not end at a physical device '
        'leaf',
      );
    }
    if (!_listEquals(path, pathByUuid[path.last])) {
      throw PktBuildFailure(
        '${name.isEmpty ? 'device' : name} Physical Workspace path is not its '
        "leaf's actual ancestry",
      );
    }
    if (leaves[path.last] != name) {
      throw PktBuildFailure(
        '${name.isEmpty ? 'device' : name} points at the Physical Workspace '
        'leaf for ${leaves[path.last]}',
      );
    }
    final cpur = _findFirst(device, 'WORKSPACE')?.getElement('PHYSICAL_CPUR');
    if (cpur == null) {
      throw PktBuildFailure(
        '${name.isEmpty ? 'device' : name} has no PHYSICAL_CPUR data',
      );
    }
    final parentPath = (cpur.getElement('PARENT_PATH')?.innerText ?? '').trim();
    final containerId =
        (cpur.getElement('CONTAINER_ID')?.innerText ?? '').trim();
    final parts = [
      for (final part in parentPath.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (containerId.isNotEmpty) parts.add(containerId);
    parts.add(path.last);
    if (!_listEquals(parts, path)) {
      throw PktBuildFailure(
        '${name.isEmpty ? 'device' : name} Physical Workspace path does not '
        'match PHYSICAL_CPUR ancestry',
      );
    }
    xml.XmlElement? leaf;
    for (final node in workspace.descendantElements) {
      // Direct-child UUID_STR, exactly like ET's findtext: PT containers
      // write their own UUID_STR *after* CHILDREN, so a descendant search
      // would make every ancestor of the leaf match the leaf's uuid.
      if (node.name.local == 'NODE' &&
          _childText(node, 'UUID_STR') == path.last) {
        leaf = node;
        break;
      }
    }
    for (final tag in ['X', 'Y']) {
      final devicePosition = (cpur.getElement(tag)?.innerText ?? '').trim();
      final leafPosition = (leaf?.getElement(tag)?.innerText ?? '').trim();
      if (devicePosition != leafPosition) {
        throw PktBuildFailure(
          '${name.isEmpty ? 'device' : name} physical $tag does not match its '
          'workspace leaf',
        );
      }
    }
  }
}

bool _listEquals(List<String> a, List<String>? b) {
  if (b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

List<String> _dedupe(List<String> messages) {
  final seen = <String>{};
  final out = <String>[];
  for (final message in messages) {
    if (seen.contains(message)) continue;
    seen.add(message);
    out.add(message);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// The spot every device was already drawn at, when the plan carries one.
///
/// Accepts `positions: {"R1": [700, 60]}` - the coordinates the app showed
/// the user in the preview - and drops anything it cannot use. A plan that
/// sends nothing usable still draws, because the caller falls back to
/// computing its own.
Map<String, (int, int)> _resolvedPositions(Object? raw) {
  final out = <String, (int, int)>{};
  if (raw is! Map) return out;
  for (final entry in raw.entries.take(4096)) {
    final key = '${entry.key}'.trim();
    final point = entry.value;
    if (key.isEmpty || point is! List || point.length < 2) continue;
    final x = (point[0] is num) ? point[0].round() : null;
    final y = (point[1] is num) ? point[1].round() : null;
    if (x == null || y == null) continue;
    if (x < -10000 || x > 100000 || y < -10000 || y > 100000) continue;
    out[key] = (x, y);
  }
  return out;
}

int _tierOf(String nodeType) {
  final kind = nodeType.trim().toLowerCase();
  if (['router', 'firewall', 'cloud', 'modem', 'wireless-router']
      .contains(kind)) {
    return 0;
  }
  if (['multilayer switch', 'wlc'].contains(kind)) return 1;
  if (['switch', 'wireless', 'accesspoint', 'wireless access point']
      .contains(kind)) {
    return 2;
  }
  if (kind == 'server') return 3;
  return 4;
}

/// The fallback drawing when the plan carries no positions: one band per
/// device kind, plan order, wrapped so no row runs off the canvas.
Map<String, (int, int)> _fallbackRows(List<Map<String, dynamic>> nodes) {
  final spots = <String, (int, int)>{};
  final bands = <int, List<String>>{};
  for (final node in nodes) {
    final name = '${node['name'] ?? ''}';
    if (name.isEmpty) continue;
    bands.putIfAbsent(
      _tierOf('${node['type'] ?? ''}'),
      () => <String>[],
    ).add(name);
  }
  final sortedTiers = bands.keys.toList()..sort();
  for (var i = 0; i < sortedTiers.length; i++) {
    final group = bands[sortedTiers[i]]!;
    final band = _rowTop + i * _bandStep;
    final columns = group.length < _rowsPerRow ? group.length : _rowsPerRow;
    for (var index = 0; index < group.length; index++) {
      final (row, column) = (index ~/ columns, index % columns);
      final inRow = (columns < group.length - row * columns)
          ? columns
          : group.length - row * columns;
      final rowLeft = _xStart +
          (((_canvasWidth - 2 * _xStart - inRow * _devicePitch) / 2)
              .floor()
              .clamp(0, 1 << 31));
      spots[group[index]] = (
        rowLeft + column * _devicePitch + _devicePitch ~/ 2,
        band + row * _rowStep,
      );
    }
  }
  return spots;
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

/// The build report, mirroring `pkt_builder.build_pkt`'s return value.
class PktEngineBuild {
  /// The save document, before encryption.
  final String xml;

  final String version;
  final String project;

  /// Device name -> the save-ref-id it was given, so links and reports can
  /// talk about the same device.
  final Map<String, int> refIds;
  final List<Map<String, dynamic>> devices;
  final List<Map<String, dynamic>> links;
  final List<String> warnings;
  final int deviceCount;
  final int linkCount;
  final int plannedDevices;
  final int plannedLinks;
  final Map<String, dynamic> layout;

  const PktEngineBuild({
    required this.xml,
    required this.version,
    required this.project,
    required this.refIds,
    required this.devices,
    required this.links,
    required this.warnings,
    required this.deviceCount,
    required this.linkCount,
    required this.plannedDevices,
    required this.plannedLinks,
    required this.layout,
  });
}

/// Compile a plan into save-file XML. Returns a report, never a file.
Future<PktEngineBuild> buildPkt({
  required Map<String, dynamic> plan,
  required PktTemplateLibrary library,
  String project = '',
  String version = '',
}) async {
  final sections = _planSections(plan);
  final nodes = [
    for (final node in sections.nodes)
      if ('${node['name'] ?? ''}'.isNotEmpty) node,
  ];
  final projectName =
      (project.isNotEmpty ? project : '${plan['project'] ?? 'default'}')
          .trim();
  final effectiveProject = projectName.isEmpty ? 'default' : projectName;
  final warnings = <String>[];

  // What ports does each node need? Links say it directly; the compiled
  // config says it for every interface it touches.
  final wanted = <String, List<String>>{};
  for (final link in sections.links) {
    for (final side in [('a', 'aIf'), ('b', 'bIf')]) {
      final (dev, iface) = side;
      final name = '${link[dev] ?? ''}';
      final spec = '${link[iface] ?? ''}';
      if (name.isNotEmpty && spec.isNotEmpty) {
        wanted.putIfAbsent(name, () => <String>[]).add(spec);
      }
    }
  }
  sections.configs.forEach((name, text) {
    final (lines, _) = _sanitizeConfigLines(text);
    for (final interface in _interfaceLines(lines)) {
      wanted.putIfAbsent(name, () => <String>[]).add(interface);
    }
  });
  // One entry per interface: a port wanted by a link *and* named in the
  // config is one requirement, not three.
  for (final name in wanted.keys.toList()) {
    final unique = <String>[];
    for (final spec in wanted[name]!) {
      if (!unique.contains(spec)) unique.add(spec);
    }
    wanted[name] = unique;
  }

  final usedRefs = <int>{};
  final refs = <String, int>{};
  final portNames = <(String, String), String>{};
  // (device, interface) -> clock rate: which ports the plan made DCE.
  final dcePorts = <(String, String), String>{};
  // (device, port): every port claimed by a resolved link, a spare remap, or
  // a config interface - so two links never share a port.
  final usedPorts = <(String, String)>{};
  final deviceBlocks = <String>[];
  final deviceReport = <Map<String, dynamic>>[];
  final variantsUsed = <String, PktTemplateDevice>{};

  // Every device's canvas spot. The drawing the app was shown wins spot for
  // spot; only devices it does not name fall back to the computed rows.
  final layoutRaw = plan['layout'];
  final resolved =
      _resolvedPositions(layoutRaw is Map ? layoutRaw['positions'] : null);
  final fallback = _fallbackRows(nodes);
  final positions = <String, (int, int)>{...fallback};
  resolved.forEach((name, spot) {
    if (nodes.any((n) => '${n['name'] ?? ''}' == name)) {
      positions[name] = spot;
    }
  });
  final layoutRawMap = layoutRaw is Map ? layoutRaw : const <String, dynamic>{};
  final layoutUsed = <String, dynamic>{
    'style': '${layoutRawMap['style'] ?? 'tree'}',
    'columns': 4,
    'spacing': 1.0,
    // ECHO the grouped-drawing facts the caller carried instead of empty
    // constants: a report that says "grouped, nothing parked" makes the
    // NEXT build recompute grouped-without-side, which is plain tree -
    // the reported reason a picked style "did not apply" on the second
    // build.
    'side': [
      for (final s in (layoutRawMap['side'] as List? ?? const <dynamic>[]))
        '$s',
    ],
    'sideEdge': '${layoutRawMap['sideEdge'] ?? 'left'}',
    'zones': [
      for (final z in (layoutRawMap['zones'] as List? ?? const <dynamic>[]))
        z,
    ],
    'positions': {
      for (final entry in positions.entries)
        entry.key: <int>[entry.value.$1, entry.value.$2],
    },
  };

  for (final node in nodes) {
    final name = '${node['name'] ?? ''}';
    final nodeType = '${node['type'] ?? ''}'.trim().toLowerCase();
    var deviceReportServices = <String, dynamic>{};
    final (selected, notes) = await selectVariant(
      library,
      node,
      wanted[name] ?? const <String>[],
    );
    warnings.addAll(notes);
    if (selected == null) continue;
    // Name the CHOSEN model's cableable ports only now it has won - see
    // [PktTemplateDevice.withNamedPorts]. Judging the whole library by named
    // ports changes which model is picked.
    final variant = selected.withNamedPorts();
    String block;
    try {
      block = await library.blockFor(variant.file);
    } on PktBuildFailure catch (e) {
      warnings.add('$name: ${e.message}');
      continue;
    }
    variantsUsed[name] = variant;
    final spot = positions[name] ?? (_xStart, _defaultRowY);
    block = _setName(block, name);
    final ref = _refId('$effectiveProject:$name', usedRefs);
    refs[name] = ref;
    block = _setRefId(block, ref);
    block = _setMacs(block, '$effectiveProject:$name');
    block = _setPosition(block, spot.$1, spot.$2);

    var configLines = <String>[];
    // One resolution per interface per device, shared by the config and the
    // links, so a two-port router cannot put its WAN and its LAN on one
    // port.
    final resolvedPorts = ResolvedPorts();
    // Reserve the ports this model really has BEFORE anything is remapped.
    // A plan names both the ports its hardware has and ports it invented to
    // keep a chain apart. Reserving the real names first means the invented
    // one takes what is left, instead of stealing the port a real name
    // needs.
    for (final spec in wanted[name] ?? const <String>[]) {
      final exact = exactPort(variant, spec);
      if (exact != null) {
        resolvedPorts.claimExact(normalizePortName(spec), exact);
      }
    }
    if (sections.configs.containsKey(name)) {
      final (lines, dropped) = _sanitizeConfigLines(sections.configs[name]!);
      if (dropped.isNotEmpty) {
        final unique = dropped.toSet().toList()..sort();
        warnings.add('$name: dropped exec-only line(s) from the saved '
            'config: ${unique.join(', ')}');
      }
      final (remapped, remapNotes) =
          _remapConfigInterfaces(variant, lines, resolvedPorts);
      configLines = remapped;
      warnings.addAll(remapNotes);
      block = _setConfig(block, configLines);
    }

    // Every port the plan named, resolved once, so links and IP config both
    // use the name Packet Tracer actually knows.
    final planPorts = <String, PktTemplatePort>{};
    for (final spec in wanted[name] ?? const <String>[]) {
      final (port: port, note: note) = resolvedPorts.resolve(variant, spec);
      if (port != null) {
        planPorts[spec] = port;
        portNames[(name, spec)] = port.name;
        usedPorts.add((name, port.name));
        if (note.isNotEmpty && !warnings.contains(note)) {
          warnings.add('$name: $note');
        }
      }
    }
    // Stamp the resolved name onto the PORT element itself.
    //
    // A model whose port block carries no <NAME> (every access point - the
    // port is named from the host module and never written into the save)
    // is addressable by name in the manifest but not in its own XML, so a
    // LINK that says <PORT>FastEthernet0</PORT> points at a port the device
    // block never declares. Writing the name closes that gap: the device says
    // "this port is called FastEthernet0" and the cable references it.
    for (final port in planPorts.values) {
      block = _stampPortName(block, port.index, port.name);
    }
    // Clocking: a serial DCE end needs the flag set on the port itself.
    planPorts.forEach((spec, port) {
      final clock = _clockRateFor(configLines, port.name);
      if (clock.isNotEmpty) {
        dcePorts[(name, port.name)] = clock;
        block = _patchPort(block, port.index, {
          'CLOCKRATE': clock,
          'CLOCKRATEFLAG': 'true',
        });
      }
    });

    // Mirror interface runtime state into the PORT elements. Packet Tracer
    // loads up/down and the IP from the port, NOT by replaying the running
    // config - a generated file that only embeds config text opens with
    // every referenced interface down (the serial link shows red).
    final byName = <String, PktTemplatePort>{
      for (final port in variant.ports)
        if (port.name.isNotEmpty) normalizePortName(port.name): port,
    };
    _interfaceBlocks(configLines).forEach((ifname, sub) {
      // A dot1Q sub-interface resolves to its parent's port; its own address
      // must NOT be mirrored onto that physical port (the parent is a trunk
      // - the address lives in PT's sub-interface config text).
      if (_subinterface.hasMatch(ifname)) return;
      final port = byName[normalizePortName(ifname)];
      if (port == null) return;
      usedPorts.add((name, port.name));
      final fields = <String, String>{};
      final lowered = [for (final s in sub) s.trim().toLowerCase()];
      if (lowered.contains('no shutdown')) {
        fields['POWER'] = 'true';
      } else if (lowered.contains('shutdown')) {
        fields['POWER'] = 'false';
      }
      for (final line in lowered) {
        final match = RegExp(r'^ip address\s+(\S+)\s+(\S+)$').firstMatch(line);
        if (match != null) {
          fields['IP'] = match.group(1)!;
          fields['SUBNET'] = match.group(2)!;
        }
      }
      if (fields.isNotEmpty) {
        block = _patchPort(block, port.index, fields);
      }
    });

    // End-device IP settings land on the port that carries the link,
    // falling back to the first named Ethernet port. Servers carry the same
    // shape under config_servers (ip/mask/gw next to their services), so
    // they get identical treatment.
    Map<String, dynamic>? endpointSettings;
    if (sections.pcs.containsKey(name)) {
      endpointSettings = sections.pcs[name] ?? <String, dynamic>{};
    } else if (sections.servers.containsKey(name)) {
      final entry = sections.servers[name];
      if (entry is Map && entry['ip'] != null) {
        endpointSettings = Map<String, dynamic>.from(entry);
      }
    }
    if (endpointSettings != null) {
      final settings = endpointSettings;
      PktTemplatePort? target;
      for (final port in planPorts.values) {
        if (_ethernetFamilies.contains(port.family)) {
          target = port;
          break;
        }
      }
      target ??= () {
        for (final port in variant.ports) {
          if (port.name.isNotEmpty && _ethernetFamilies.contains(port.family)) {
            return port;
          }
        }
        return null;
      }();
      if (target == null) {
        warnings.add('$name: no Ethernet port found for its IP settings');
      } else {
        final fields = <String, String>{'PORT_DHCP_ENABLE': 'false'};
        if ('${settings['ip'] ?? ''}'.isNotEmpty) {
          fields['IP'] = '${settings['ip']}';
        }
        if ('${settings['mask'] ?? ''}'.isNotEmpty) {
          fields['SUBNET'] = '${settings['mask']}';
        }
        if ('${settings['gw'] ?? ''}'.isNotEmpty) {
          fields['PORT_GATEWAY'] = '${settings['gw']}';
        }
        if ('${settings['dns'] ?? ''}'.isNotEmpty) {
          fields['PORT_DNS'] = '${settings['dns']}';
        }
        if ('${settings['ipv6'] ?? ''}'.toLowerCase() == 'true') {
          // Dual-stack: endpoints autoconfigure from the router's
          // advertisements (SLAAC) rather than a spelled-out address.
          fields['IPV6_ENABLED'] = 'true';
          fields['IPV6_ADDRESS_AUTOCONFIG'] = 'true';
        }
        block = _patchPort(block, target.index, fields);
      }
    }

    // SERVICES TAB: the save file really does carry it (DHCP pools, DNS
    // records, HTTP/HTTPS, FTP/email accounts, the ACS/TACACS+ users and
    // clients), so an offline .pkt is configured, not just placed. The
    // template's own leftovers - a stale pool and its leases - are replaced
    // either way, never shipped.
    final serverEntry = sections.servers[name];
    Map<String, dynamic> serverServices;
    if (serverEntry is Map) {
      final servicesField = serverEntry['services'];
      serverServices = servicesField is Map
          ? Map<String, dynamic>.from(servicesField)
          : Map<String, dynamic>.from(serverEntry);
    } else {
      serverServices = <String, dynamic>{};
    }
    // Wireless rules ride on the NODE itself (serviceRules.wireless) - they
    // apply to APs, home routers and any device with a wireless ENGINE,
    // none of which are servers.
    final nodeRules = node['serviceRules'];
    final nodeWireless = nodeRules is Map ? nodeRules['wireless'] : null;
    if (nodeWireless != null) {
      serverServices = {
        ...serverServices,
        'wireless': nodeWireless,
      };
    }
    final (servicedBlock, serviceNotes, serviceReport) =
        _applyServices(block, variant, serverServices);
    block = servicedBlock;
    warnings.addAll([for (final n in serviceNotes) '$name: $n']);
    if (serviceReport.isNotEmpty) {
      deviceReportServices = serviceReport;
    }

    deviceBlocks.add(block);
    deviceReport.add({
      'name': name,
      'type': nodeType,
      if (deviceReportServices.isNotEmpty) 'services': deviceReportServices,
      'model': variant.model,
      'template': variant.key,
      'x': spot.$1,
      'y': spot.$2,
      'configLines': configLines.length,
      'ports': {
        for (final entry in planPorts.entries) entry.key: entry.value.name,
      },
    });
  }

  final linkBlocks = <String>[];
  final linkReport = <Map<String, dynamic>>[];
  for (final link in sections.links) {
    // Load and pick the cable template the link will clone.
    final requestedCable = '${link['cable'] ?? 'copper'}';
    final (template, note) = _pickLinkTemplate(library, requestedCable);
    if (template == null) {
      warnings.add('link ${link['a'] ?? ''}-${link['b'] ?? ''}: '
          '${note.isEmpty ? 'the library has no copper cable template' : note}');
      continue;
    }
    String templateBlock;
    try {
      templateBlock = await library.blockFor(template.file);
    } on PktBuildFailure catch (e) {
      warnings.add('link ${link['a'] ?? ''}-${link['b'] ?? ''}: ${e.message}');
      continue;
    }
    final block = _buildLink(
      template: template,
      templateBlock: templateBlock,
      link: link,
      refs: refs,
      portNames: portNames,
      warnings: warnings,
      dcePorts: dcePorts,
      usedPorts: usedPorts,
      variants: variantsUsed,
    );
    if (block == null) continue;
    // The link's own port claims (resolved or spare-remapped) count toward
    // the used set, so a later link cannot take them.
    for (final side in ['a', 'b']) {
      final dev = '${link[side] ?? ''}';
      final port = portNames[(dev, '${link['${side}If'] ?? ''}')] ?? '';
      if (dev.isNotEmpty && port.isNotEmpty) usedPorts.add((dev, port));
    }
    linkBlocks.add(block);
    linkReport.add({
      'a': '${link['a'] ?? ''}',
      'aIf': portNames[('${link['a'] ?? ''}', '${link['aIf'] ?? ''}')] ?? '',
      'b': '${link['b'] ?? ''}',
      'bIf': portNames[('${link['b'] ?? ''}', '${link['bIf'] ?? ''}')] ?? '',
      'cable': '${link['cable'] ?? 'copper'}',
    });
  }

  // ONE INTERFACE, ONE CABLE. A plan may name the same port twice, but the
  // generator must never *create* it: two <LINK> records on one port is what
  // Packet Tracer refuses to load. Report it rather than ship it quietly.
  final cableCount = <(String, String), int>{};
  for (final link in linkReport) {
    for (final side in ['a', 'b']) {
      final device = '${link[side] ?? ''}';
      final port = '${link['${side}If'] ?? ''}';
      if (device.isNotEmpty && port.isNotEmpty) {
        cableCount[(device, port)] = (cableCount[(device, port)] ?? 0) + 1;
      }
    }
  }
  final sortedCables = cableCount.keys.toList()
    ..sort((a, b) => '${a.$1}|${a.$2}'.compareTo('${b.$1}|${b.$2}'));
  for (final key in sortedCables) {
    final count = cableCount[key]!;
    if (count > 1) {
      warnings.add('${key.$1}: ${key.$2} is cabled $count times - one '
          'interface cannot carry two cables, so only one of them can work');
    }
  }

  if (sections.servers.isNotEmpty &&
      !deviceReport.any((entry) => entry['services'] != null)) {
    warnings.add('no server in this plan declares a service role, so every '
        'Services tab was left at its off state');
  }

  var xmlText = library.skeleton;
  xmlText = _replaceFirst(
    xmlText,
    RegExp(r'<VERSION>[^<]*</VERSION>'),
    '<VERSION>${_esc(version.isNotEmpty ? version : (library.version.isNotEmpty ? library.version : '9.0.0.0810'))}</VERSION>',
  );  final (rebuiltXml, rebuiltBlocks) = _rebuildPhysicalWorkspace(
    skeleton: xmlText,
    deviceBlocks: deviceBlocks,
    deviceReport: deviceReport,
    project: effectiveProject,
    notes: warnings,
  );
  xmlText = rebuiltXml;
  deviceBlocks
    ..clear()
    ..addAll(rebuiltBlocks);
  final devicesDoc = deviceBlocks
      .map((block) =>
          block.split('\n').map((line) => '   $line').join('\n'))
      .join('\n');
  final linksDoc = linkBlocks
      .map((block) =>
          block.split('\n').map((line) => '   $line').join('\n'))
      .join('\n');
  xmlText = xmlText.replaceFirstMapped(
    RegExp(r'<DEVICES\s*>\s*</DEVICES>'),
    (_) => '<DEVICES>\n$devicesDoc\n  </DEVICES>',
  );
  xmlText = xmlText.replaceFirstMapped(
    RegExp(r'<LINKS\s*>\s*</LINKS>'),
    (_) => '<LINKS>\n$linksDoc\n  </LINKS>',
  );
  if (!xmlText.contains('<DEVICE>')) {
    throw const PktBuildFailure(
      'no device could be built from this plan; the template library may not '
      'cover the planned models',
    );
  }

  _validate(xmlText, refs);
  return PktEngineBuild(
    xml: xmlText,
    version: version.isNotEmpty ? version : library.version,
    project: effectiveProject,
    refIds: refs,
    devices: deviceReport,
    links: linkReport,
    warnings: _dedupe(warnings),
    deviceCount: deviceBlocks.length,
    linkCount: linkBlocks.length,
    plannedDevices: nodes.length,
    plannedLinks: sections.links.length,
    layout: layoutUsed,
  );
}
