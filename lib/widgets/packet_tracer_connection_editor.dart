import 'package:flutter/material.dart';
import '../models/network_intent.dart';
import '../services/packet_tracer/catalog.dart';

class PacketTracerConnectionEditor extends StatefulWidget {
  final NetworkIntent intent;
  final String a, b;
  final NetLink? existing;
  const PacketTracerConnectionEditor({
    super.key,
    required this.intent,
    required this.a,
    required this.b,
    this.existing,
  });
  static Future<NetLink?> show(
    BuildContext context, {
    required NetworkIntent intent,
    required String a,
    required String b,
    NetLink? existing,
  }) => showModalBottomSheet<NetLink>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: PacketTracerConnectionEditor(
        intent: intent,
        a: a,
        b: b,
        existing: existing,
      ),
    ),
  );
  @override
  State<PacketTracerConnectionEditor> createState() =>
      _PacketTracerConnectionEditorState();
}

class _PacketTracerConnectionEditorState
    extends State<PacketTracerConnectionEditor> {
  late String _cable;
  late final TextEditingController _a, _b;
  String? _error;
  bool _unknownCable = false;
  final _catalog = PacketTracerCatalog.instance;
  @override
  void initState() {
    super.initState();
    final existingCable = _catalog.cable(widget.existing?.cable);
    _unknownCable = existingCable == null;
    _cable = existingCable?.id ?? 'unknown';
    _a = TextEditingController(text: widget.existing?.aIf ?? '');
    _b = TextEditingController(text: widget.existing?.bIf ?? '');
    if (!_unknownCable) {
      if (widget.existing == null) {
        for (final cable in _catalog.cables.where((c) => c.templateAvailable)) {
          _cable = cable.id;
          final compatible = ports(widget.a).any(
            (a) => ports(widget.b).any(
              (b) =>
                  cable.mismatch(
                    a,
                    b,
                    modulesA: node(widget.a).modules,
                    modulesB: node(widget.b).modules,
                  ) ==
                  null,
            ),
          );
          if (compatible) break;
          _cable = 'copper';
        }
      }
      _defaults();
    }
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  NetNode node(String name) =>
      widget.intent.nodes.firstWhere((n) => n.name == name);
  PtDevice? device(String name) => _catalog.device(node(name).model ?? '');
  List<PtPort> ports(String name) {
    final n = node(name), d = device(name);
    final variants =
        d?.variants
            .where(
              (v) => n.modules.isEmpty || n.modules.every(v.modules.contains),
            )
            .toList() ??
        [];
    final byName = <String, PtPort>{};
    for (final variant in variants) {
      for (final port in variant.ports) {
        byName.putIfAbsent(ptPortName(port.name), () => port);
      }
    }
    return byName.values
        .where((p) => _catalog.cable(_cable)?.accepts(p) ?? false)
        .where((p) => !occupied(name, p.name))
        .toList();
  }

  bool occupied(String name, String port) => widget.intent.links
      .where((l) => l != widget.existing)
      .any(
        (l) =>
            (l.a == name && ptPortName(l.aIf) == ptPortName(port)) ||
            (l.b == name && ptPortName(l.bIf) == ptPortName(port)),
      );
  void _defaults() {
    for (final pair in [(widget.a, _a), (widget.b, _b)]) {
      final values = ports(pair.$1);
      if (!values.any((p) => ptPortName(p.name) == ptPortName(pair.$2.text))) {
        pair.$2.text = values.firstOrNull?.name ?? '';
      }
    }
  }

  void _save() {
    if (_unknownCable) {
      setState(() => _error = 'Select a known cable type before saving.');
      return;
    }
    final cable = _catalog.cable(_cable)!;
    final a = ports(
      widget.a,
    ).where((p) => ptPortName(p.name) == ptPortName(_a.text)).firstOrNull;
    final b = ports(
      widget.b,
    ).where((p) => ptPortName(p.name) == ptPortName(_b.text)).firstOrNull;
    String? error;
    if (_a.text.trim().isEmpty || _b.text.trim().isEmpty) {
      error = 'Select a port at each end.';
    } else if (occupied(widget.a, _a.text) || occupied(widget.b, _b.text)) {
      error = 'A selected port already carries another cable.';
    } else if (cable.templateAvailable && (a == null || b == null)) {
      error =
          'This hardware has no compatible free port. Choose another model or module.';
    } else if (a != null && b != null) {
      error = cable.mismatch(
        a,
        b,
        modulesA: node(widget.a).modules,
        modulesB: node(widget.b).modules,
      );
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(
      context,
      NetLink(
        a: widget.a,
        aIf: _a.text.trim(),
        b: widget.b,
        bIf: _b.text.trim(),
        cable: _cable,
        exactPorts: true,
        dce: _cable == 'serial-dte'
            ? 'b'
            : _cable.startsWith('serial')
            ? 'a'
            : null,
      ),
    );
  }

  Widget _portField(String name, TextEditingController controller) => TextField(
    controller: controller,
    decoration: InputDecoration(
      labelText: '$name port',
      hintText: 'Select a compatible port',
      suffixIcon: PopupMenuButton<String>(
        tooltip: 'Free compatible ports',
        onSelected: (v) => setState(() => controller.text = v),
        itemBuilder: (_) => [
          for (final port in ports(name))
            PopupMenuItem(value: port.name, child: Text(port.name)),
        ],
        icon: const Icon(Icons.arrow_drop_down),
      ),
    ),
    onChanged: (_) => setState(() => _error = null),
  );
  @override
  Widget build(BuildContext context) {
    final cable = _catalog.cable(_cable);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${widget.a} → ${widget.b}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          const Text('Choose the cable and the exact port at each end.'),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _cable,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Cable type'),
            items: [
              if (_unknownCable)
                DropdownMenuItem(
                  value: 'unknown',
                  child: Text('Unknown: ${widget.existing?.cable}'),
                ),
              for (final c in _catalog.cables)
                DropdownMenuItem(value: c.id, child: Text(c.label)),
            ],
            onChanged: (v) => setState(() {
              _cable = v ?? _cable;
              _unknownCable = _cable == 'unknown';
              _error = null;
              if (!_unknownCable) _defaults();
            }),
          ),
          const SizedBox(height: 12),
          _portField(widget.a, _a),
          const SizedBox(height: 12),
          _portField(widget.b, _b),
          const SizedBox(height: 12),
          Text(
            _unknownCable
                ? 'This cable is unknown. Select its type to keep the connection accurate.'
                : cable!.templateAvailable
                ? '${ports(widget.a).length} free compatible ports on ${widget.a}; ${ports(widget.b).length} on ${widget.b}.'
                : 'This cable is understood. You can save the connection in your plan, but building it requires desktop support.',
          ),
          if (_cable.startsWith('serial'))
            Text(
              'Clocking (DCE) end: ${_cable == 'serial-dte' ? widget.b : widget.a}',
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.cable),
            label: Text(
              widget.existing == null ? 'Add connection' : 'Save connection',
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
