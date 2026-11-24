import '../../models/network_intent.dart';
import 'catalog.dart';

/// Resolves a named endpoint without silently choosing the first device.
class EndpointReference {
  const EndpointReference._();

  static ({NetNode? node, bool ambiguous}) resolve(
    String reference,
    Iterable<NetNode> nodes,
  ) {
    final name = reference.trim();
    final inventory = nodes.toList();
    final exact = inventory
        .where((node) => node.name.toLowerCase() == name.toLowerCase())
        .toList();
    if (exact.isNotEmpty) {
      return (
        node: exact.length == 1 ? exact.single : null,
        ambiguous: exact.length > 1,
      );
    }
    final phrase = name.replaceFirst(
      RegExp(r'^the\s+', caseSensitive: false),
      '',
    );
    final device = PacketTracerCatalog.instance.device(phrase);
    final kind = device?.type ?? phrase.toLowerCase();
    final candidates = inventory.where((node) {
      if (node.type.toLowerCase() != kind.toLowerCase()) return false;
      return device == null ||
          ptIdentity(node.model ?? '') == ptIdentity(device.model);
    }).toList();
    return (
      node: candidates.length == 1 ? candidates.single : null,
      ambiguous: candidates.length > 1,
    );
  }
}
