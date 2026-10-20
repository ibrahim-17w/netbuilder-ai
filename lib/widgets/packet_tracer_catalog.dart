import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/packet_tracer/catalog.dart';
import '../services/settings_service.dart';

class PtDeviceChoice {
  final PtDevice device;
  final PtHardwareVariant variant;
  const PtDeviceChoice(this.device, this.variant);
}

class PacketTracerCatalogSheet extends StatefulWidget {
  final bool selectDevice;
  const PacketTracerCatalogSheet({super.key, this.selectDevice = false});
  static Future<PtDeviceChoice?> show(
    BuildContext context, {
    bool selectDevice = false,
  }) => showModalBottomSheet<PtDeviceChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: PacketTracerCatalogSheet(selectDevice: selectDevice),
    ),
  );
  @override
  State<PacketTracerCatalogSheet> createState() =>
      _PacketTracerCatalogSheetState();
}

class _PacketTracerCatalogSheetState extends State<PacketTracerCatalogSheet> {
  String _query = '';
  String? _category;
  bool _available = false;
  bool _cables = false;
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String get _installedVersion {
    try {
      return context.read<SettingsService>().packetTracerVersion;
    } catch (_) {
      return '';
    }
  }

  Future<void> _details(PtDevice device) async {
    var selected = 0;
    final compatibility = PacketTracerCatalog.instance.compatibility(
      device.model,
      installedVersion: _installedVersion,
    );
    final result = await showDialog<PtDeviceChoice>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text(device.model),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(device.kind),
                  const SizedBox(height: 12),
                  Text(
                    '${compatibility.recognitionLabel} · ${compatibility.buildLabel}',
                  ),
                  const SizedBox(height: 8),
                  Text('Verification: ${compatibility.verifyLabel}'),
                  const SizedBox(height: 6),
                  Text(compatibility.versionNote),
                  if (device.variants.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: selected,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Hardware / modules',
                      ),
                      items: [
                        for (var i = 0; i < device.variants.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              device.variants[i].modules.isEmpty
                                  ? 'Built-in hardware'
                                  : device.variants[i].modules.join(' + '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) =>
                          refresh(() => selected = value ?? 0),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${device.variants[selected].ports.length} named ports',
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final port in device.variants[selected].ports)
                          Chip(
                            label: Text(port.name),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    if (device.variants[selected].ports.isEmpty)
                      const Text(
                        'No usable connector names are available for this hardware.',
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Close'),
            ),
            if (widget.selectDevice)
              FilledButton(
                onPressed: !device.placeable
                    ? null
                    : () => Navigator.pop(
                        dialog,
                        PtDeviceChoice(device, device.variants[selected]),
                      ),
                child: const Text('Use device'),
              ),
          ],
        ),
      ),
    );
    if (result != null && mounted) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final catalog = PacketTracerCatalog.instance;
    final devices = catalog.search(
      _query,
      type: _category,
      availableOnly: _available,
    );
    final categories = catalog.devices.map((d) => d.type).toSet().toList()
      ..sort();
    final cables = catalog.cables
        .where(
          (c) => [
            c.label,
            c.id,
            ...c.aliases,
          ].any((a) => ptIdentity(a).contains(ptIdentity(_query))),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.selectDevice
                      ? 'Choose a device'
                      : 'Packet Tracer catalog',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Close catalog',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Recognition, build templates, and live verification are tracked separately. Catalog source: Packet Tracer ${catalog.version}.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              labelText: 'Search models, names or cables',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.clear),
                    ),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                label: Text('Devices'),
                icon: Icon(Icons.devices),
              ),
              ButtonSegment(
                value: true,
                label: Text('Cables'),
                icon: Icon(Icons.cable),
              ),
            ],
            selected: {_cables},
            onSelectionChanged: (v) => setState(() {
              _cables = v.single;
              _query = '';
              _search.clear();
            }),
          ),
        ),
        if (!_cables)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _category,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('All devices'),
                      ),
                      for (final category in categories)
                        DropdownMenuItem(
                          value: category,
                          child: Text(category),
                        ),
                    ],
                    onChanged: (v) => setState(() => _category = v),
                  ),
                ),
                const SizedBox(width: 10),
                FilterChip(
                  label: const Text('Buildable'),
                  selected: _available,
                  onSelected: (v) => setState(() => _available = v),
                ),
              ],
            ),
          ),
        Expanded(
          child: _cables
              ? ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: cables.length,
                  itemBuilder: (context, i) {
                    final cable = cables[i];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.cable),
                        title: Text(cable.label),
                        subtitle: Text(
                          '${cable.templateAvailable ? 'Cable format available' : 'Needs desktop / additional saved-file support'}\nCompatible connectors: ${cable.families.join(', ')}',
                        ),
                        isThreeLine: true,
                        onTap: () => showDialog(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: Text(cable.label),
                            content: Text(
                              'Names understood: ${cable.aliases.join(', ')}.\n\nThe connection editor checks both endpoints. A cable format alone does not prove that every device can use it.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                )
              : devices.isEmpty
              ? const Center(
                  child: Text(
                    'No matching devices. Try a model number or another category.',
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: devices.length,
                  itemBuilder: (context, i) {
                    final device = devices[i];
                    final support = catalog.compatibility(
                      device.model,
                      installedVersion: _installedVersion,
                    );
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          device.placeable
                              ? Icons.devices_other
                              : Icons.info_outline,
                        ),
                        title: Text(device.model),
                        subtitle: Text(
                          '${device.kind} · ${device.placeable ? 'Buildable' : 'Recognition only'} · ${device.configurable ? 'CLI configurable' : 'No CLI template'}${support.versionNeedsReview ? ' · version check needed' : ''}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _details(device),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
