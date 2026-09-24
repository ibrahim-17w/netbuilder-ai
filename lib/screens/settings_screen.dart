import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/context_budget.dart';
import '../services/gemini_model_catalog.dart';
import '../services/gemini_service.dart';
import '../services/settings_service.dart';
import '../theme/app_palette.dart';
import '../widgets/gemini_model_picker.dart';

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
  /// Models detected for the stored/typed key, or null until detection has
  /// run. Null is distinct from empty: null = not checked yet.
  List<String>? _detected;
  String? _detectedNote;
  /// Re-run detection silently when the key field settles.
  Timer? _detectDebounce;

  @override
  void dispose() {
    _detectDebounce?.cancel();
    _key.dispose();
    _gns3.dispose();
    _gns3User.dispose();
    _gns3Pass.dispose();
    super.dispose();
  }

  /// What the model dropdown offers: the live detection when there is one,
  /// the current stable fallback when there is not, and always the model
  /// actually in use so the dropdown can never show an orphan value.
  List<String> modelChoices(String current) {
    final set = <String>{
      if (_detected != null)
        ...(_detected ?? const <String>[])
      else
        ...GeminiModelCatalog.fallbackSuggestions,
      if (current.trim().isNotEmpty) current,
    };
    return set.toList()..sort((a, b) => b.compareTo(a));
  }

  /// Detect what this key can use, then recommend the latest stable model.
  /// Runs on save, on opening the picker, and (debounced) while typing a key.
  Future<void> _detect({bool announce = true}) async {
    final s = context.read<SettingsService>();
    final key = _key.text.trim().isEmpty ? (await s.getApiKey() ?? '') : _key.text.trim();
    if (!mounted) return;
    setState(() {
      if (announce) {
        _busy = true;
        _status = 'Detecting the models this key can use...';
      }
    });
    try {
      final models = await GeminiModelCatalog().fetchFor(key);
      final best = GeminiModelCatalog.recommend(models);
      if (!mounted) return;
      setState(() {
        _detected = models.map((m) => m.name).toList();
        _detectedNote = models.isEmpty
            ? 'This key listed no chat models.'
            : '${models.length} model(s) available'
                '${best == null ? '' : ' - latest stable: ${best.name}'}';
        if (announce) _status = _detectedNote!;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _detected = null;
        _detectedNote = e.toString().replaceFirst('Exception: ', '');
        if (announce) _status = _detectedNote!;
      });
    } finally {
      if (mounted && announce) setState(() => _busy = false);
    }
  }

  void _onKeyChanged(String value) {
    setState(() => _showKey = true);
    _detectDebounce?.cancel();
    _detectDebounce = Timer(const Duration(milliseconds: 1200), () {
      if (value.trim().length >= 20) _detect(announce: false);
    });
  }

  /// Open the picker, and store the chosen model.
  Future<void> _pickModel() async {
    final s = context.read<SettingsService>();
    final key = _key.text.trim().isEmpty ? (await s.getApiKey() ?? '') : _key.text.trim();
    if (!mounted) return;
    // Never send the key through detection twice: the picker fetches its own
    // list, so a stale _detected list is not a second round trip.
    final chosen = await showGeminiModelPicker(
      context,
      apiKey: key,
      currentModel: s.model,
    );
    if (chosen == null || chosen.trim().isEmpty || !mounted) return;
    await s.setModel(chosen.trim());
    setState(() => _status = 'Model set to ${chosen.trim()}.');
  }

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
      // Detect first: the saved model may be one this key cannot use, and
      // the recommendation is only trustworthy once the list is real.
      await _detect(announce: false);
      final detected = _detected;
      if (detected != null && !detected.contains(s.model)) {
        final best = GeminiModelCatalog.recommend(
          [for (final n in detected) GeminiModelInfo(name: n)],
        );
        if (best != null) {
          await s.setModel(best.name);
        }
      }
      final err = await GeminiService().testKey(apiKey: key, model: s.model);
      if (!mounted) return;
      setState(
        () => _status = err == null
            ? 'Key valid for ${s.model}. ${_detectedNote ?? ''}'.trim()
            : 'Key test failed: $err',
      );
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _listModels() async {
    final s = context.read<SettingsService>();
    await _detect(announce: true);
    if (!mounted || _detected == null) return;
    final key = _key.text.trim().isEmpty ? (await s.getApiKey() ?? '') : _key.text.trim();
    if (!mounted) return;
    await showGeminiModelPicker(
      context,
      apiKey: key,
      currentModel: s.model,
    );
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
            onChanged: _onKeyChanged,
          ),
          if (_showKey)
            Text(
              'Unsaved changes - press Save + Test.',
              style: TextStyle(
                color: AppPalette.warning(Theme.of(context).colorScheme),
              ),
            ),
          const SizedBox(height: 8),
          // THE MODEL PICKER, FED BY THE KEY. The dropdown offers what this
          // key can actually use once detection has run; the button opens the
          // full picker with the recommendation. The static list is gone:
          // Google's newest model appears here on its own.
          DropdownButtonFormField<String>(
            key: ValueKey('model-${(_detected ?? const <String>[]).length}-${s.model}'),
            initialValue: s.model,
            items: modelChoices(s.model)
                .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                .toList(),
            onChanged: (v) => v == null ? null : s.setModel(v),
            decoration: InputDecoration(
              labelText: 'Model',
              helperText: _detectedNote ??
                  'Press "Save + Test Key" to detect the models this key '
                      'can use.',
              helperMaxLines: 2,
              suffixIcon: IconButton(
                tooltip: 'Detect models for this key and choose one',
                icon: const Icon(Icons.auto_awesome_outlined),
                onPressed: _busy ? null : _pickModel,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // THE CONTEXT KNOB. The ceiling lives in one documented constant
          // (ContextBudget.defaultContextTokens) and is overridable here.
          DropdownButtonFormField<int>(
            initialValue: s.contextBudget,
            items:
                (<int>{
                      32768,
                      131072,
                      ContextBudget.defaultContextTokens,
                      1048576,
                      s.contextBudget,
                    }.toList()
                    ..sort())
                .map(
                  (b) => DropdownMenuItem<int>(
                    value: b,
                    child: Text(
                      '${b ~/ 1024}k tokens'
                      '${b == ContextBudget.defaultContextTokens ? ' (default)' : ''}',
                    ),
                  ),
                )
                .toList(),
            onChanged: (v) => s.setContextBudget(v ?? s.contextBudget),
            decoration: const InputDecoration(
              labelText: 'Chat context budget (tokens)',
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'How much conversation the chat holds before older turns are '
              'summarized into memory. Default 256k.',
              style: TextStyle(
                fontSize: 12,
                color: AppPalette.mutedText(Theme.of(context).colorScheme),
              ),
            ),
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
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'GNS3 2.2+ requires HTTP auth by default (user admin). '
              'Credentials are sent as Basic auth on every GNS3 call.',
              style: TextStyle(
                fontSize: 12,
                color: AppPalette.mutedText(Theme.of(context).colorScheme),
              ),
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
            child: const Text('Detect available models for this key'),
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
