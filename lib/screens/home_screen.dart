import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/build_record.dart';
import '../services/memory_service.dart';

class HomeScreen extends StatefulWidget {
  final void Function(BuildRecord) onOpen;
  const HomeScreen({super.key, required this.onOpen});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<BuildRecord> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final mem = context.read<MemoryService>();
      if (mem.ready) {
        _items = await mem.recentBuilds(limit: 30);
      }
    } catch (_) {
      _items = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.hub_outlined, size: 56),
              const SizedBox(height: 12),
              const Text(
                'No networks yet.\nGo to Build to create your first one.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _refresh, child: const Text('Refresh')),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _items.length,
        itemBuilder: (c, i) {
          final b = _items[i];
          final statusColor = switch (b.status) {
            'verified' => Colors.green,
            'failed' => Colors.red,
            'corrected' => Colors.orange,
            _ => Colors.blueGrey,
          };
          return ListTile(
            leading: Icon(
              b.status == 'verified'
                  ? Icons.check_circle
                  : b.status == 'failed'
                  ? Icons.error
                  : Icons.pending_actions,
              color: statusColor,
            ),
            title: Text('${b.projectName} [${b.target}]'),
            subtitle: Text(
              '${b.status.toUpperCase()} · ${b.instruction}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => widget.onOpen(b),
          );
        },
      ),
    );
  }
}
