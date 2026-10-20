import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import '../models/network_intent.dart';
import '../services/network_block_service.dart';
import '../services/topology_edit_service.dart';
import '../services/packet_tracer/catalog.dart';
import '../services/packet_tracer/hardware_check.dart';
import '../widgets/packet_tracer_catalog.dart';
import '../widgets/packet_tracer_connection_editor.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../widgets/topology_canvas.dart';

T? _firstOrNull<T>(Iterable<T> values, bool Function(T value) matches) {
  for (final value in values) {
    if (matches(value)) return value;
  }
  return null;
}

/// Plan diagram with direct device, cable, address, and layout editing.
class TopologyPreviewScreen extends StatefulWidget {
  final NetworkIntent intent;
  final ValueChanged<Map<String, Offset?>>? onLayoutChanged;
  final Future<void> Function(NetworkIntent intent)? onIntentSaved;

  const TopologyPreviewScreen({
    super.key,
    required this.intent,
    this.onLayoutChanged,
    this.onIntentSaved,
  });

  @override
  State<TopologyPreviewScreen> createState() => _TopologyPreviewScreenState();
}

class _TopologyEditSnapshot {
  final NetworkIntent intent;
  final Map<String, Offset?>? layout;
  const _TopologyEditSnapshot(this.intent, this.layout);
}

class _TopologyPreviewScreenState extends State<TopologyPreviewScreen> {
  late NetworkIntent _intent;
  Map<String, Offset?>? _layout;
  bool _editing = false;
  bool _connecting = false;
  bool _removing = false;
  bool _dirty = false;
  bool _saving = false;
  String? _connectFrom;
  final List<_TopologyEditSnapshot> _undo = [];
  final List<_TopologyEditSnapshot> _redo = [];
  final Set<String> _selectedGroup = {};
  bool _selectingGroup = false;

  @override
  void initState() {
    super.initState();
    _intent = widget.intent;
  }

  void _change(NetworkIntent next) {
    _recordUndo();
    setState(() {
      _intent = next;
      _dirty = true;
    });
  }

  void _recordUndo() {
    _undo.add(
      _TopologyEditSnapshot(
        _intent,
        _layout == null ? null : Map<String, Offset?>.of(_layout!),
      ),
    );
    if (_undo.length > 80) _undo.removeAt(0);
    _redo.clear();
  }

  void _undoEdit() {
    if (!_editing || _undo.isEmpty) return;
    _redo.add(
      _TopologyEditSnapshot(
        _intent,
        _layout == null ? null : Map<String, Offset?>.of(_layout!),
      ),
    );
    _restoreEdit(_undo.removeLast());
  }

  void _redoEdit() {
    if (!_editing || _redo.isEmpty) return;
    _undo.add(
      _TopologyEditSnapshot(
        _intent,
        _layout == null ? null : Map<String, Offset?>.of(_layout!),
      ),
    );
    _restoreEdit(_redo.removeLast());
  }

  void _restoreEdit(_TopologyEditSnapshot snapshot) => setState(() {
    _intent = snapshot.intent;
    _layout = snapshot.layout == null
        ? null
        : Map<String, Offset?>.of(snapshot.layout!);
    _dirty = true;
    _connecting = false;
    _removing = false;
    _selectingGroup = false;
    _selectedGroup.clear();
    _connectFrom = null;
  });

  NetworkIntent get _intentWithCurrentLayout => _intent.copyWith(
    layout: _layout == null
        ? _intent.layout
        : Map<String, Offset?>.of(_layout!),
  );

  void _toggleGroupNode(String name) {
    setState(() {
      if (!_selectedGroup.add(name)) _selectedGroup.remove(name);
    });
  }

  void _finishGroupSelection() => setState(() {
    _selectingGroup = false;
    _selectedGroup.clear();
  });

  Future<void> _saveSelectedBlock() async {
    if (_selectedGroup.isEmpty) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Save reusable network block'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Block name',
            hintText: 'Small office, classroom, server room…',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save block'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    final block = NetworkBlock.fromSelection(
      name: name,
      intent: _intentWithCurrentLayout,
      selected: Set<String>.of(_selectedGroup),
    );
    await NetworkBlockService.save(block);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved “$name” for reuse on this device.')),
    );
  }

  void _duplicateSelectedGroup() {
    if (_selectedGroup.isEmpty) return;
    final selected = Set<String>.of(_selectedGroup);
    final block = NetworkBlock.fromSelection(
      name: 'Copy',
      intent: _intentWithCurrentLayout,
      selected: selected,
    );
    final result = NetworkBlockService.addTo(
      _intent,
      block,
      currentLayout: _layout ?? _intent.layout,
    );
    _change(result.intent);
    _layout = result.intent.layout;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.clearedAddressCount == 0
              ? 'Duplicated ${selected.length} devices and their internal cables.'
              : 'Duplicated the group; cleared ${result.clearedAddressCount} '
                    'conflicting address(es).',
        ),
      ),
    );
    _finishGroupSelection();
  }

  void _autoWireSelectedGroup() {
    if (_selectedGroup.length < 2) return;
    final result = TopologyEditService.autoWire(_intent, _selectedGroup);
    if (result.added.isNotEmpty) _change(result.intent);
    final text = result.added.isEmpty
        ? 'No compatible free ports were found for this group.'
        : 'Added ${result.added.length} compatible cable(s)'
              '${result.notConnected.isEmpty ? '.' : '; could not connect ${result.notConnected.join(', ')}.'}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    _finishGroupSelection();
  }

  Future<void> _openReusableBlocks() async {
    var blocks = await NetworkBlockService.load();
    if (!mounted) return;
    if (blocks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save a selected group to create a reusable block.')),
      );
      return;
    }
    final selected = await showModalBottomSheet<NetworkBlock>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, refresh) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.55,
            child: ListView(
              children: [
                const ListTile(
                  title: Text('Reusable network blocks'),
                  subtitle: Text('Tap a block to add a fresh copy to this plan.'),
                ),
                for (final block in blocks)
                  ListTile(
                    leading: const Icon(Icons.account_tree_outlined),
                    title: Text(block.name),
                    subtitle: Text(
                      '${block.nodes.length} devices · ${block.links.length} cables',
                    ),
                    onTap: () => Navigator.pop(sheetContext, block),
                    trailing: IconButton(
                      tooltip: 'Delete saved block',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await NetworkBlockService.delete(block.name);
                        blocks = await NetworkBlockService.load();
                        if (context.mounted) refresh(() {});
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final result = NetworkBlockService.addTo(
      _intent,
      selected,
      currentLayout: _layout ?? _intent.layout,
    );
    _change(result.intent);
    _layout = result.intent.layout;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Added ${selected.name}; ${result.clearedAddressCount} conflicting '
          'address(es) need review.',
        ),
      ),
    );
  }

  Future<void> _openPathExplorer() async {
    if (_intent.nodes.length < 2) return;
    var start = _intent.nodes.first.name;
    var end = _intent.nodes.last.name;
    String? result;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('Network path'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: start,
                  decoration: const InputDecoration(labelText: 'From device'),
                  items: [
                    for (final node in _intent.nodes)
                      DropdownMenuItem(value: node.name, child: Text(node.name)),
                  ],
                  onChanged: (value) => refresh(() => start = value ?? start),
                ),
                DropdownButtonFormField<String>(
                  initialValue: end,
                  decoration: const InputDecoration(labelText: 'To device'),
                  items: [
                    for (final node in _intent.nodes)
                      DropdownMenuItem(value: node.name, child: Text(node.name)),
                  ],
                  onChanged: (value) => refresh(() => end = value ?? end),
                ),
                if (result != null) ...[
                  const SizedBox(height: AppTheme.s12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(result!, style: Theme.of(context).textTheme.bodyMedium),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
            FilledButton.icon(
              onPressed: start == end
                  ? null
                  : () => refresh(() => result = _describePath(start, end)),
              icon: const Icon(Icons.route_outlined),
              label: const Text('Find path'),
            ),
          ],
        ),
      ),
    );
  }

  String _describePath(String start, String end) {
    final queue = <String>[start];
    final previous = <String, (String, NetLink)>{};
    final seen = <String>{start};
    var cursor = 0;
    while (cursor < queue.length) {
      final current = queue[cursor++];
      if (current == end) break;
      for (final link in _intent.wiredLinks) {
        final next = link.a == current
            ? link.b
            : link.b == current
            ? link.a
            : null;
        if (next == null || !seen.add(next)) continue;
        previous[next] = (current, link);
        queue.add(next);
      }
    }
    if (!seen.contains(end)) {
      return 'No physical cable path connects $start to $end. Add a cable '
          'between the separate parts of the topology. IP reachability also '
          'depends on addresses, VLANs, gateways, and routes.';
    }
    final hops = <String>[];
    var at = end;
    while (at != start) {
      final step = previous[at]!;
      final link = step.$2;
      final forward = link.a == step.$1;
      hops.add(
        '${step.$1} ${forward ? link.aIf : link.bIf} → '
        '$at ${forward ? link.bIf : link.aIf} '
        '(${PacketTracerCatalog.instance.cable(link.cable)?.label ?? link.cable ?? 'cable'})',
      );
      at = step.$1;
    }
    return 'Planned physical path (${hops.length} hop${hops.length == 1 ? '' : 's'}):\n'
        '${hops.reversed.join('\n')}\n\n'
        'This checks the drawn cables. It does not simulate IP reachability; '
        'addresses, VLANs, gateways, and routing still matter.';
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    setState(() => _saving = true);
    final next = _intent.copyWith(
      layout: _layout == null
          ? _intent.layout
          : <String, Offset?>{for (final e in _layout!.entries) e.key: e.value},
    );
    try {
      await widget.onIntentSaved?.call(next);
      widget.onLayoutChanged?.call(next.layout);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save this plan version: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addDevice() async {
    final choice = await PacketTracerCatalogSheet.show(
      context,
      selectDevice: true,
    );
    if (choice == null || !mounted) return;
    final prefix = devicePrefix(choice.device.type);
    var i = 1;
    while (_intent.nodes.any(
      (n) => n.name.toLowerCase() == '$prefix$i'.toLowerCase(),
    )) {
      i++;
    }
    final controller = TextEditingController(text: '$prefix$i');
    String? error;
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text('Add ${choice.device.model}'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Device name',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty ||
                    _intent.nodes.any(
                      (n) => n.name.toLowerCase() == value.toLowerCase(),
                    )) {
                  refresh(() => error = 'Enter a unique device name.');
                  return;
                }
                Navigator.pop(dialog, value);
              },
              child: const Text('Add device'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    _change(
      _intent.copyWith(
        nodes: [
          ..._intent.nodes,
          NetNode(
            name: name,
            type: choice.device.type,
            model: choice.device.model,
            exactModel: true,
            modules: choice.variant.modules,
          ),
        ],
      ),
    );
  }

  Future<void> _connectDevices(String a, String b, {NetLink? existing}) async {
    final link = await PacketTracerConnectionEditor.show(
      context,
      intent: _intent,
      a: a,
      b: b,
      existing: existing,
    );
    if (link == null || !mounted) return;
    _change(
      _intent.copyWith(
        links: existing == null
            ? [..._intent.links, link]
            : [
                for (final old in _intent.links)
                  if (identical(old, existing)) link else old,
              ],
      ),
    );
  }

  Future<void> _manageCables() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.72,
          child: Column(
            children: [
              ListTile(
                title: const Text('Connections'),
                subtitle: const Text(
                  'Edit ports or cable types; remove an unwanted connection.',
                ),
                trailing: IconButton(
                  tooltip: 'Close connections',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Expanded(
                child: _intent.links.isEmpty
                    ? const Center(
                        child: Text(
                          'No connections yet. Choose Connect to link two devices.',
                        ),
                      )
                    : ListView.builder(
                        itemCount: _intent.links.length,
                        itemBuilder: (context, index) {
                          final link = _intent.links[index];
                          return ListTile(
                            leading: const Icon(Icons.cable),
                            title: Text(
                              '${link.a} ${link.aIf} → ${link.b} ${link.bIf}',
                            ),
                            subtitle: Text(
                              PacketTracerCatalog.instance
                                      .cable(link.cable)
                                      ?.label ??
                                  'Unknown cable: ${link.cable}',
                            ),
                            onTap: () async {
                              await _connectDevices(
                                link.a,
                                link.b,
                                existing: link,
                              );
                              if (context.mounted) refresh(() {});
                            },
                            trailing: IconButton(
                              tooltip: 'Remove connection',
                              icon: const Icon(Icons.link_off),
                              onPressed: () {
                                _change(
                                  _intent.copyWith(
                                    links: _intent.links
                                        .where((l) => !identical(l, link))
                                        .toList(),
                                  ),
                                );
                                refresh(() {});
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editDevice(String name) async {
    final node = _firstOrNull(_intent.nodes, (n) => n.name == name);
    if (node == null) return;
    final nameCtl = TextEditingController(text: node.name);
    final currentAddressIndex = _intent.addressing.indexWhere(
      (a) => a.node == name,
    );
    final currentAddress = currentAddressIndex < 0
        ? null
        : _intent.addressing[currentAddressIndex];
    final addressCtl = TextEditingController(
      text: currentAddress?.ipCidr ?? '',
    );
    String? error;
    PtDeviceChoice? hardware;
    final result = await showDialog<(String, String, PtDeviceChoice?)?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, refresh) => AlertDialog(
          title: Text('Edit ${node.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    hardware?.device.model ?? node.model ?? node.type,
                  ),
                  subtitle: const Text('Change device or installed modules'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final choice = await PacketTracerCatalogSheet.show(
                      dialogContext,
                      selectDevice: true,
                    );
                    if (choice != null && dialogContext.mounted) {
                      refresh(() => hardware = choice);
                    }
                  },
                ),
                TextField(
                  controller: nameCtl,
                  decoration: InputDecoration(
                    labelText: 'Device name',
                    errorText: error,
                  ),
                ),
                TextField(
                  controller: addressCtl,
                  decoration: const InputDecoration(
                    labelText: 'Primary IPv4 address / CIDR',
                    hintText: '192.168.1.10/24',
                    helperText: 'Leave blank to clear this device address.',
                  ),
                  keyboardType: TextInputType.text,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final newName = nameCtl.text.trim();
                final address = addressCtl.text.trim();
                final duplicate = _intent.nodes.any(
                  (n) =>
                      n.name.toLowerCase() == newName.toLowerCase() &&
                      n.name != name,
                );
                final validAddress =
                    address.isEmpty ||
                    RegExp(
                          r'^\d{1,3}(?:\.\d{1,3}){3}(?:/(?:[0-9]|[12][0-9]|3[0-2]))?$',
                        ).hasMatch(address) &&
                        _validIpv4(address.split('/').first);
                if (newName.isEmpty || duplicate || !validAddress) {
                  refresh(
                    () => error = newName.isEmpty
                        ? 'Enter a name'
                        : duplicate
                        ? 'That name is already used'
                        : 'Enter an IPv4 address, optionally with /CIDR',
                  );
                  return;
                }
                Navigator.pop(dialogContext, (newName, address, hardware));
              },
              child: const Text('Save device'),
            ),
          ],
        ),
      ),
    );
    nameCtl.dispose();
    addressCtl.dispose();
    if (result == null || !mounted) return;
    final (newName, rawAddress, hardwareChoice) = result;
    final address = rawAddress.isEmpty || rawAddress.contains('/')
        ? rawAddress
        : '$rawAddress/24';
    var next = TopologyEditService.editDevice(
      intent: _intentWithCurrentLayout,
      oldName: name,
      newName: newName,
      primaryIpv4: address,
      fallbackInterface: _defaultPort(node.type, 0),
    );
    if (hardwareChoice != null) {
      next = next.copyWith(
        nodes: [
          for (final n in next.nodes)
            if (n.name == newName)
              NetNode.fromJson({
                ...n.toJson(),
                'type': hardwareChoice.device.type,
                'model': hardwareChoice.device.model,
                'exactModel': true,
                'modules': hardwareChoice.variant.modules,
              })
            else
              n,
        ],
      );
    }
    _change(next);
    _layout = next.layout;
  }

  void _tapDevice(String name) {
    if (_selectingGroup) {
      _toggleGroupNode(name);
      return;
    }
    if (_removing) {
      _removeDevice(name);
      return;
    }
    if (_connecting) {
      if (_connectFrom == null) {
        setState(() => _connectFrom = name);
        return;
      }
      final from = _connectFrom!;
      setState(() {
        _connectFrom = null;
        _connecting = false;
      });
      if (from != name) _connectDevices(from, name);
      return;
    }
    _editDevice(name);
  }

  bool _validIpv4(String value) {
    final parts = value.split('.');
    return parts.length == 4 &&
        parts.every((part) {
          final octet = int.tryParse(part);
          return octet != null && octet >= 0 && octet <= 255;
        });
  }

  String _defaultPort(String type, int index) => switch (type.toLowerCase()) {
    'switch' || 'hub' || 'bridge' => 'F0/${index + 1}',
    'router' || 'wireless-router' => 'G0/$index',
    'firewall' => 'G1/${index + 1}',
    _ => deviceKindOf(type)?.port ?? 'Fa0',
  };

  Future<void> _removeDevice(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text(
          'Its cables, addresses, and saved position will also be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _removing = false);
    final layout = Map<String, Offset?>.from(_intentWithCurrentLayout.layout)
      ..remove(name);
    final securityJson = _intent.security.toJson();
    for (final field in ['aaaServer', 'aaaRouter', 'vpnPeerA', 'vpnPeerB']) {
      if (securityJson[field] == name) securityJson.remove(field);
    }
    final next = _intentWithCurrentLayout.copyWith(
        nodes: _intent.nodes.where((n) => n.name != name).toList(),
        links: _intent.links.where((l) => l.a != name && l.b != name).toList(),
        addressing: _intent.addressing.where((a) => a.node != name).toList(),
        layout: layout,
        security: SecurityIntent.fromJson(securityJson),
      );
    _change(next);
    _layout = layout;
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undoEdit,
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): _redoEdit,
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): _redoEdit,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      appBar: AppBar(
        title: Text(
          '${_intent.projectName} - topology',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_editing) ...[
            IconButton(
              tooltip: 'Undo',
              onPressed: _undo.isEmpty ? null : _undoEdit,
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              tooltip: 'Redo',
              onPressed: _redo.isEmpty ? null : _redoEdit,
              icon: const Icon(Icons.redo),
            ),
          ],
          if (_editing)
            TextButton(
              onPressed: () => setState(() {
                _editing = false;
                _connecting = false;
                _removing = false;
                _selectingGroup = false;
                _selectedGroup.clear();
                _connectFrom = null;
              }),
              child: const Text('Done'),
            )
          else
            TextButton.icon(
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit'),
            ),
          if (_dirty)
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving' : 'Save'),
            ),
          const SizedBox(width: AppTheme.s8),
        ],
      ),
      body: Column(
        children: [
          AppToolbar(
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTag(
                  label: '${_intent.nodes.length} devices',
                  tone: AppTone.accent,
                  icon: Icons.devices_other_outlined,
                ),
                AppTag(
                  label: '${_intent.links.length} cables',
                  tone: AppTone.info,
                  icon: Icons.cable_outlined,
                ),
                const SizedBox(width: AppTheme.s8),
                Flexible(
                  child: Text(
                    _editing
                        ? (_selectingGroup
                              ? 'Tap devices to select; drag one to move the group'
                              : _removing
                              ? 'Select a device to remove'
                              : _connecting
                              ? (_connectFrom == null
                                    ? 'Select the first device'
                                    : 'Select the second device')
                              : 'Select a device to edit')
                        : 'Pinch to zoom, drag canvas, tap for details',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          if (_editing)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.s12,
                vertical: AppTheme.s6,
              ),
              child: Wrap(
                spacing: AppTheme.s8,
                runSpacing: AppTheme.s6,
                children: _selectingGroup
                    ? [
                        OutlinedButton.icon(
                          onPressed: _finishGroupSelection,
                          icon: const Icon(Icons.done),
                          label: Text('Done (${_selectedGroup.length})'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _selectedGroup.isEmpty
                              ? null
                              : _duplicateSelectedGroup,
                          icon: const Icon(Icons.copy_outlined),
                          label: const Text('Duplicate'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _selectedGroup.length < 2
                              ? null
                              : _autoWireSelectedGroup,
                          icon: const Icon(Icons.cable_outlined),
                          label: const Text('Auto-wire'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _selectedGroup.isEmpty
                              ? null
                              : _saveSelectedBlock,
                          icon: const Icon(Icons.bookmark_add_outlined),
                          label: const Text('Save as block'),
                        ),
                      ]
                    : [
                        OutlinedButton.icon(
                          onPressed: _addDevice,
                          icon: const Icon(Icons.add),
                          label: const Text('Add device'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => setState(() {
                            _connecting = !_connecting;
                            _removing = false;
                            _connectFrom = null;
                          }),
                          icon: const Icon(Icons.cable_outlined),
                          label: Text(_connecting ? 'Cancel' : 'Connect cable'),
                        ),
                        PopupMenuButton<String>(
                          tooltip: 'More network tools',
                          onSelected: (value) {
                            switch (value) {
                              case 'connections':
                                _manageCables();
                                break;
                              case 'catalog':
                                PacketTracerCatalogSheet.show(context);
                                break;
                              case 'select':
                                setState(() {
                                  _selectingGroup = true;
                                  _selectedGroup.clear();
                                  _connecting = false;
                                  _removing = false;
                                });
                                break;
                              case 'remove':
                                setState(() {
                                  _removing = !_removing;
                                  _connecting = false;
                                  _connectFrom = null;
                                });
                                break;
                              case 'path':
                                _openPathExplorer();
                                break;
                              case 'blocks':
                                _openReusableBlocks();
                                break;
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 'connections', child: Text('Manage connections')),
                            PopupMenuItem(value: 'catalog', child: Text('Device and cable catalog')),
                            PopupMenuItem(value: 'select', child: Text('Select a device group')),
                            PopupMenuItem(value: 'remove', child: Text('Remove a device')),
                            PopupMenuItem(value: 'path', child: Text('Explore a network path')),
                            PopupMenuItem(value: 'blocks', child: Text('Reusable network blocks')),
                          ],
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.tune, size: 18),
                                SizedBox(width: 6),
                                Text('More'),
                              ],
                            ),
                          ),
                        ),
                      ],
              ),
            ),
          if (PtHardwareCheck.inspect(_intent).any((i) => i.blocking))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      PtHardwareCheck.inspect(
                        _intent,
                      ).firstWhere((i) => i.blocking).message,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TopologyCanvas(
                intent: _intent,
                selectedNode: _connectFrom,
                allowNodeDrag: _editing && !_connecting && !_removing,
                layout: _layout?.cast<String, Offset?>(),
                onNodeTap: _editing ? _tapDevice : null,
                selectedNodes: Set<String>.unmodifiable(_selectedGroup),
                onLayoutChanged: (positions) {
                  _recordUndo();
                  setState(() {
                    _layout = {for (final e in positions.entries) e.key: e.value};
                    _dirty = true;
                  });
                },
              ),
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }
}
