import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/gemini_service.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _key = TextEditingController();
  final _gns3 = TextEditingController();
  final _gns3User = TextEditingController();
  final _gns3Pass = TextEditingController();
  bool _obscure = true;
  bool _obscureGns3 = true;
  String _status = '';
  bool _busy = false;
  bool _showKey = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final s = context.read<SettingsService>();
    final k = await s.getApiKey();
    _key.text = k ?? '';
    _gns3.text = s.gns3Endpoint;
    _gns3User.text = s.gns3User;
    _gns3Pass.text = s.gns3Pass;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _key.dispose();
    _gns3.dispose();
    _gns3User.dispose();
    _gns3Pass.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    setState(() {
      _busy = true;
      _status = 'Saving + testing...';
    });
    try {
      final s = context.read<SettingsService>();
      await s.setApiKey(_key.text);
      await s.setGns3Endpoint(_gns3.text);
      await s.setGns3Credentials(_gns3User.text, _gns3Pass.text);
      final key = _key.text.trim();
      if (key.isEmpty) {
        setState(() => _status = 'Key cleared. Private Mode only.');
        return;
      }
      final err = await GeminiService().testKey(apiKey: key, model: s.model);
      setState(
        () => _status = err == null
            ? 'Key valid for ${s.model}.'
            : 'Key test failed: $err',
      );
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _listModels() async {
    setState(() {
      _busy = true;
      _status = 'Listing models...';
    });
    try {
      final s = context.read<SettingsService>();
      await s.setApiKey(_key.text);
      final key = _key.text.trim();
      if (key.isEmpty) {
        setState(() => _status = 'Paste a key first.');
        return;
      }
      final models = await GeminiService().listModels(key);
      final flash = models
          .where((m) => m.contains('flash'))
          .take(10)
          .join('\n');
      setState(
        () => _status =
            'Models for this key (${models.length}):\n$flash\n\nIf empty, enable Gemini API in AI Studio project.',
      );
    } catch (e) {
      setState(() => _status = 'List failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Gemini API Key (BYOK)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 4),
          const Text(
            'Get one free at aistudio.google.com. Stored only in secure storage on this device, never logged or uploaded.',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'Gemini API Key',
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'show/hide',
                    icon: Icon(
                      _obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                  IconButton(
                    tooltip: 'clear',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() => _key.clear()),
                  ),
                ],
              ),
            ),
            onChanged: (_) => setState(() => _showKey = true),
          ),
          if (_showKey)
            const Text(
              'Unsaved changes - press Save + Test.',
              style: TextStyle(color: Colors.orange),
            ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: s.model,
            items: SettingsService.supportedModels
                .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                .toList(),
            onChanged: (v) => s.setModel(v ?? s.model),
            decoration: const InputDecoration(labelText: 'Model'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _gns3,
            decoration: const InputDecoration(
              labelText: 'GNS3 server endpoint',
              hintText: 'http://127.0.0.1:3080',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _gns3User,
                  decoration: const InputDecoration(
                    labelText: 'GNS3 user (default admin)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _gns3Pass,
                  obscureText: _obscureGns3,
                  decoration: InputDecoration(
                    labelText: 'GNS3 password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      tooltip: 'show/hide',
                      icon: Icon(
                        _obscureGns3 ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _obscureGns3 = !_obscureGns3),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'GNS3 2.2+ requires HTTP auth by default (user admin). '
              'Credentials are sent as Basic auth on every GNS3 call.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: s.defaultTarget,
            items: SettingsService.supportedTargets
                .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                .toList(),
            onChanged: (v) => s.setDefaultTarget(v ?? 'gns3'),
            decoration: const InputDecoration(labelText: 'Default target'),
          ),
          SwitchListTile(
            title: const Text('Private / Offline Mode'),
            subtitle: const Text(
              'Kill-switch: disables Gemini + web search. Local only.',
            ),
            value: s.privateMode,
            onChanged: (v) => s.setPrivateMode(v),
          ),
          SwitchListTile(
            title: const Text('Let the sidecar ask Gemini when stuck'),
            subtitle: const Text(
              'On a rejected command the sidecar asks Gemini for a '
              'replacement, tries it, and remembers it only if the terminal '
              'proves it worked. Off in Private Mode.',
            ),
            value: s.llmFix,
            onChanged: (v) => s.setLlmFix(v),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _busy ? null : _saveAndTest,
            child: Text(_busy ? 'Testing...' : 'Save + Test Key'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _listModels,
            child: const Text('List available models for this key'),
          ),
          const SizedBox(height: 8),
          SelectableText(_status),
          const SizedBox(height: 16),
          const Text(
            'PT Autopilot requirements',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            '- Packet Tracer open, maximized, focused\n- Display 100%, no overlays\n- Do not touch mouse/keyboard during run\n- Sidecar: python sidecar/pt_autopilot.py',
          ),
        ],
      ),
    );
  }
}
