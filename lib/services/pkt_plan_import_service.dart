import 'dart:convert';
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/network_intent.dart';
import 'network_math.dart';
import 'packet_tracer/catalog.dart';
import 'pkt/pkt_codec.dart';
import 'pkt/seed_library.dart';

/// A structure-level conversion from a Packet Tracer save to the app's plan.
///
/// The source file is never modified. The converted plan keeps recognized
/// devices, model names, cable endpoints, and IOS interface addresses. Device
/// GUI settings, scenario state, and unrecognized metadata may not be carried
/// into a regenerated .pkt, so callers must show the fidelity note.
class ImportedPktPlan {
  final NetworkIntent intent;
  final List<String> preservedDetails;
  final List<String> limitations;

  const ImportedPktPlan({
    required this.intent,
    this.preservedDetails = const [],
    required this.limitations,
  });
}

class PktPlanImportService {
  const PktPlanImportService._();

  static const int backgroundThresholdBytes = 256 * 1024;

  static ImportedPktPlan fromBytes(
    List<int> bytes, {
    String projectName = 'Imported network',
    void Function(String stage, double progress)? onProgress,
  }) {
    onProgress?.call('Reading the Packet Tracer save', 0.04);
    final document = utf8.decode(decryptPkt(bytes), allowMalformed: true);
    onProgress?.call('Reading devices and connections', 0.1);
    return fromXml(document, projectName: projectName, onProgress: onProgress);
  }

  @visibleForTesting
  static ImportedPktPlan fromXml(
    String document, {
    String projectName = 'Imported network',
    void Function(String stage, double progress)? onProgress,
  }) {
    final library = SeedLibrary.fromXml(document);
    if (library.devices.isEmpty) {
      throw const PktFormatError(
        'No supported Packet Tracer devices were found in this file.',
      );
    }

    final nodes = <NetNode>[];
    final refs = <String, String>{};
    final configByName = <String, List<String>>{};
    final layout = <String, Offset?>{};
    final blocks = SeedLibrary.deviceBlocksOf(document);
    var index = 0;
    final recognized = library.devices.length;
    for (final block in blocks) {
      final source = SeedLibrary.deviceFromBlock(block);
      if (source == null) continue;
      index++;
      final rawName = _unescape(source.name).trim();
      final name = rawName.isEmpty ? 'Device $index' : rawName;
      final model = source.model.trim().isEmpty
          ? source.customModel.trim()
          : source.model.trim();
      final type = _normalizedType(source.type, model);
      final modules = _installedModules(block);
      final node = NetNode(
        name: name,
        type: type,
        model: model.isEmpty ? null : model,
        // Preserve the source hardware request. A later compatibility check
        // can explain when the installed build library lacks this exact model.
        exactModel: model.isNotEmpty,
        modules: modules,
        services: _enabledServices(block),
      );
      nodes.add(node);
      final position = _logicalPosition(block);
      if (position != null) layout[name] = position;
      configByName[name] = _runningConfig(block);
      final ref = RegExp(
        r'<SAVE_REF_ID>save-ref-id:([^<]+)</SAVE_REF_ID>',
      ).firstMatch(block)?.group(1);
      if (ref != null && ref.isNotEmpty) refs[ref] = name;
      if (recognized > 0) {
        onProgress?.call(
          'Reading devices ($index of $recognized)',
          0.1 + (index / recognized) * 0.55,
        );
      }
    }

    final links = <NetLink>[];
    final linkMatches = RegExp(
      r'<LINK>.*?</LINK>',
      dotAll: true,
    ).allMatches(document).toList(growable: false);
    var linkIndex = 0;
    for (final match in linkMatches) {
      linkIndex++;
      final block = match.group(0)!;
      final fromRef =
          RegExp(
            r'<FROM>save-ref-id:([^<]+)</FROM>',
          ).firstMatch(block)?.group(1) ??
          '';
      final toRef =
          RegExp(r'<TO>save-ref-id:([^<]+)</TO>').firstMatch(block)?.group(1) ??
          '';
      final a = refs[fromRef];
      final b = refs[toRef];
      if (a == null || b == null) continue;
      final aIf = _portAfter(block, '<FROM>');
      final bIf = _portAfter(block, '<TO>');
      final typeTags = RegExp(r'<TYPE>([^<]*)</TYPE>')
          .allMatches(block)
          .map((item) => _unescape(item.group(1) ?? ''))
          .toList();
      final dce = typeTags.join(' ').toLowerCase().contains('serial')
          ? _dceEnd(a, aIf, b, bIf, configByName)
          : null;
      final cable = _cable(typeTags, dce);
      links.add(
        NetLink(
          a: a,
          aIf: aIf,
          b: b,
          bIf: bIf,
          cable: cable,
          exactPorts: aIf.isNotEmpty && bIf.isNotEmpty,
          dce: dce,
        ),
      );
      if (linkMatches.isNotEmpty) {
        onProgress?.call(
          'Reading cable endpoints ($linkIndex of ${linkMatches.length})',
          0.65 + (linkIndex / linkMatches.length) * 0.25,
        );
      }
    }

    final addressing = <InterfaceAddr>[];
    final vlans = <int>{};
    var routing = 'static';
    for (final entry in configByName.entries) {
      String? iface;
      for (final line in entry.value) {
        final clean = line.trim();
        final interface = RegExp(
          r'^interface\s+(\S+)',
          caseSensitive: false,
        ).firstMatch(clean);
        if (interface != null) {
          iface = interface.group(1);
          final vlan = RegExp(
            r'^Vlan(\d+)$',
            caseSensitive: false,
          ).firstMatch(iface ?? '');
          if (vlan != null) vlans.add(int.parse(vlan.group(1)!));
          continue;
        }
        final vlanLine = RegExp(
          r'^vlan\s+(\d+)',
          caseSensitive: false,
        ).firstMatch(clean);
        if (vlanLine != null) vlans.add(int.parse(vlanLine.group(1)!));
        final accessVlan = RegExp(
          r'^switchport\s+access\s+vlan\s+(\d+)',
          caseSensitive: false,
        ).firstMatch(clean);
        if (accessVlan != null) vlans.add(int.parse(accessVlan.group(1)!));
        final ipv4 = RegExp(
          r'^ip\s+address\s+(\d{1,3}(?:\.\d{1,3}){3})\s+(\d{1,3}(?:\.\d{1,3}){3})',
          caseSensitive: false,
        ).firstMatch(clean);
        if (ipv4 != null && iface != null) {
          final prefix = NetworkMath.prefixFromMask(ipv4.group(2)!);
          if (prefix != null) {
            addressing.add(
              InterfaceAddr(
                node: entry.key,
                iface: iface,
                ipCidr: '${ipv4.group(1)}/$prefix',
              ),
            );
          }
        }
        final ipv6 = RegExp(
          r'^ipv6\s+address\s+(\S+)',
          caseSensitive: false,
        ).firstMatch(clean);
        if (ipv6 != null && iface != null && addressing.isNotEmpty) {
          final pos = addressing.lastIndexWhere(
            (item) => item.node == entry.key && item.iface == iface,
          );
          if (pos >= 0) {
            final prior = addressing[pos];
            addressing[pos] = InterfaceAddr(
              node: prior.node,
              iface: prior.iface,
              ipCidr: prior.ipCidr,
              ip6Cidr: ipv6.group(1),
            );
          }
        }
        if (RegExp(r'^router\s+ospf\b', caseSensitive: false).hasMatch(clean)) {
          routing = 'ospf';
        } else if (RegExp(
          r'^router\s+eigrp\b',
          caseSensitive: false,
        ).hasMatch(clean)) {
          routing = 'eigrp';
        } else if (RegExp(
          r'^router\s+bgp\b',
          caseSensitive: false,
        ).hasMatch(clean)) {
          routing = 'bgp';
        }
      }
    }

    final name = projectName.trim().isEmpty
        ? 'Imported network'
        : projectName.trim();
    final intent = NetworkIntent(
      projectName: name,
      nodes: nodes,
      links: links,
      addressing: addressing,
      vlans: vlans.toList()..sort(),
      routing: routing,
      layout: layout,
      planningSource: 'packet-tracer-import',
      confidence: 0.8,
      assumptions: const [
        'This editable plan is a structural conversion of the selected Packet Tracer save.',
        'The original .pkt remains unchanged; generated copies may omit settings the editor cannot represent.',
      ],
    );
    return ImportedPktPlan(
      intent: intent,
      preservedDetails: [
        'Device names and exact model names for ${nodes.length} recognized devices.',
        'Installed hardware modules and saved canvas positions where present.',
        'Cable type, exact port endpoints, serial clock side, and IOS IPv4/IPv6 addresses where saved.',
        'Recognized VLAN IDs, routing protocol, and enabled server-service roles.',
      ],
      limitations: const [
        'Service-pool records, account contents, and per-device GUI settings are summarized only when the editable plan has a matching field.',
        'Simulation scenarios, event lists, and unknown Packet Tracer save metadata are not editable in this plan.',
        'The original .pkt stays untouched. A new build is a separate file; review the retained and unsupported details before replacing any save.',
      ],
    );
  }

  /// Parse large saves away from the UI isolate. The worker reports coarse
  /// progress while decrypting and walking devices/cables, and the caller can
  /// cancel without waiting for a large file to finish.
  static Future<ImportedPktPlan> fromBytesInBackground(
    List<int> bytes, {
    String projectName = 'Imported network',
    void Function(String stage, double progress)? onProgress,
    PktPlanImportTask? task,
    @visibleForTesting bool forceIsolate = false,
  }) async {
    if (!forceIsolate && bytes.length < backgroundThresholdBytes) {
      onProgress?.call('Reading the Packet Tracer save', 0.04);
      await Future<void>.delayed(Duration.zero);
      task?.throwIfCancelled();
      final result = fromBytes(
        bytes,
        projectName: projectName,
        onProgress: onProgress,
      );
      task?.throwIfCancelled();
      return result;
    }
    final worker = task ?? PktPlanImportTask();
    return worker.run(bytes, projectName: projectName, onProgress: onProgress);
  }

  static List<String> _installedModules(String block) {
    final modules = <String>[];
    for (final slot in RegExp(
      r'<SLOT>.*?</SLOT>',
      dotAll: true,
    ).allMatches(block)) {
      for (final model in RegExp(
        r'<MODEL>\s*([^<\s]+)\s*</MODEL>',
      ).allMatches(slot.group(0)!)) {
        final value = _unescape(model.group(1) ?? '').trim();
        if (value.isNotEmpty && !modules.contains(value)) modules.add(value);
      }
    }
    return modules;
  }

  static Offset? _logicalPosition(String block) {
    final logical = RegExp(
      r'<LOGICAL>(.*?)</LOGICAL>',
      dotAll: true,
    ).firstMatch(block)?.group(1);
    if (logical == null) return null;
    final x = double.tryParse(
      RegExp(r'<X>\s*(-?\d+(?:\.\d+)?)\s*</X>').firstMatch(logical)?.group(1) ??
          '',
    );
    final y = double.tryParse(
      RegExp(r'<Y>\s*(-?\d+(?:\.\d+)?)\s*</Y>').firstMatch(logical)?.group(1) ??
          '',
    );
    if (x == null || y == null || !x.isFinite || !y.isFinite) return null;
    return Offset(x, y);
  }

  static String _normalizedType(String sourceType, String model) {
    final catalog = PacketTracerCatalog.instance;
    final recognized = catalog.device(model);
    if (recognized != null && recognized.type.isNotEmpty) {
      return recognized.type;
    }
    final type = sourceType.trim().toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '',
    );
    final fallback = sourceType
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return switch (type) {
      'router' => 'router',
      'switch' || 'multilayerswitch' => 'switch',
      'pc' || 'desktop' || 'desktopcomputer' => 'pc',
      'server' => 'server',
      'firewall' || 'asa' => 'firewall',
      'accesspoint' || 'wirelessaccesspoint' => 'wireless',
      'wirelessrouter' => 'wireless-router',
      'wirelesscontroller' || 'wlc' => 'wlc',
      'phone' || 'ipphone' => 'phone',
      'laptop' => 'laptop',
      'printer' => 'printer',
      'cloud' => 'cloud',
      'modem' || 'cablemodem' || 'dslmodem' => 'modem',
      'hub' => 'hub',
      'bridge' => 'bridge',
      'tablet' => 'tablet',
      'smartphone' || 'mobilephone' => 'smartphone',
      'tv' || 'smarttv' => 'tv',
      'homegateway' || 'iotgateway' => 'iot',
      _ => fallback.isEmpty ? 'unknown' : fallback,
    };
  }

  static List<String> _runningConfig(String block) {
    final section = RegExp(
      r'<RUNNINGCONFIG(?:\s[^>]*)?>(.*?)</RUNNINGCONFIG>',
      dotAll: true,
    ).firstMatch(block)?.group(1);
    if (section == null) return const [];
    return [
      for (final line in RegExp(
        r'<LINE>(.*?)</LINE>',
        dotAll: true,
      ).allMatches(section))
        _unescape(line.group(1) ?? ''),
    ];
  }

  static List<String> _enabledServices(String block) {
    final enabled = <String>[];
    void check(String name, String pattern) {
      if (RegExp(pattern).hasMatch(block)) {
        enabled.add(name);
      }
    }

    check('dhcp', r'<DHCP_SERVER>\s*<ENABLED>1');
    check('dns', r'<DNS_SERVER><ENABLED>1');
    check('http', r'<HTTP_SERVER><ENABLED>1');
    check('https', r'<HTTPSENABLED>1');
    check('aaa', r'<ACS_SERVER><ENABLED>1');
    check('ftp', r'<FTP_SERVER><ENABLED>1');
    check('email', r'<SMTP_ENABLED>1');
    check('syslog', r'<SYSLOG_SERVER><ENABLED>1');
    check('ntp', r'<NTP_SERVER><ENABLED>1');
    check('tftp', r'<TFTP_SERVER><ENABLED>1');
    return enabled;
  }

  static String _portAfter(String block, String marker) {
    final at = block.indexOf(marker);
    if (at < 0) {
      return '';
    }
    return RegExp(
          r'<PORT>([^<]*)</PORT>',
        ).firstMatch(block.substring(at))?.group(1) ??
        '';
  }

  static String? _dceEnd(
    String a,
    String aIf,
    String b,
    String bIf,
    Map<String, List<String>> configByName,
  ) {
    bool hasClock(String name, String iface) {
      var active = false;
      for (final line in configByName[name] ?? const <String>[]) {
        final interface = RegExp(
          r'^interface\s+(\S+)',
          caseSensitive: false,
        ).firstMatch(line.trim());
        if (interface != null) {
          active = interface.group(1)!.toLowerCase() == iface.toLowerCase();
        }
        if (active &&
            RegExp(
              r'^clock\s+rate\b',
              caseSensitive: false,
            ).hasMatch(line.trim())) {
          return true;
        }
      }
      return false;
    }

    if (hasClock(a, aIf)) {
      return 'a';
    }
    if (hasClock(b, bIf)) {
      return 'b';
    }
    return null;
  }

  static String _cable(List<String> tags, String? dce) {
    final joined = tags.join(' ').toLowerCase();
    if (joined.contains('console')) {
      return 'console';
    }
    if (joined.contains('serial')) {
      return dce == 'a'
          ? 'serial-dce'
          : dce == 'b'
          ? 'serial-dte'
          : 'serial';
    }
    if (joined.contains('fiber')) {
      if (joined.contains('single')) {
        return 'fiber-single';
      }
      if (joined.contains('multi')) {
        return 'fiber-multi';
      }
      return 'fiber';
    }
    if (joined.contains('coax')) {
      return 'coaxial';
    }
    if (joined.contains('phone')) {
      return 'phone';
    }
    if (joined.contains('usb')) {
      return 'usb';
    }
    if (joined.contains('octal')) {
      return 'octal';
    }
    if (joined.contains('ioe')) {
      return 'ioe';
    }
    if (joined.contains('copper')) {
      return joined.contains('cross') ? 'copper-cross' : 'copper';
    }
    if (tags.isEmpty) {
      return 'copper';
    }
    return tags.last;
  }

  static String _unescape(String value) => value
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}

/// One cancellable background import. A task instance is single-use.
class PktPlanImportTask {
  final ReceivePort _messages = ReceivePort();
  final ReceivePort _exit = ReceivePort();
  final Completer<ImportedPktPlan> _result = Completer<ImportedPktPlan>();
  StreamSubscription<Object?>? _messageSubscription;
  StreamSubscription<Object?>? _exitSubscription;
  Isolate? _isolate;
  void Function(String stage, double progress)? _onProgress;
  bool _finished = false;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  Future<ImportedPktPlan> run(
    List<int> bytes, {
    required String projectName,
    void Function(String stage, double progress)? onProgress,
  }) async {
    if (_isolate != null || _finished || _cancelled) {
      throw StateError('A Packet Tracer import task can only run once.');
    }
    _onProgress = onProgress;
    onProgress?.call('Preparing a background import', 0.02);
    _messageSubscription = _messages.listen(_handleMessage);
    _exitSubscription = _exit.listen((_) {
      if (!_finished && !_cancelled) {
        _completeError(StateError('The background import stopped early.'));
      }
    });
    try {
      final transfer = TransferableTypedData.fromList([
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      ]);
      _isolate = await Isolate.spawn<List<Object?>>(
        _pktPlanImportWorker,
        <Object?>[transfer, projectName, _messages.sendPort],
        onExit: _exit.sendPort,
        errorsAreFatal: true,
      );
    } catch (error) {
      _completeError(error);
    }
    return _result.future;
  }

  void _handleMessage(Object? message) {
    if (message is! Map || _finished || _cancelled) return;
    final map = Map<String, dynamic>.from(message);
    final stage = map['stage'];
    if (stage is String) {
      final progress = (map['progress'] as num?)?.toDouble() ?? 0;
      _onProgress?.call(stage, progress.clamp(0, 1).toDouble());
      return;
    }
    if (map['error'] is String) {
      _completeError(StateError(map['error'] as String));
      return;
    }
    final rawIntent = map['intent'];
    if (rawIntent is String) {
      try {
        final decoded = jsonDecode(rawIntent);
        if (decoded is! Map) throw const FormatException('Invalid plan.');
        _finished = true;
        _result.complete(
          ImportedPktPlan(
            intent: NetworkIntent.fromJson(Map<String, dynamic>.from(decoded)),
            preservedDetails: List<String>.from(
              map['preservedDetails'] as List? ?? const [],
            ),
            limitations: List<String>.from(
              map['limitations'] as List? ?? const [],
            ),
          ),
        );
        _close();
      } catch (error) {
        _completeError(error);
      }
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const PktPlanImportCancelled();
  }

  void cancel() {
    if (_finished || _cancelled) return;
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    if (!_result.isCompleted) {
      _result.completeError(const PktPlanImportCancelled());
    }
    _close();
  }

  void _completeError(Object error) {
    if (_finished || _cancelled) return;
    _finished = true;
    if (!_result.isCompleted) _result.completeError(error);
    _isolate?.kill(priority: Isolate.immediate);
    _close();
  }

  void _close() {
    _messageSubscription?.cancel();
    _exitSubscription?.cancel();
    _messages.close();
    _exit.close();
    _isolate = null;
  }
}

class PktPlanImportCancelled implements Exception {
  const PktPlanImportCancelled();
  @override
  String toString() => 'Import cancelled.';
}

void _pktPlanImportWorker(List<Object?> arguments) {
  final transfer = arguments[0] as TransferableTypedData;
  final projectName = arguments[1] as String;
  final send = arguments[2] as SendPort;
  try {
    send.send({'stage': 'Decrypting the Packet Tracer save', 'progress': 0.05});
    final bytes = transfer.materialize().asUint8List();
    final imported = PktPlanImportService.fromBytes(
      bytes,
      projectName: projectName,
      onProgress: (stage, progress) =>
          send.send({'stage': stage, 'progress': progress}),
    );
    send.send({
      'intent': jsonEncode(imported.intent.toJson(includeSecrets: false)),
      'preservedDetails': imported.preservedDetails,
      'limitations': imported.limitations,
    });
  } catch (error) {
    send.send({'error': error.toString()});
  }
}
