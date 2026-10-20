import '../../models/network_intent.dart';
import 'catalog.dart';

class PtHardwareIssue {
  final String message;
  final bool blocking;
  const PtHardwareIssue(this.message, {this.blocking = true});
}

/// Hardware checks use the same versioned catalog as recognition and selection.
class PtHardwareCheck {
  static List<PtHardwareIssue> inspect(NetworkIntent intent) {
    final catalog = PacketTracerCatalog.instance;
    final issues = <PtHardwareIssue>[];
    final byName = {for (final n in intent.nodes) n.name: n};
    final variants = <String, List<PtHardwareVariant>>{};
    final unsupportedModels =
        <String, ({String type, String model, List<String> names})>{};
    for (final node in intent.nodes) {
      if (node.type == 'unknown') {
        issues.add(
          PtHardwareIssue('Choose a device type or model for ${node.name}.'),
        );
      }
      final device = catalog.device(node.model ?? '');
      if (!node.exactModel && node.modules.isEmpty) continue;
      if (device == null || !device.placeable) {
        final model = (node.model ?? '').trim();
        final key = '${node.type.toLowerCase()}|${model.toLowerCase()}';
        final current = unsupportedModels[key];
        if (current == null) {
          unsupportedModels[key] = (
            type: node.type,
            model: model,
            names: [node.name],
          );
        } else {
          current.names.add(node.name);
        }
        continue;
      }
      final exactLinks = intent.links.where(
        (l) => l.exactPorts && (l.a == node.name || l.b == node.name),
      );
      final ports = {
        for (final l in exactLinks)
          ptPortName(l.a == node.name ? l.aIf : l.bIf),
      };
      final fitting = device.variants
          .where(
            (v) =>
                node.modules.every(
                  (m) => v.modules.any((x) => ptIdentity(x) == ptIdentity(m)),
                ) &&
                ports.every((p) => v.ports.any((x) => ptPortName(x.name) == p)),
          )
          .toList();
      variants[node.name] = fitting;
      if (fitting.isEmpty) {
        issues.add(
          PtHardwareIssue(
            '${node.name}: no ${device.model} variant has all requested ports and modules. Available variants: ${device.variants.map((v) => v.key).join(', ')}.',
          ),
        );
      }
    }
    for (final unsupported in unsupportedModels.values) {
      final examples = unsupported.names.take(4).join(', ');
      final rest = unsupported.names.length > 4
          ? ', plus ${unsupported.names.length - 4} more'
          : '';
      final model = unsupported.model.isEmpty
          ? 'an unspecified model'
          : '`${unsupported.model}`';
      issues.add(
        PtHardwareIssue(
          '${unsupported.names.length} ${unsupported.type} device(s) use '
          '$model, which has no buildable template in this library '
          '(for example $examples$rest). Choose a supported model or remove '
          'those devices.',
        ),
      );
    }
    final occupied = <String>{};
    for (final link in intent.links) {
      final cable = catalog.cable(
        link.cable ?? (link.isSerial ? 'serial' : 'copper'),
      );
      if (cable == null) {
        issues.add(
          PtHardwareIssue(
            'Unknown cable "${link.cable}" between ${link.a} and ${link.b}. Select a catalog cable.',
          ),
        );
        continue;
      }
      if (!cable.templateAvailable) {
        issues.add(
          PtHardwareIssue(
            '${cable.label} is understood, but this library cannot save it. Use Packet Tracer on desktop for this connection.',
            blocking: link.exactPorts,
          ),
        );
      }
      for (final side in ['a', 'b']) {
        final name = side == 'a' ? link.a : link.b;
        final port = side == 'a' ? link.aIf : link.bIf;
        final key = '$name:${ptPortName(port)}';
        if (!occupied.add(key)) {
          issues.add(
            PtHardwareIssue(
              '$name $port already carries another cable. Select a free port.',
            ),
          );
        }
      }
      final aVariants =
          variants[link.a] ??
          catalog.device(byName[link.a]?.model ?? '')?.variants ??
          const [];
      final bVariants =
          variants[link.b] ??
          catalog.device(byName[link.b]?.model ?? '')?.variants ??
          const [];
      String? mismatch;
      var matched = false;
      for (final av in aVariants) {
        final a = av.ports
            .where((p) => ptPortName(p.name) == ptPortName(link.aIf))
            .firstOrNull;
        if (a == null) continue;
        for (final bv in bVariants) {
          final b = bv.ports
              .where((p) => ptPortName(p.name) == ptPortName(link.bIf))
              .firstOrNull;
          if (b == null) continue;
          final result = cable.mismatch(
            a,
            b,
            modulesA: av.modules,
            modulesB: bv.modules,
          );
          if (result == null) {
            matched = true;
            break;
          }
          mismatch = result;
        }
        if (matched) break;
      }
      if (!matched && mismatch != null) {
        issues.add(PtHardwareIssue('${link.a}–${link.b}: $mismatch'));
      }
    }
    return issues;
  }
}
