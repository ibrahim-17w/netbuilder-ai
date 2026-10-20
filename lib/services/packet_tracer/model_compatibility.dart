import '../../models/network_intent.dart';
import 'catalog.dart';

/// A requested exact model that this app can identify but cannot serialize
/// into a Packet Tracer file.
class UnsupportedPacketTracerModel {
  final String type;
  final String model;
  final List<String> deviceNames;

  const UnsupportedPacketTracerModel({
    required this.type,
    required this.model,
    required this.deviceNames,
  });

  int get count => deviceNames.length;
}

/// Shared preflight and explicit model-selection logic for chat and builds.
class PacketTracerModelCompatibility {
  static final _catalog = PacketTracerCatalog.instance;

  static List<UnsupportedPacketTracerModel> unsupportedExactModels(
    NetworkIntent? plan,
  ) {
    if (plan == null) return const [];
    final groups =
        <String, ({String type, String model, List<String> names})>{};
    for (final node in plan.nodes) {
      if (!node.exactModel) continue;
      final device = _catalog.device(node.model ?? '');
      if (device != null && device.placeable) continue;
      final model = (node.model ?? '').trim();
      final key = '${node.type.toLowerCase()}|${model.toLowerCase()}';
      final current = groups[key];
      if (current == null) {
        groups[key] = (type: node.type, model: model, names: [node.name]);
      } else {
        current.names.add(node.name);
      }
    }
    return [
      for (final group in groups.values)
        UnsupportedPacketTracerModel(
          type: group.type,
          model: group.model,
          deviceNames: List.unmodifiable(group.names),
        ),
    ];
  }

  static List<String> compatibleModels(UnsupportedPacketTracerModel group) =>
      _catalog.devices
          .where((device) => device.type == group.type && device.placeable)
          .map((device) => device.model)
          .toList();

  static String question(UnsupportedPacketTracerModel group) {
    final examples = group.deviceNames.take(5).join(', ');
    final remainder = group.count > 5 ? ', and ${group.count - 5} more' : '';
    final choices = compatibleModels(group);
    final options = choices.isEmpty
        ? 'There is no compatible ${group.type} template in this app yet.'
        : 'Available compatible models: ${choices.map((value) => '`$value`').join(', ')}.';
    return 'Before I show network designs, I checked the exact requested model. '
        '`${group.model}` is not buildable by this app for ${group.count} '
        '${group.type} device(s) ($examples$remainder). $options Which model '
        'should I use for all ${group.count}? The device count and names stay '
        'as requested; I have not substituted, removed, or added devices.';
  }

  static String? selectedCompatibleModel(
    String text,
    UnsupportedPacketTracerModel group,
  ) {
    final trimmed = text.trim();
    final modelOnly = RegExp(r'^[A-Za-z0-9-]+$').hasMatch(trimmed);
    for (final model in compatibleModels(group)) {
      if (RegExp(
        '(?<![A-Za-z0-9])${RegExp.escape(model)}(?![A-Za-z0-9])',
        caseSensitive: false,
      ).hasMatch(trimmed)) {
        if (modelOnly ||
            RegExp(
              r'\b(use|choose|replace|change|switch|make|set)\b',
              caseSensitive: false,
            ).hasMatch(trimmed)) {
          return model;
        }
      }
    }
    return null;
  }

  static NetworkIntent applyChoice(
    NetworkIntent plan,
    UnsupportedPacketTracerModel group,
    String model,
  ) {
    final compatible = compatibleModels(group);
    if (!compatible.any(
      (candidate) => candidate.toLowerCase() == model.toLowerCase(),
    )) {
      throw ArgumentError.value(
        model,
        'model',
        'No buildable compatible model',
      );
    }
    final names = group.deviceNames.map((name) => name.toLowerCase()).toSet();
    return plan.copyWith(
      nodes: [
        for (final node in plan.nodes)
          if (names.contains(node.name.toLowerCase()))
            NetNode.fromJson({
              ...node.toJson(),
              'model': model,
              'exactModel': true,
            })
          else
            node,
      ],
    );
  }
}
