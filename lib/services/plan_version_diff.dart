import 'dart:convert';

import '../models/network_intent.dart';

/// What changed between two versions of one project.
///
/// Pure and value-shaped on purpose: the home screen shows it in a dialog,
/// the chat can quote it, and the tests can assert on the STRUCTURE rather
/// than on rendered prose. Device/link/address/routing/VLAN/service deltas
/// only - secret fields are read through `includeSecrets: false` copies, so
/// a diff can never print a password.
class PlanVersionDiff {
  final String projectBefore;
  final String projectAfter;
  final List<String> devicesAdded;
  final List<String> devicesRemoved;
  final List<String> deviceChanges;
  final List<String> cablesAdded;
  final List<String> cablesRemoved;
  final List<String> addressChanges;
  final String? routingBefore;
  final String? routingAfter;
  final List<String> vlansBefore;
  final List<String> vlansAfter;
  final List<String> serviceChanges;
  final List<String> securityChanges;

  const PlanVersionDiff({
    required this.projectBefore,
    required this.projectAfter,
    this.devicesAdded = const [],
    this.devicesRemoved = const [],
    this.deviceChanges = const [],
    this.cablesAdded = const [],
    this.cablesRemoved = const [],
    this.addressChanges = const [],
    this.routingBefore,
    this.routingAfter,
    this.vlansBefore = const [],
    this.vlansAfter = const [],
    this.serviceChanges = const [],
    this.securityChanges = const [],
  });

  bool get isEmpty =>
      devicesAdded.isEmpty &&
      devicesRemoved.isEmpty &&
      deviceChanges.isEmpty &&
      cablesAdded.isEmpty &&
      cablesRemoved.isEmpty &&
      addressChanges.isEmpty &&
      routingBefore == routingAfter &&
      _sameList(vlansBefore, vlansAfter) &&
      serviceChanges.isEmpty &&
      securityChanges.isEmpty;

  static bool _sameList(List<String> a, List<String> b) {
    final x = [...a]..sort();
    final y = [...b]..sort();
    return x.join('|') == y.join('|');
  }

  static PlanVersionDiff compare(NetworkIntent before, NetworkIntent after) {
    final oldNodes = {for (final n in before.nodes) n.name: n};
    final newNodes = {for (final n in after.nodes) n.name: n};
    final devicesAdded = <String>[];
    final devicesRemoved = <String>[];
    final deviceChanges = <String>[];
    for (final name in ({
      ...oldNodes.keys,
      ...newNodes.keys,
    }).toList()..sort()) {
      final oldNode = oldNodes[name];
      final newNode = newNodes[name];
      if (oldNode == null) {
        devicesAdded.add(name);
      } else if (newNode == null) {
        devicesRemoved.add(name);
      } else {
        final oldJson = oldNode.toJson(includeSecrets: false);
        final newJson = newNode.toJson(includeSecrets: false);
        for (final field in ({
          ...oldJson.keys,
          ...newJson.keys,
        }).toList()..sort()) {
          if (jsonEncode(oldJson[field]) != jsonEncode(newJson[field])) {
            deviceChanges.add(
              '$name $field: ${jsonEncode(oldJson[field] ?? 'unset')} -> '
              '${jsonEncode(newJson[field] ?? 'unset')}',
            );
          }
        }
      }
    }

    String linkKey(NetLink link) {
      final ends = ['${link.a}:${link.aIf}', '${link.b}:${link.bIf}']..sort();
      return '${ends[0]} <-> ${ends[1]}';
    }

    final oldLinks = before.links.map(linkKey).toSet();
    final newLinks = after.links.map(linkKey).toSet();

    String addrKey(InterfaceAddr a) => '${a.node}/${a.iface}';
    String addrValue(InterfaceAddr a) =>
        '${a.ipCidr}${a.ip6Cidr == null ? '' : ' / ${a.ip6Cidr}'}';
    final oldAddresses = {for (final a in before.addressing) addrKey(a): a};
    final newAddresses = {for (final a in after.addressing) addrKey(a): a};
    final addressChanges = <String>[];
    for (final key in ({
      ...oldAddresses.keys,
      ...newAddresses.keys,
    }).toList()..sort()) {
      final was = oldAddresses[key];
      final now = newAddresses[key];
      if (was == null) {
        addressChanges.add('$key: added ${addrValue(now!)}');
      } else if (now == null) {
        addressChanges.add('$key: removed (was ${addrValue(was)})');
      } else if (addrValue(was) != addrValue(now)) {
        addressChanges.add('$key: ${addrValue(was)} -> ${addrValue(now)}');
      }
    }

    final serviceChanges = <String>[];
    String rolesOf(NetworkIntent p) => [
      for (final n in p.nodes)
        for (final s in n.services) '${n.name}:$s',
    ].join(', ');
    if (rolesOf(before) != rolesOf(after)) {
      serviceChanges.add(
        'service roles: ${rolesOf(before)} -> ${rolesOf(after)}',
      );
    }

    final securityChanges = <String>[];
    final oldSecurity = before.security.toJson(includeSecrets: false);
    final newSecurity = after.security.toJson(includeSecrets: false);
    for (final field in ({
      ...oldSecurity.keys,
      ...newSecurity.keys,
    }).toList()..sort()) {
      if (jsonEncode(oldSecurity[field]) != jsonEncode(newSecurity[field])) {
        securityChanges.add(
          '$field: ${jsonEncode(oldSecurity[field] ?? 'unset')} -> '
          '${jsonEncode(newSecurity[field] ?? 'unset')}',
        );
      }
    }

    return PlanVersionDiff(
      projectBefore: before.projectName,
      projectAfter: after.projectName,
      devicesAdded: devicesAdded,
      devicesRemoved: devicesRemoved,
      deviceChanges: deviceChanges,
      cablesAdded: newLinks.difference(oldLinks).toList()..sort(),
      cablesRemoved: oldLinks.difference(newLinks).toList()..sort(),
      addressChanges: addressChanges,
      routingBefore: before.routing,
      routingAfter: after.routing,
      vlansBefore: before.vlans.map((v) => '$v').toList(),
      vlansAfter: after.vlans.map((v) => '$v').toList(),
      serviceChanges: serviceChanges,
      securityChanges: securityChanges,
    );
  }

  /// Markdown for a dialog or a report.
  String toMarkdown() {
    if (isEmpty) return 'The two versions carry the same network.';
    final b = StringBuffer();
    void section(String title, List<String> lines) {
      if (lines.isEmpty) return;
      b
        ..writeln('**$title**')
        ..writeln();
      for (final line in lines) {
        b.writeln('- $line');
      }
      b.writeln();
    }

    if (projectBefore != projectAfter) {
      b.writeln('Project renamed: $projectBefore -> $projectAfter');
      b.writeln();
    }
    if (routingBefore != routingAfter) {
      b.writeln('Routing: $routingBefore -> $routingAfter');
      b.writeln();
    }
    if (!_sameList(vlansBefore, vlansAfter)) {
      b.writeln('VLANs: ${vlansBefore.join(', ')} -> ${vlansAfter.join(', ')}');
      b.writeln();
    }
    section('Devices added', devicesAdded.map((d) => '`$d`').toList());
    section('Devices removed', devicesRemoved.map((d) => '`$d`').toList());
    section('Device settings changed', deviceChanges);
    section('Cables added', cablesAdded);
    section('Cables removed', cablesRemoved);
    section('Addresses changed', addressChanges);
    section('Services changed', serviceChanges);
    section('Security changed', securityChanges);
    return b.toString().trimRight();
  }
}
