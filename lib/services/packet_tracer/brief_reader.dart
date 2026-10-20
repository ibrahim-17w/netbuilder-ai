import '../../models/network_intent.dart';
import 'catalog.dart';

class _Binding {
  final String name;
  final String type;
  final PtDevice? device;
  final String? requestedModel;
  final List<String> modules;
  const _Binding(
    this.name,
    this.type, {
    this.device,
    this.requestedModel,
    this.modules = const [],
  });

  String? get model => requestedModel ?? device?.model;
  bool get exactModel => requestedModel != null || device != null;
}

class _ModelMention {
  final int start, end, count;
  final PtDevice device;
  final List<String> modules;
  final List<String> labels;
  const _ModelMention(
    this.start,
    this.end,
    this.count,
    this.device,
    this.modules, {
    this.labels = const [],
  });
}

typedef _ConnectionMention = ({
  int start,
  int end,
  String a,
  String aIf,
  String b,
  String bIf,
  String? forcedCable,
});

/// Reads hardware and connection clauses before the general network planner.
/// Model numbers never become device counts, and original names survive.
class PtBriefRequest {
  final String raw;
  final String plannerText;
  final Map<String, _Binding> _bindings;
  final List<_ModelMention> _models;
  final List<NetLink> connections;
  const PtBriefRequest._(
    this.raw,
    this.plannerText,
    this._bindings,
    this._models,
    this.connections,
  );

  static final _clauseBreak = RegExp(r'[;\n]|[.!?](?=\s+[A-Za-z])');
  static final _instructionBreak = RegExp(
    r'\b(?:connect|configure|assign|install|keep|run|show|use)\b',
    caseSensitive: false,
  );
  static const _port =
      r'(?:FastEthernet|GigabitEthernet|TenGigabitEthernet|TwentyFiveGigE|HundredGigE|Ethernet|Serial|Async|Fa|Gi|Te|Eth|Se|F|G|S)\s*\d+(?:/\d+){0,3}|RS[- ]?232\d*|Console\s*\d*|Aux(?:iliary)?\s*\d*|USB\s*\d*|Coax(?:ial)?\s*\d*|Modem\s*\d*|Phone\s*\d*|(?:GPIO|D|A)\d+|Port\s*\d+(?:/\d+)*';
  static const _label =
      r'`[^`\n]+`|"[^"\n]+"|\x27[^\x27\n]+\x27|(?:Multilayer Switch|Access Point|Wireless Router|IP Phone|Analog Phone|Home VoIP|Central Office Server|Cell Tower|Power Distribution Device)\s*\d+|[A-Za-z][A-Za-z0-9_.-]*';
  static final _connection = RegExp(
    '($_label)\\s+($_port)\\s*'
    r'(?:connects?\s+to|connected\s+to|to|->|→|and)\s*'
    '($_label)\\s+($_port)',
    caseSensitive: false,
  );
  // Common Cisco lab notation puts the interface inside the backticks with
  // the device name: `R-HQ G0/1` to `R-EAST G0/1`. The general endpoint
  // matcher above expects the interface outside the quoted label, so keep a
  // second explicit form instead of dropping these exact connections.
  static final _combinedConnection = RegExp(
    '`([^`\\n]+?\\s+$_port)`\\s*'
    r'(?:connects?\s+to|connected\s+to|to|->|→|and)\s*'
    '`([^`\\n]+?\\s+$_port)`',
    caseSensitive: false,
  );
  static final _combinedEndpoint = RegExp('^(.+?)\\s+($_port)\$');
  // An end device normally has only one Ethernet interface, so Packet
  // Tracer briefs often state only the switch side: "PC1 connects to SW1
  // FastEthernet0/2". Keep that explicit switch port while deriving the
  // endpoint's single port from its model.
  static final _singlePortConnection = RegExp(
    '($_label)\\s*(?:connects?\\s+to|connected\\s+to|to|->|→)\\s*'
    '($_label)\\s+($_port)',
    caseSensitive: false,
  );
  static final _singlePortReverseConnection = RegExp(
    '($_label)\\s+($_port)\\s*(?:connects?\\s+to|connected\\s+to|to|->|→)\\s*'
    // Do not let the label backtrack into the middle of a name: "Router0"
    // must not become "Router" just so the port lookahead can pass. Without
    // the boundary, "PC0 RS232 to Router0 Console" produced a second console
    // link to a phantom device called "Router".
    // Group the whole port alternation inside the lookahead: `_port` is a
    // top-level `|` chain, so `\s*$_port` would only attach the whitespace to
    // its first alternative and miss " Console".
    '($_label)(?![A-Za-z0-9_.-])(?!\\s*($_port))',
    caseSensitive: false,
  );
  static final _routerPeerPort = RegExp(
    r'\b([A-Za-z][A-Za-z0-9_.-]*)\s+and\s+'
    r'([A-Za-z][A-Za-z0-9_.-]*)\s+connect\s+to\s+each\s+other\s+'
    'using\\s+($_port)\\s+on\\s+both\\s+sides',
    caseSensitive: false,
  );
  static final _rangedConnection = RegExp(
    r'`?([A-Za-z][A-Za-z0-9_.-]*\d+)`?\s*[-–—]\s*'
    r'`?([A-Za-z][A-Za-z0-9_.-]*\d+)`?\s+to\s+'
    '`?([A-Za-z][A-Za-z0-9_.-]*)\\s*($_port)`?\\s*[-–—]\\s*'
    '`?((?:[A-Za-z]+\\s*)?\\d+(?:/\\d+){0,3})`?',
    caseSensitive: false,
  );
  static final _listedRangeConnection = RegExp(
    r'((?:[A-Za-z][A-Za-z0-9_.-]*\s*,\s*)+'
    r'[A-Za-z][A-Za-z0-9_.-]*(?:\s*,?\s+and\s+[A-Za-z][A-Za-z0-9_.-]*)?)'
    r'\s+to\s+([A-Za-z][A-Za-z0-9_.-]*)\s*'
    '($_port)\\s*[-–—]\\s*((?:[A-Za-z]+\\s*)?\\d+(?:/\\d+){0,3})',
    caseSensitive: false,
  );
  static final _siteGroupRange = RegExp(
    '\\b(?:Connect\\s+|and\\s+)?(HQ|East|West)\\s+(PCs?|phones?)\\s+to\\s+'
    '`?([A-Za-z][A-Za-z0-9_.-]*)\\s*($_port)`?\\s*[-–—]\\s*'
    '`?($_port)`?',
    caseSensitive: false,
  );
  static final _sitePhoneLink = RegExp(
    '\\bConnect\\s+the\\s+(HQ|East|West)\\s+phone\\s+to\\s+'
    '`?([A-Za-z][A-Za-z0-9_.-]*)\\s*($_port)`?',
    caseSensitive: false,
  );
  static final _siteAccessPointLink = RegExp(
    r'`?(AP-(HQ|EAST|WEST))`?\s+to\s+`?'
    '($_port)`?',
    caseSensitive: false,
  );
  static String _unquote(String value) =>
      value.replaceAll(RegExp(r'^[`"\x27]|[`"\x27]$'), '');
  static const _prefixes = {
    'router': 'R',
    'switch': 'SW',
    'pc': 'PC',
    'server': 'SRV',
    'laptop': 'LT',
    'wireless': 'AP',
    'wlc': 'WLC',
    'phone': 'PH',
    'firewall': 'FW',
    'iot': 'IOT',
    'mcu': 'MCU',
    'sbc': 'SBC',
    'plc': 'PLC',
    'hub': 'HUB',
    'cloud': 'CLOUD',
    'modem': 'MODEM',
    'tablet': 'TAB',
    'smartphone': 'SP',
  };
  static const _namedKinds = {
    'router': 'router',
    'switch': 'switch',
    'pc': 'pc',
    'server': 'server',
    'laptop': 'laptop',
    'access point': 'wireless',
    'hub': 'hub',
    'firewall': 'firewall',
    'controller': 'controller',
    'plc': 'plc',
    'sbc': 'sbc',
    'mcu': 'mcu',
  };
  static String? _typeFromName(String name) {
    final n = name.toLowerCase().replaceAll(' ', '');
    // Real lab names commonly carry a site suffix rather than a number:
    // `R-HQ`, `SW-HQ-DIST`, `PC-EAST-01`, `SRV-01`, `AP-HQ`.
    // Connections still need their device kind so they can attach to the
    // counted, model-resolved inventory instead of creating unknown nodes.
    for (final entry in const {
      'ipph-': 'phone',
      'ip-phone-': 'phone',
      'phone-': 'phone',
      'ph-': 'phone',
      'router-': 'router',
      'r-': 'router',
      'switch-': 'switch',
      'sw-': 'switch',
      'server-': 'server',
      'srv-': 'server',
      'computer-': 'pc',
      'pc-': 'pc',
      'laptop-': 'laptop',
      'lt-': 'laptop',
      'accesspoint-': 'wireless',
      'access-point-': 'wireless',
      'ap-': 'wireless',
    }.entries) {
      if (n.startsWith(entry.key)) return entry.value;
    }
    for (final pair in const {
      'multilayerswitch': 'switch',
      'ipphone': 'phone',
      'analogphone': 'analog-phone',
      'accesspoint': 'wireless',
      'wirelessrouter': 'wireless-router',
      'homerouter': 'wireless-router',
      'router': 'router',
      'switch': 'switch',
      'server': 'server',
      'laptop': 'laptop',
      'pc': 'pc',
      'srv': 'server',
      'sw': 'switch',
      'r': 'router',
      'ap': 'wireless',
      'wlc': 'wlc',
      'fw': 'firewall',
      'hub': 'hub',
      'mcu': 'mcu',
      'sbc': 'sbc',
      'plc': 'plc',
      'ph': 'phone',
    }.entries) {
      if (RegExp('^${pair.key}[0-9]+\$').hasMatch(n)) return pair.value;
    }
    return null;
  }

  static List<String> _inventoryNamesAfter(String text, int end) {
    final lineEnd = text.indexOf('\n', end);
    final clauseEnd = text.indexOf(_clauseBreak, end);
    final suffixEnd = [
      if (lineEnd >= 0) lineEnd,
      if (clauseEnd >= 0) clauseEnd,
      text.length,
    ].reduce((a, b) => a < b ? a : b);
    final suffix = text.substring(end, suffixEnd);
    final listing = RegExp(
      r'^\s*[`*_]*\s*(?:routers?|switch(?:es)?|pcs?|computers?|servers?|laptops?|'
      r'printers?|ip\s+phones?|phones?|access\s+points?|aps?|devices?)\s*:\s*(.+)$',
      caseSensitive: false,
    ).firstMatch(suffix);
    if (listing == null) return const [];
    final names = <String>[];
    for (final raw in listing[1]!.split(RegExp(r'\s*(?:,|\band\b)\s*'))) {
      final token = raw
          .trim()
          .replaceAll(RegExp(r'[`"\x27*_]'), '')
          .replaceAll(RegExp(r'\.$'), '');
      if (token.isEmpty) continue;
      final expanded = _expandInventoryRange(token);
      if (expanded.isNotEmpty) {
        names.addAll(expanded);
      } else {
        names.add(token);
      }
    }
    return names;
  }

  static bool _isNegatedDeviceCommand(String text, int at) {
    if (at <= 0) return false;
    final sentenceStart =
        [
          text.lastIndexOf('.', at - 1),
          text.lastIndexOf(';', at - 1),
          text.lastIndexOf('\n', at - 1),
        ].reduce((a, b) => a > b ? a : b) +
        1;
    final head = text.substring(sentenceStart, at);
    final negative = RegExp(
      r'\b(?:do\s+not|don.t|never|must\s+not|should\s+not)\s+'
      r'(?:add|include|create|introduce|insert|use|choose|select)\b',
      caseSensitive: false,
    ).allMatches(head).lastOrNull;
    if (negative == null) return false;
    final laterPositive = RegExp(
      r'\b(?:but|however)\s+(?:do\s+)?'
      r'(?:add|include|create|introduce|insert|use|choose|select)\b',
      caseSensitive: false,
    ).allMatches(head).any((match) => match.start > negative.start);
    return !laterPositive;
  }

  static List<String> _expandInventoryRange(String token) {
    for (var i = 1; i < token.length - 1; i++) {
      final separator = token[i];
      if (separator != '-' && separator != '–' && separator != '—') continue;
      final left = RegExp(r'^(.*?)(\d+)$').firstMatch(token.substring(0, i));
      if (left == null) continue;
      final right = RegExp(r'^(.*?)(\d+)$').firstMatch(token.substring(i + 1));
      if (right == null || left[1]!.toLowerCase() != right[1]!.toLowerCase()) {
        continue;
      }
      final from = int.tryParse(left[2]!);
      final to = int.tryParse(right[2]!);
      if (from == null || to == null || (to - from).abs() > 499) continue;
      // Preserve a deliberately zero-padded inventory (PC-01–PC-08), but
      // don't change ordinary names like PC1-PC10 into PC01-PC10.
      final padded = left[2]!.startsWith('0') || right[2]!.startsWith('0');
      final width = padded
          ? (left[2]!.length > right[2]!.length
                ? left[2]!.length
                : right[2]!.length)
          : 0;
      final step = from <= to ? 1 : -1;
      final out = <String>[];
      for (var value = from; ; value += step) {
        out.add('${left[1]}${value.toString().padLeft(width, '0')}');
        if (value == to) break;
      }
      return out;
    }
    return const [];
  }

  static List<String> _expandPortRange(String start, String end) {
    final left = RegExp(r'^(.*?)(\d+)$').firstMatch(start);
    final right = RegExp(r'^(.*?)(\d+)$').firstMatch(end);
    if (left == null || right == null) {
      return const [];
    }
    var rightPrefix = right[1]!;
    final leftPrefix = left[1]!;
    if (leftPrefix.toLowerCase() != rightPrefix.toLowerCase()) {
      if (leftPrefix.toLowerCase().endsWith(rightPrefix.toLowerCase())) {
        // Cisco notation commonly shortens Fa0/7-0/12 to omit the interface
        // type on the final port. Expand it back to Fa0/12 before pairing.
        rightPrefix = leftPrefix;
      } else {
        return const [];
      }
    }
    final from = int.tryParse(left[2]!);
    final to = int.tryParse(right[2]!);
    if (from == null || to == null || (to - from).abs() > 499) {
      return const [];
    }
    final step = from <= to ? 1 : -1;
    final result = <String>[];
    for (var value = from; ; value += step) {
      result.add('$leftPrefix$value');
      if (value == to) break;
    }
    return result;
  }

  static final _modulePattern = RegExp(
    r'\b(?:HWIC-[\w-]+|WIC-[\w-]+|NM-[\w-]+|GLC-[\w-]+|PT-[A-Z0-9-]*NM-[A-Z0-9-]+)\b',
    caseSensitive: false,
  );
  static List<String> _moduleNames(String text) => _modulePattern
      .allMatches(text)
      .map((m) => m[0]!.toUpperCase())
      .toSet()
      .toList();

  static final _modelPatterns = <String, RegExp>{};

  factory PtBriefRequest.read(String text) {
    final catalog = PacketTracerCatalog.instance;
    final modelMatches = <_ModelMention>[];
    for (final device in catalog.devices) {
      for (final alias in {
        device.model,
        ...device.aliases,
        if (RegExp(r'^\d').hasMatch(device.model)) 'Cisco ${device.model}',
      }) {
        if (alias.length < 2) continue;
        // Generic type words are inventory counts, not model names. Removing
        // "cloud", "printer", or "smartphone" from "1 cloud, 1 printer, and
        // 1 smartphone" made the general planner lose the counts and then
        // appended disconnected model nodes after it had laid out the plan.
        // Explicit catalog names such as Cloud-PT and Printer-PT still match.
        if (const {
          'router',
          'routers',
          'switch',
          'switches',
          'pc',
          'pcs',
          'computer',
          'computers',
          'server',
          'servers',
          'laptop',
          'laptops',
          'printer',
          'printers',
          'cloud',
          'clouds',
          'modem',
          'modems',
          'phone',
          'phones',
          'ip phone',
          'ip phones',
          'access point',
          'access points',
          'wireless access point',
          'wireless access points',
          'tablet',
          'tablets',
          'smartphone',
          'smartphones',
          'firewall',
          'firewalls',
        }.contains(alias.toLowerCase().trim())) {
          continue;
        }
        final pattern = _modelPatterns.putIfAbsent(
          alias,
          () => RegExp(
            '(?<![a-z0-9])${RegExp.escape(alias)}(?![a-z0-9-])',
            caseSensitive: false,
          ),
        );
        for (final match in pattern.allMatches(text)) {
          if (_isNegatedDeviceCommand(text, match.start)) continue;
          final prefix = text.substring(0, match.start);
          final quantity =
              RegExp(
                r'(\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty)\s*(?:(?:Cisco|Catalyst)\s*)?[`*_]*$',
                caseSensitive: false,
              ).firstMatch(prefix) ??
              RegExp(
                r'(\d{1,3})\s+(?:routers?|switches|switch|pcs?|servers?|devices?)\s*\(\s*$',
                caseSensitive: false,
              ).firstMatch(prefix);
          final distinctive = RegExp(r'\d|[-_]').hasMatch(alias);
          if (!distinctive &&
              quantity == null &&
              !RegExp(
                r'(?:add|create|use|model|named|called)\s+(?:an?\s+)?$',
                caseSensitive: false,
              ).hasMatch(prefix)) {
            continue;
          }
          modelMatches.add(
            _ModelMention(
              match.start,
              match.end,
              int.tryParse(quantity?[1] ?? '') ??
                  const {
                    'one': 1,
                    'two': 2,
                    'three': 3,
                    'four': 4,
                    'five': 5,
                    'six': 6,
                    'seven': 7,
                    'eight': 8,
                    'nine': 9,
                    'ten': 10,
                    'eleven': 11,
                    'twelve': 12,
                    'twenty': 20,
                  }[quantity?[1]?.toLowerCase()] ??
                  1,
              device,
              _moduleNames(
                text.substring(
                  match.end,
                  text.indexOf(_clauseBreak, match.end) < 0
                      ? text.length
                      : text.indexOf(_clauseBreak, match.end),
                ),
              ),
            ),
          );
        }
      }
    }
    modelMatches.sort((a, b) => (b.end - b.start).compareTo(a.end - a.start));
    final modelMentions = <_ModelMention>[];
    for (final match in modelMatches) {
      if (!modelMentions.any(
        (m) => match.start < m.end && match.end > m.start,
      )) {
        modelMentions.add(match);
      }
    }
    modelMentions.sort((a, b) => a.start.compareTo(b.start));
    for (var i = 0; i < modelMentions.length; i++) {
      final mention = modelMentions[i];
      var end = i + 1 < modelMentions.length
          ? modelMentions[i + 1].start
          : text.length;
      final clause = text.indexOf(_clauseBreak, mention.end);
      final instruction = text.indexOf(_instructionBreak, mention.end);
      if (clause >= 0 && clause < end) end = clause;
      if (instruction >= 0 && instruction < end) end = instruction;
      modelMentions[i] = _ModelMention(
        mention.start,
        mention.end,
        mention.count,
        mention.device,
        _moduleNames(text.substring(mention.end, end)),
        labels: _inventoryNamesAfter(text, mention.end),
      );
    }
    final named = <String, _Binding>{};
    final unsupportedInventoryModels = <({String model, int start, int end})>[];
    void bind(
      String name,
      String type, {
      PtDevice? device,
      String? requestedModel,
      List<String> modules = const [],
    }) {
      final key = name.toLowerCase();
      final old = named[key];
      named[key] = _Binding(
        name,
        device?.type ?? type,
        device: device ?? old?.device,
        requestedModel: requestedModel ?? old?.requestedModel,
        modules: modules.isEmpty ? old?.modules ?? const [] : modules,
      );
    }

    // Preserve an explicitly named model even when the bundled catalog does
    // not know it. The buildability check can then ask the user about that
    // exact model instead of silently choosing the default for its device.
    final explicitInventoryLine = RegExp(
      r'^\s*-\s*\d{1,3}\s+(`[^`\r\n]+`)\s+'
      r'(routers?|switch(?:es)?|pcs?|servers?|laptops?|ip\s+phones?|phones?|'
      r'access\s+points?|aps?)\s*:\s*(.+)$',
      caseSensitive: false,
      multiLine: true,
    );
    for (final match in explicitInventoryLine.allMatches(text)) {
      final wrappedModel = match[1]!;
      final model = wrappedModel.substring(1, wrappedModel.length - 1).trim();
      if (catalog.device(model) != null) continue;
      final noun = match[2]!.toLowerCase();
      final type = noun.startsWith('router')
          ? 'router'
          : noun.startsWith('switch')
          ? 'switch'
          : noun.startsWith('pc')
          ? 'pc'
          : noun.startsWith('server')
          ? 'server'
          : noun.startsWith('laptop')
          ? 'laptop'
          : noun.startsWith('ip phone') || noun.startsWith('phone')
          ? 'phone'
          : 'wireless';
      final modelAt = match.start + match[0]!.indexOf(wrappedModel);
      unsupportedInventoryModels.add((
        model: model,
        start: modelAt,
        end: modelAt + wrappedModel.length,
      ));
      for (final label in _inventoryNamesAfter(
        text,
        modelAt + wrappedModel.length,
      )) {
        bind(label, type, requestedModel: model);
      }
    }

    for (final match in RegExp(
      r'\b(router|switch|pc|server|laptop|access point|hub|firewall|controller|plc|sbc|mcu)\s+(?:named|called)\s+([A-Za-z][\w.-]*)',
      caseSensitive: false,
    ).allMatches(text)) {
      bind(match[2]!, _namedKinds[match[1]!.toLowerCase()]!);
    }
    for (final mention in modelMentions) {
      final before = text.substring(0, mention.start);
      final after = text.substring(mention.end);
      final left = RegExp(
        r'\b([A-Za-z][\w.-]*)\s*(?:\(\s*|(?:is\s+)?(?:an?\s+)?(?:model\s+))$',
        caseSensitive: false,
      ).firstMatch(before);
      final right = RegExp(
        r'^\s*(?:\)\s*)?(?:named|called|as)\s+([A-Za-z][\w.-]*)',
        caseSensitive: false,
      ).firstMatch(after);
      final label = right?[1] ?? left?[1];
      if (label != null &&
          !const {
            'routers',
            'switches',
            'pcs',
            'servers',
            'devices',
          }.contains(label.toLowerCase()) &&
          !const [
            'router',
            'switch',
            'pc',
            'server',
            'use',
            'add',
            'model',
            'a',
            'an',
          ].contains(label.toLowerCase())) {
        final modules = mention.modules;
        bind(
          label,
          mention.device.type,
          device: mention.device,
          modules: modules,
        );
      }
    }
    for (final mention in modelMentions) {
      for (final label in mention.labels) {
        bind(
          label,
          mention.device.type,
          device: mention.device,
          modules: mention.modules,
        );
      }
    }
    final matches = <_ConnectionMention>[];
    final straightThroughSpecified = RegExp(
      r'copper\s+straight-through.*device-to-switch',
      caseSensitive: false,
      dotAll: true,
    ).hasMatch(text);
    final endpointRanges = <({int start, int end})>[
      for (final m in _rangedConnection.allMatches(text))
        (start: m.start, end: m.end),
      for (final m in _listedRangeConnection.allMatches(text))
        (start: m.start, end: m.end),
    ];
    bool insideEndpointRange(int start, int end) =>
        endpointRanges.any((range) => range.start <= start && range.end >= end);
    String devicePort(String name, String type) {
      final binding = named[name.toLowerCase()];
      final device = binding?.device ?? catalog.device(binding?.model ?? '');
      final port = device?.ports
          .where((candidate) => candidate.medium == 'copper')
          .firstOrNull;
      if (port != null) return port.name;
      return switch (type) {
        'router' => 'GigabitEthernet0/0',
        'switch' => 'FastEthernet0/1',
        _ => 'FastEthernet0',
      };
    }

    for (final m in _connection.allMatches(text)) {
      matches.add((
        start: m.start,
        end: m.end,
        a: _unquote(m[1]!),
        aIf: m[2]!,
        b: _unquote(m[3]!),
        bIf: m[4]!,
        forcedCable: null,
      ));
    }
    for (final m in _combinedConnection.allMatches(text)) {
      final a = _combinedEndpoint.firstMatch(m[1]!);
      final b = _combinedEndpoint.firstMatch(m[2]!);
      if (a == null || b == null) continue;
      matches.add((
        start: m.start,
        end: m.end,
        a: _unquote(a[1]!.trim()),
        aIf: a[2]!,
        b: _unquote(b[1]!.trim()),
        bIf: b[2]!,
        forcedCable: null,
      ));
    }
    for (final m in _listedRangeConnection.allMatches(text)) {
      final devices = m[1]!
          .split(RegExp(r'\s*,\s*|\s*,?\s+and\s+'))
          .map((value) => _unquote(value.trim()))
          .where((value) => value.isNotEmpty)
          .toList();
      final switchName = _unquote(m[2]!);
      final ports = _expandPortRange(m[3]!, m[4]!);
      if (devices.isEmpty || ports.length != devices.length) continue;
      for (var i = 0; i < devices.length; i++) {
        final type =
            named[devices[i].toLowerCase()]?.type ??
            _typeFromName(devices[i]) ??
            'unknown';
        matches.add((
          start: m.start,
          end: m.end,
          a: devices[i],
          aIf: devicePort(devices[i], type),
          b: switchName,
          bIf: ports[i],
          forcedCable: straightThroughSpecified ? 'copper' : null,
        ));
      }
    }
    for (final m in _singlePortConnection.allMatches(text)) {
      if (insideEndpointRange(m.start, m.end)) continue;
      final a = _unquote(m[1]!);
      final b = _unquote(m[2]!);
      final aType = named[a.toLowerCase()]?.type ?? _typeFromName(a);
      final bType = named[b.toLowerCase()]?.type ?? _typeFromName(b);
      if (aType == null || bType == null) continue;
      matches.add((
        start: m.start,
        end: m.end,
        a: a,
        aIf: devicePort(a, aType),
        b: b,
        bIf: m[3]!,
        forcedCable: null,
      ));
    }
    for (final m in _singlePortReverseConnection.allMatches(text)) {
      if (insideEndpointRange(m.start, m.end)) continue;
      final a = _unquote(m[1]!);
      final b = _unquote(m[3]!);
      final aType = named[a.toLowerCase()]?.type ?? _typeFromName(a);
      final bType = named[b.toLowerCase()]?.type ?? _typeFromName(b);
      if (aType == null || bType == null) continue;
      matches.add((
        start: m.start,
        end: m.end,
        a: a,
        aIf: m[2]!,
        b: b,
        bIf: devicePort(b, bType),
        forcedCable: null,
      ));
    }
    for (final m in _routerPeerPort.allMatches(text)) {
      final a = _unquote(m[1]!);
      final b = _unquote(m[2]!);
      if ((_typeFromName(a) ?? named[a.toLowerCase()]?.type) != 'router' ||
          (_typeFromName(b) ?? named[b.toLowerCase()]?.type) != 'router') {
        continue;
      }
      matches.add((
        start: m.start,
        end: m.end,
        a: a,
        aIf: m[3]!,
        b: b,
        bIf: m[3]!,
        forcedCable: null,
      ));
    }
    for (final m in _rangedConnection.allMatches(text)) {
      final devices = _expandInventoryRange('${m[1]!}-${m[2]!}');
      final switchName = _unquote(m[3]!);
      final ports = _expandPortRange(m[4]!, m[5]!);
      if (devices.isEmpty || ports.length != devices.length) continue;
      for (var i = 0; i < devices.length; i++) {
        final type =
            named[devices[i].toLowerCase()]?.type ??
            _typeFromName(devices[i]) ??
            'unknown';
        matches.add((
          start: m.start,
          end: m.end,
          a: devices[i],
          aIf: devicePort(devices[i], type),
          b: switchName,
          bIf: ports[i],
          forcedCable: straightThroughSpecified ? 'copper' : null,
        ));
      }
    }
    for (final m in _siteGroupRange.allMatches(text)) {
      final site = m[1]!.toUpperCase();
      final kind = m[2]!.toLowerCase().startsWith('pc') ? 'pc' : 'phone';
      final endpoints =
          named.values
              .where(
                (binding) =>
                    binding.type == kind &&
                    binding.name.toUpperCase().contains(site),
              )
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      final ports = _expandPortRange(m[4]!, m[5]!);
      if (endpoints.isEmpty || ports.length != endpoints.length) continue;
      for (var i = 0; i < endpoints.length; i++) {
        matches.add((
          start: m.start,
          end: m.end,
          a: endpoints[i].name,
          aIf: devicePort(endpoints[i].name, kind),
          b: _unquote(m[3]!),
          bIf: ports[i],
          forcedCable: straightThroughSpecified ? 'copper' : null,
        ));
      }
    }
    for (final m in _sitePhoneLink.allMatches(text)) {
      final site = m[1]!.toUpperCase();
      final phone = named.values.where(
        (binding) =>
            binding.type == 'phone' &&
            binding.name.toUpperCase().contains(site),
      );
      if (phone.length != 1) continue;
      matches.add((
        start: m.start,
        end: m.end,
        a: phone.single.name,
        aIf: devicePort(phone.single.name, 'phone'),
        b: _unquote(m[2]!),
        bIf: m[3]!,
        forcedCable: straightThroughSpecified ? 'copper' : null,
      ));
    }
    const accessSwitchForSite = {
      'hq': 'SW-HQ-DIST',
      'east': 'SW-EAST',
      'west': 'SW-WEST',
    };
    for (final m in _siteAccessPointLink.allMatches(text)) {
      final ap = named[m[1]!.toLowerCase()];
      final switchName = accessSwitchForSite[m[2]!.toLowerCase()];
      if (ap == null || switchName == null) continue;
      matches.add((
        start: m.start,
        end: m.end,
        a: ap.name,
        aIf: devicePort(ap.name, 'wireless'),
        b: switchName,
        bIf: m[3]!,
        forcedCable: straightThroughSpecified ? 'copper' : null,
      ));
    }
    // The site-uplink shorthand names the switch endpoint exactly but omits
    // the router label and port from each pair. Expand it only when a unique
    // site router is already present in the declared inventory.
    final siteUplinks = RegExp(
      '\\bConnect\\s+each\\s+router(?:’s|\\x27s)\\s+`?($_port)`?'
      r'\s+to\s+its\s+site\s+switch\s*:\s*([^\.\n]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (siteUplinks != null) {
      final routerPort = siteUplinks[1]!;
      final sites = siteUplinks[2]!;
      final sitesOffset = siteUplinks.start + siteUplinks[0]!.indexOf(sites);
      for (final endpoint in RegExp(
        r'\b(HQ|East|West)\s+to\s+`([^`]+)`',
        caseSensitive: false,
      ).allMatches(sites)) {
        final site = endpoint[1]!.toLowerCase();
        final switchEndpoint = _combinedEndpoint.firstMatch(endpoint[2]!);
        if (switchEndpoint == null) continue;
        final routers = named.values.where(
          (binding) =>
              binding.type == 'router' &&
              binding.name.toLowerCase() == 'r-$site',
        );
        if (routers.length != 1) continue;
        matches.add((
          start: sitesOffset + endpoint.start,
          end: sitesOffset + endpoint.end,
          a: routers.single.name,
          aIf: routerPort,
          b: _unquote(switchEndpoint[1]!.trim()),
          bIf: switchEndpoint[2]!,
          forcedCable: straightThroughSpecified ? 'copper' : null,
        ));
      }
    }
    matches.sort((a, b) => a.start.compareTo(b.start));
    final uniqueMatches = <_ConnectionMention>[];
    for (final match in matches) {
      if (!uniqueMatches.any(
        (seen) =>
            seen.a.toLowerCase() == match.a.toLowerCase() &&
            seen.aIf.toLowerCase() == match.aIf.toLowerCase() &&
            seen.b.toLowerCase() == match.b.toLowerCase() &&
            seen.bIf.toLowerCase() == match.bIf.toLowerCase(),
      )) {
        uniqueMatches.add(match);
      }
    }
    matches
      ..clear()
      ..addAll(uniqueMatches);
    for (final match in RegExp(
      r'(?<![\w.-])(?:Router|Switch|Server|Laptop|Hub|Access Point|Multilayer Switch|Wireless Router|IP Phone|Analog Phone)\d+(?![\w.-])|(?<![\w.-])PC0(?![\w.-])',
      caseSensitive: false,
    ).allMatches(text)) {
      final name = match[0]!;
      if (!named.containsKey(name.toLowerCase())) {
        bind(name, _typeFromName(name) ?? 'unknown');
      }
    }
    for (final match in matches) {
      for (final name in [match.a, match.b]) {
        if (!named.containsKey(name.toLowerCase())) {
          bind(name, _typeFromName(name) ?? 'unknown');
        }
      }
    }
    final bindings = <String, _Binding>{};
    final counts = <String, int>{};
    for (final binding in named.values) {
      final index = counts.update(
        binding.type,
        (n) => n + 1,
        ifAbsent: () => 1,
      );
      bindings['${_prefixes[binding.type] ?? binding.type.toUpperCase()}$index'] =
          binding;
    }
    var planner = text;
    final modelRanges = <({int start, int end, String replacement})>[];
    for (final mention in modelMentions) {
      var start = mention.start;
      var end = mention.end;
      while (start > 0 && '\x60*_'.contains(text[start - 1])) {
        start--;
      }
      while (end < text.length && '\x60*_'.contains(text[end])) {
        end++;
      }
      // A model and its Cisco/Catalyst prefix are metadata, not device words.
      final vendor = RegExp(
        r'\b(?:Cisco|Catalyst)\s*$',
        caseSensitive: false,
      ).firstMatch(text.substring(0, start));
      if (vendor != null) start = vendor.start;
      var replacement = '';
      if (mention.device.type == 'server') {
        final tail = text.substring(mention.end);
        if (!RegExp(r'^\s+servers?\b', caseSensitive: false).hasMatch(tail)) {
          // Keep a typed server count visible to the general planner. Without
          // this, "3 Server-PT devices" became "3 devices"; the model queue
          // appended two servers only after links, addresses, and service
          // roles had already been planned for one.
          replacement =
              RegExp(r'^\s+devices?\b', caseSensitive: false).hasMatch(tail)
              ? 'servers'
              : RegExp(r'^\s+\w+\b').hasMatch(tail)
              ? 'server'
              : 'servers';
        }
      }
      modelRanges.add((start: start, end: end, replacement: replacement));
    }
    modelRanges.addAll([
      for (final mention in unsupportedInventoryModels)
        (start: mention.start, end: mention.end, replacement: ''),
    ]);
    // Replace right to left so offsets still refer to the original prompt.
    modelRanges.sort((a, b) => b.start.compareTo(a.start));
    for (final range in modelRanges) {
      planner = planner.replaceRange(range.start, range.end, range.replacement);
    }
    if (bindings.isNotEmpty) {
      final replacements = {
        for (final entry in bindings.entries)
          entry.value.name.toLowerCase(): entry.key,
      };
      final keys = replacements.keys.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      planner = planner.replaceAllMapped(
        RegExp(
          '(?<![a-z0-9_.-])(?:${keys.map(RegExp.escape).join('|')})(?![a-z0-9_.-])',
          caseSensitive: false,
        ),
        (match) => replacements[match[0]!.toLowerCase()]!,
      );
    }
    final connections = <NetLink>[];
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      var limit = text.length;
      for (var j = i + 1; j < matches.length; j++) {
        if (matches[j].start > m.start) {
          limit = matches[j].start;
          break;
        }
      }
      var end = text.indexOf(_clauseBreak, m.end);
      if (end < m.end || end > limit) end = limit;
      final instruction = text.indexOf(_instructionBreak, m.end);
      if (instruction >= 0 && instruction < end) end = instruction;
      final suffix = text.substring(m.end, end);
      final start = text.lastIndexOf(_clauseBreak, m.start);
      var prefixStart = start < 0 ? 0 : start + 1;
      if (i > 0 &&
          matches[i - 1].end > prefixStart &&
          matches[i - 1].end <= m.start) {
        prefixStart = matches[i - 1].end;
      }
      var prefix = text.substring(prefixStart, m.start);
      final intro = RegExp(
        r'\bconnect\b',
        caseSensitive: false,
      ).allMatches(prefix).lastOrNull;
      if (intro != null) prefix = prefix.substring(intro.end);
      var candidates = catalog.cablesIn(suffix);
      if (candidates.isEmpty) candidates = catalog.cablesIn(prefix);
      String? cable = m.forcedCable ?? candidates.firstOrNull?.cable.id;
      if (cable == null) {
        final unknown = RegExp(
          r'\b(?:using|with)\s+(?:an?\s+)?([a-z][a-z -]*?\s+cable)\b',
          caseSensitive: false,
        ).firstMatch(suffix);
        cable = unknown?[1];
      }
      String portName(String value) {
        return ptPortName(value)
            .replaceFirst('gigabitethernet', 'g')
            .replaceFirst('fastethernet', 'f')
            .replaceFirst('serial', 's');
      }

      var a = m.a;
      var b = m.b;
      var aIf = portName(m.aIf), bIf = portName(m.bIf);
      var aType = named[a.toLowerCase()]?.type ?? _typeFromName(a);
      var bType = named[b.toLowerCase()]?.type ?? _typeFromName(b);
      // Keep switch access links in a stable switch-first order. Endpoints
      // are bidirectional, but consistent ordering makes previews, audits,
      // and saved connection records easier to compare.
      if (bType == 'switch' && aType != 'switch' && aType != 'router') {
        final oldA = a;
        a = b;
        b = oldA;
        final oldPort = aIf;
        aIf = bIf;
        bIf = oldPort;
        final oldType = aType;
        aType = bType;
        bType = oldType;
      }
      final explicitCableRules = text.toLowerCase();
      if (aType == 'router' &&
          bType == 'router' &&
          explicitCableRules.contains('copper crossover') &&
          explicitCableRules.contains('router-to-router')) {
        cable = 'copper-cross';
      } else if ({aType, bType}.contains('switch') &&
          explicitCableRules.contains('copper straight-through') &&
          explicitCableRules.contains('device-to-switch')) {
        cable = 'copper';
      }
      if (cable == null && ptPortName(aIf).startsWith('serial')) {
        cable = 'serial';
      }
      if (cable == null &&
          {
            ptPortName(aIf),
            ptPortName(bIf),
          }.any((p) => p.startsWith('console') || p.startsWith('rs232'))) {
        cable = 'console';
      }
      if (cable == null) {
        final names = [ptPortName(aIf), ptPortName(bIf)];
        for (final entry in const {
          'usb': ['usb'],
          'coaxial': ['coaxial'],
          'phone': ['phone', 'modem'],
          'ioe': ['gpio', 'd', 'a'],
        }.entries) {
          if (names.every(
            (name) => entry.value.any(
              (prefix) => RegExp(
                '^$prefix[0-9]*'
                r'$',
              ).hasMatch(name),
            ),
          )) {
            cable = entry.key;
            break;
          }
        }
      }
      connections.add(
        NetLink(
          a: a,
          aIf: aIf,
          b: b,
          bIf: bIf,
          cable: cable,
          exactPorts: true,
          dce: cable == 'serial-dte'
              ? 'b'
              : cable?.startsWith('serial') == true
              ? 'a'
              : null,
        ),
      );
    }
    return PtBriefRequest._(
      text,
      planner,
      bindings,
      modelMentions,
      connections,
    );
  }

  NetworkIntent apply(NetworkIntent base) {
    if (_models.isEmpty && _bindings.isEmpty && connections.isEmpty) {
      return base;
    }
    final queues = <String, List<_ModelMention>>{};
    for (final mention in _models) {
      if (_bindings.values.any((b) => b.device == mention.device)) continue;
      queues
          .putIfAbsent(mention.device.type, () => [])
          .addAll(List.filled(mention.count, mention));
    }
    final labelsByType = <String, List<String>>{};
    final bindingByName = <String, _Binding>{
      for (final binding in _bindings.values)
        binding.name.toLowerCase(): binding,
    };
    void addLabel(String type, String name) {
      final labels = labelsByType.putIfAbsent(type, () => []);
      if (!labels.any((value) => value.toLowerCase() == name.toLowerCase())) {
        labels.add(name);
      }
    }

    for (final mention in _models) {
      for (final label in mention.labels) {
        addLabel(mention.device.type, label);
      }
    }
    for (final binding in _bindings.values) {
      if (binding.type == 'unknown' ||
          base.nodes.any(
            (node) => node.name.toLowerCase() == binding.name.toLowerCase(),
          )) {
        continue;
      }
      addLabel(binding.type, binding.name);
    }
    final nodes = <NetNode>[];
    final names = <String, String>{};
    final labelOffsets = <String, int>{};
    for (final node in base.nodes) {
      final directBinding =
          bindingByName[node.name.toLowerCase()] ??
          _bindings[node.name.toLowerCase()];
      String? inventoryName;
      if (directBinding == null) {
        final labels = labelsByType[node.type] ?? const <String>[];
        final offset = labelOffsets[node.type] ?? 0;
        if (offset < labels.length) {
          inventoryName = labels[offset];
          labelOffsets[node.type] = offset + 1;
        }
      }
      final binding =
          directBinding ??
          (inventoryName == null
              ? null
              : bindingByName[inventoryName.toLowerCase()] ??
                    _bindings[inventoryName.toLowerCase()]);
      final queue = queues[node.type];
      final mention = binding?.device == null && queue?.isNotEmpty == true
          ? queue!.removeAt(0)
          : null;
      final device = binding?.device ?? mention?.device;
      final modules = binding?.modules.isNotEmpty == true
          ? binding!.modules
          : mention?.modules ?? const <String>[];
      final name = binding?.name ?? inventoryName ?? node.name;
      names[node.name] = name;
      nodes.add(
        NetNode.fromJson({
          ...node.toJson(),
          'name': name,
          if (binding != null || device != null)
            'type': binding?.type ?? device!.type,
          if (binding?.model != null || device != null)
            'model': binding?.model ?? device!.model,
          if (binding?.exactModel == true || device != null) 'exactModel': true,
          if (modules.isNotEmpty) 'modules': modules,
        }),
      );
    }
    for (final binding in _bindings.values) {
      if (nodes.any(
        (n) => n.name.toLowerCase() == binding.name.toLowerCase(),
      )) {
        continue;
      }
      nodes.add(
        NetNode(
          name: binding.name,
          type: binding.type,
          model: binding.model,
          exactModel: binding.exactModel,
          modules: binding.modules,
        ),
      );
    }
    for (final entry in queues.entries) {
      for (final mention in entry.value) {
        final device = mention.device;
        var index = 1;
        final prefix = _prefixes[device.type] ?? device.type.toUpperCase();
        while (nodes.any((n) => n.name == '$prefix$index')) {
          index++;
        }
        nodes.add(
          NetNode(
            name: '$prefix$index',
            type: device.type,
            model: device.model,
            exactModel: true,
            modules: mention.modules,
          ),
        );
      }
    }
    String canonical(String name) =>
        nodes
            .where((n) => n.name.toLowerCase() == name.toLowerCase())
            .firstOrNull
            ?.name ??
        names[name] ??
        name;
    final explicit = connections
        .map(
          (l) => NetLink.fromJson({
            ...l.toJson(),
            'a': canonical(l.a),
            'b': canonical(l.b),
          }),
        )
        .toList();
    bool conflictsWithExplicit(NetLink candidate) {
      final a = canonical(candidate.a).toLowerCase();
      final b = canonical(candidate.b).toLowerCase();
      final aIf = candidate.aIf.toLowerCase();
      final bIf = candidate.bIf.toLowerCase();
      return explicit.any((link) {
        final x = link.a.toLowerCase(), y = link.b.toLowerCase();
        final xIf = link.aIf.toLowerCase(), yIf = link.bIf.toLowerCase();
        final samePair = (a == x && b == y) || (a == y && b == x);
        final reusedPort =
            (a == x && aIf == xIf) ||
            (a == y && aIf == yIf) ||
            (b == x && bIf == xIf) ||
            (b == y && bIf == yIf);
        return samePair || reusedPort;
      });
    }

    final links = [
      for (final link in base.links)
        if (!conflictsWithExplicit(link))
          NetLink.fromJson({
            ...link.toJson(),
            'a': canonical(link.a),
            'b': canonical(link.b),
          }),
      ...explicit,
    ];
    final security = base.security.toJson();
    for (final key in ['aaaServer', 'aaaRouter', 'vpnPeerA', 'vpnPeerB']) {
      if (security[key] is String) security[key] = canonical(security[key]);
    }
    final siteAddressing = _addressExplicitSitePlan(nodes, links, base.vlans);
    final expandedNodes = _applyExplicitDeviceRules(nodes, siteAddressing);
    return base.copyWith(
      nodes: expandedNodes,
      links: links,
      addressing:
          siteAddressing ??
          [
            for (final address in base.addressing)
              InterfaceAddr.fromJson({
                ...address.toJson(),
                'node': canonical(address.node),
              }),
          ],
      security: SecurityIntent.fromJson(security),
      questions: [
        ...base.questions,
        for (final n in nodes.where((n) => n.type == 'unknown'))
          'What model or device type is ${n.name}?',
      ],
    );
  }

  /// The generic planner's sample 192.168.x VLAN ranges are useful defaults,
  /// but they cannot be reused at three sites. When a brief spells out a
  /// site-specific VLAN subnet pattern, replace those defaults with the
  /// requested addressing plan instead of appending to it (which creates
  /// duplicate addresses on every router and endpoint).
  List<InterfaceAddr>? _addressExplicitSitePlan(
    List<NetNode> nodes,
    List<NetLink> links,
    List<int> plannerVlans,
  ) {
    final prefixes = <String, String>{};
    final sitePattern = RegExp(
      r'\b(HQ|East|West)\s*:\s*[`"\x27]?\s*(10\.\d{1,3})\s*\.\s*<\s*VLAN\s*>\s*\.\s*0\s*/\s*24\s*[`"\x27]?',
      caseSensitive: false,
    );
    for (final match in sitePattern.allMatches(raw)) {
      final site = match[1]!.toUpperCase();
      prefixes[site == 'EAST' ? 'EAST' : site] = match[2]!;
    }
    if (!['HQ', 'EAST', 'WEST'].every(prefixes.containsKey)) return null;

    final vlans = <int>{
      ...plannerVlans,
      for (final match in RegExp(
        r'\bVLAN\s*(\d{1,4})\b',
        caseSensitive: false,
      ).allMatches(raw))
        int.parse(match[1]!),
    }.toList()..sort();
    if (vlans.isEmpty) return null;

    String? siteOf(String name) {
      final normalized = name.toUpperCase();
      if (normalized.contains('HQ')) return 'HQ';
      if (normalized.contains('EAST')) return 'EAST';
      if (normalized.contains('WEST')) return 'WEST';
      return null;
    }

    String host(String subnet, int number) {
      final octets = subnet.split('/').first.split('.');
      final network = int.parse(octets[3]);
      final ip = (network + number) & 255;
      return '${octets[0]}.${octets[1]}.${octets[2]}.$ip/${subnet.split('/').last}';
    }

    final output = <InterfaceAddr>[];
    final usedSites = <String>{};
    // Allocate transit addresses in the same order the requested router
    // triangle appears in the prompt: HQ-East, East-West, West-HQ.
    final wanSubnets = RegExp(
      r'10\.255\.0\.(?:0|4|8)\s*/\s*30',
      caseSensitive: false,
    ).allMatches(raw).map((m) => m[0]!.replaceAll(' ', '')).toList();
    final transitLinks = links.where((link) {
      final a = nodes.where((n) => n.name == link.a).firstOrNull;
      final b = nodes.where((n) => n.name == link.b).firstOrNull;
      return link.exactPorts && a?.type == 'router' && b?.type == 'router';
    }).toList();
    if (wanSubnets.length < transitLinks.length) return null;
    for (var i = 0; i < transitLinks.length; i++) {
      final link = transitLinks[i];
      final subnet = wanSubnets[i];
      output
        ..add(
          InterfaceAddr(node: link.a, iface: link.aIf, ipCidr: host(subnet, 1)),
        )
        ..add(
          InterfaceAddr(node: link.b, iface: link.bIf, ipCidr: host(subnet, 2)),
        );
    }

    final siteRouters = <String, NetNode>{
      for (final node in nodes)
        if (node.type == 'router' && siteOf(node.name) != null)
          siteOf(node.name)!: node,
    };
    for (final site in ['HQ', 'EAST', 'WEST']) {
      final router = siteRouters[site];
      if (router == null) continue;
      final uplink = links.where((link) {
        final peerName = link.a == router.name ? link.b : link.a;
        final peer = nodes.where((n) => n.name == peerName).firstOrNull;
        return peer?.type == 'switch' && siteOf(peerName) == site;
      }).firstOrNull;
      if (uplink == null) continue;
      final routerPort = uplink.a == router.name ? uplink.aIf : uplink.bIf;
      usedSites.add(site);
      for (final vlan in vlans) {
        if (vlan == 30 && site != 'HQ') continue;
        final base = prefixes[site]!;
        output.add(
          InterfaceAddr(
            node: router.name,
            iface: '$routerPort.$vlan',
            ipCidr: '$base.$vlan.1/24',
          ),
        );
      }
    }
    if (usedSites.length != 3) return null;

    // Give each managed switch a unique SVI address in that site's VLAN 99.
    // HQ has two switches, so their host IDs differ while the router remains
    // the .1 gateway.
    for (final site in ['HQ', 'EAST', 'WEST']) {
      if (!vlans.contains(99)) continue;
      final switches =
          nodes
              .where(
                (node) => node.type == 'switch' && siteOf(node.name) == site,
              )
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      for (var i = 0; i < switches.length; i++) {
        output.add(
          InterfaceAddr(
            node: switches[i].name,
            iface: 'vlan99',
            ipCidr: '${prefixes[site]}.99.${2 + i}/24',
          ),
        );
      }
    }

    final sitePhones = <String, List<NetNode>>{};
    for (final node in nodes.where((n) => n.type == 'phone')) {
      final site = siteOf(node.name);
      if (site != null) sitePhones.putIfAbsent(site, () => []).add(node);
    }
    for (final group in sitePhones.values) {
      group.sort((a, b) => a.name.compareTo(b.name));
    }
    final phoneIndices = <String, int>{};
    for (final node in nodes) {
      // The prompt names the HQ servers as SRV-01..08 without a site suffix.
      final site = node.type == 'server' ? 'HQ' : siteOf(node.name);
      final prefix = site == null ? null : prefixes[site];
      if (site == null ||
          prefix == null ||
          node.type == 'router' ||
          node.type == 'switch') {
        continue;
      }
      if (!const {'pc', 'server', 'phone', 'printer'}.contains(node.type)) {
        continue;
      }

      final connected = links
          .where((link) => link.a == node.name || link.b == node.name)
          .firstOrNull;
      final iface = connected == null
          ? 'f0'
          : connected.a == node.name
          ? connected.aIf
          : connected.bIf;
      final suffix = RegExp(r'(\d+)$').firstMatch(node.name);
      int vlan;
      int hostNumber;
      switch (node.type) {
        case 'server':
          vlan = 30;
          hostNumber = 10 + (int.tryParse(suffix?.group(1) ?? '') ?? 1);
          break;
        case 'phone':
          vlan = 20;
          final index = phoneIndices[site] ?? 0;
          phoneIndices[site] = index + 1;
          hostNumber = 10 + index;
          break;
        default:
          vlan = 10;
          hostNumber = 9 + (int.tryParse(suffix?.group(1) ?? '') ?? 1);
          break;
      }
      if (vlan == 30 && site != 'HQ') continue;
      output.add(
        InterfaceAddr(
          node: node.name,
          iface: iface,
          ipCidr: '$prefix.$vlan.$hostNumber/24',
        ),
      );
    }
    return output;
  }

  /// Attach the explicitly requested AP/client pairing and WLAN settings to
  /// the devices that Packet Tracer serializes as wireless profiles. A named
  /// laptop is a wireless client here, never a fabricated Ethernet cable.
  List<NetNode> _applyExplicitDeviceRules(
    List<NetNode> nodes,
    List<InterfaceAddr>? siteAddressing,
  ) {
    final ssid = RegExp(
      r'\bSSID\s*[`"\x27]?([A-Za-z0-9_.-]{2,32})',
      caseSensitive: false,
    ).firstMatch(raw)?.group(1);
    final psk = RegExp(
      r'\bWPA2-PSK\s+key\s+[`"\x27]?([^`"\x27\s,]+)',
      caseSensitive: false,
    ).firstMatch(raw)?.group(1);
    final explicitRoles = raw.toLowerCase().contains('assign roles in order');
    const roleOrder = [
      'dhcp',
      'dns',
      'http',
      'email',
      'ftp',
      'ntp',
      'syslog',
      'aaa',
    ];
    String? addressOf(String name) => siteAddressing
        ?.where((address) => address.node == name)
        .map((address) => address.ipCidr.split('/').first)
        .firstOrNull;
    final dnsIp = addressOf('SRV-02');
    return [
      for (final node in nodes) ...[
        if (explicitRoles &&
            node.type == 'server' &&
            RegExp(
              r'^SRV-(01|05|06|07|08)$',
              caseSensitive: false,
            ).hasMatch(node.name))
          NetNode.fromJson({
            ...node.toJson(),
            'services': <String>{
              ...node.services,
              roleOrder[int.parse(node.name.substring(5)) - 1],
            }.toList(),
            if (node.name.toUpperCase() == 'SRV-01' && siteAddressing != null)
              'serviceRules': {
                ...node.serviceRules,
                'dhcp': {
                  'pools': [
                    for (final address in siteAddressing)
                      if (address.iface.contains('.') &&
                          RegExp(r'\.(10|20|40)$').hasMatch(address.iface))
                        {
                          'poolName':
                              '${address.node}_${address.iface.split('.').last}',
                          'gateway': address.ipCidr.split('/').first,
                          'dnsServer': dnsIp ?? '10.10.30.12',
                          'startIp':
                              '${address.ipCidr.split('/').first.split('.').take(3).join('.')}.50',
                          'mask': '255.255.255.0',
                          'maxUsers': '100',
                        },
                  ],
                },
              },
          })
        else if (explicitRoles &&
            node.type == 'server' &&
            node.name.toUpperCase() == 'SRV-02')
          NetNode.fromJson({
            ...node.toJson(),
            'services': <String>{...node.services, 'dns'}.toList(),
            'serviceRules': {
              ...node.serviceRules,
              'dns': {
                'records': [
                  {
                    'name': 'intranet.lab',
                    'address': addressOf('SRV-03') ?? '10.10.30.13',
                  },
                  {
                    'name': 'mail.lab',
                    'address': addressOf('SRV-04') ?? '10.10.30.14',
                  },
                ],
              },
            },
          })
        else if (explicitRoles &&
            node.type == 'server' &&
            node.name.toUpperCase() == 'SRV-04')
          NetNode.fromJson({
            ...node.toJson(),
            'services': <String>{...node.services, 'email'}.toList(),
            'serviceRules': {
              ...node.serviceRules,
              'email': {
                ...Map<String, dynamic>.from(
                  (node.serviceRules['email'] as Map?) ?? const {},
                ),
                'domain': 'lab',
              },
            },
          })
        else if (explicitRoles &&
            node.type == 'server' &&
            node.name.toUpperCase() == 'SRV-03')
          NetNode.fromJson({
            ...node.toJson(),
            'services': <String>{...node.services, 'http'}.toList(),
          })
        else if (explicitRoles &&
            node.type == 'server' &&
            RegExp(r'^SRV-0[5-8]$', caseSensitive: false).hasMatch(node.name))
          NetNode.fromJson({
            ...node.toJson(),
            'services': <String>{
              ...node.services,
              roleOrder[int.parse(node.name.substring(5)) - 1],
            }.toList(),
          })
        else if (ssid != null &&
            psk != null &&
            (node.type == 'wireless' || node.type == 'laptop'))
          NetNode.fromJson({
            ...node.toJson(),
            'serviceRules': {
              ...node.serviceRules,
              'wireless': {
                'ssid': ssid,
                'wpa2': true,
                'psk': psk,
                'vlan': 40,
                if (node.type == 'wireless') 'mode': 'access-point',
                if (node.type == 'laptop') 'mode': 'client',
                if (node.type == 'laptop')
                  'associatedAp': node.name.toUpperCase().contains('EAST')
                      ? 'AP-EAST'
                      : 'AP-HQ',
              },
            },
          })
        else
          node,
      ],
    ];
  }
}
