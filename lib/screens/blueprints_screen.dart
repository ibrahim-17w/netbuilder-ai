import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/build_record.dart';
import '../models/network_intent.dart';
import '../services/memory_service.dart';
import '../services/user_blueprints.dart';

class BlueprintsScreen extends StatefulWidget {
  final ValueChanged<BuildRecord> onOpen;
  const BlueprintsScreen({super.key, required this.onOpen});
  @override
  State<BlueprintsScreen> createState() => _BlueprintsScreenState();

  static Future<void> savePlan(
    BuildContext context,
    NetworkIntent plan, {
    Map<String, dynamic>? existing,
  }) async {
    final service = UserBlueprints(context.read<MemoryService>());
    final name = TextEditingController(
      text: existing?['name'] ?? plan.projectName,
    );
    final description = TextEditingController(
      text: existing?['description'] ?? '',
    );
    final tags = TextEditingController(text: existing?['tags'] ?? '');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Save blueprint'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: description,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              TextField(
                controller: tags,
                decoration: const InputDecoration(labelText: 'Tags'),
              ),
              const Text(
                'Credentials and build results are omitted. Each use creates a new project.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (name.text.trim().isNotEmpty) Navigator.pop(c, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    try {
      if (accepted == true) {
        await service.save(
          plan,
          name: name.text,
          description: description.text,
          tags: tags.text,
          id: existing?['id'],
        );
      }
    } finally {
      name.dispose();
      description.dispose();
      tags.dispose();
    }
  }
}

class _BlueprintsScreenState extends State<BlueprintsScreen> {
  List<Map<String, dynamic>> rows = [];
  String query = '';
  String? error;
  bool busy = false;
  UserBlueprints get service => UserBlueprints(context.read<MemoryService>());
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final loaded = await service.all();
      if (mounted) {
        setState(() {
          rows = loaded;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _action(Map<String, dynamic> row, String action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      if (action == 'edit') {
        await BlueprintsScreen.savePlan(
          context,
          NetworkIntent.fromJson(Map<String, dynamic>.from(row['plan'])),
          existing: row,
        );
      } else if (action == 'delete') {
        await service.remove(row['id']);
      } else {
        final name = TextEditingController(text: row['name']);
        final accepted = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('New project from blueprint'),
            content: TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Project name'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (name.text.trim().isNotEmpty) Navigator.pop(c, true);
                },
                child: const Text('Create project'),
              ),
            ],
          ),
        );
        final text = name.text;
        name.dispose();
        if (accepted != true || !mounted) return;
        final record = await service.instantiate(row, text);
        if (!mounted) return;
        Navigator.pop(context);
        widget.onOpen(record);
        return;
      }
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Your blueprints')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Save any project as a blueprint from its history menu.'),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search name, description or tags',
          ),
          onChanged: (v) => setState(() => query = v.toLowerCase()),
        ),
        if (error != null) Text(error!),
        if (rows.isEmpty) const Text('No saved blueprints yet.'),
        for (final row in rows.where(
          (r) => '${r['name']} ${r['description']} ${r['tags']}'
              .toLowerCase()
              .contains(query),
        ))
          Card(
            child: ListTile(
              title: Text(row['name']),
              subtitle: Text('${row['description']}\n${row['tags']}'),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                enabled: !busy,
                onSelected: (v) => _action(row, v),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'use', child: Text('Create project')),
                  PopupMenuItem(value: 'edit', child: Text('Edit blueprint')),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete blueprint'),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
