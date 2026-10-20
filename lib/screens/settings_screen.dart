import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/autopilot_service.dart';
import '../services/context_budget.dart';
import '../services/gemini_model_catalog.dart';
import '../services/gemini_service.dart';
import '../services/engine_configuration_sync.dart';
import '../services/provider_chat_service.dart';
import '../services/pkt/pkt_export_service.dart';
import '../services/packet_tracer/catalog.dart';
import '../services/settings_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../widgets/gemini_model_picker.dart';
import '../widgets/local_model_section.dart';
import '../widgets/whats_new.dart';

/// Everything that configures the app, in one place, grouped by the question
/// a person is actually asking:
///
/// * *Can it think?* - the model, the key, the context it may use.
/// * *Where does it build?* - the target and the GNS3 credentials.
/// * *What may it do on its own?* - private mode and the learning switches.
/// * *How does it look?* - the theme.
/// * *Is it working?* - the connection test and the autopilot requirements.
///
/// The screen this replaces was one column of seventeen controls in the order
/// they had been added, with the key field first and the explanation last.
/// Nothing was wrong with the controls; the order was. Every control is still
/// here - it is just findable now.
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
  final _openAiBase = TextEditingController();
  final _openAiModel = TextEditingController();
  final _openAiKey = TextEditingController();
  final _openAiHeaders = TextEditingController();
  final _openAiOrganization = TextEditingController();
  final _engine = TextEditingController();
  final _outputDir = TextEditingController();
  final _pktVersion = TextEditingController();
  bool _obscure = true;
  bool _obscureGns3 = true;
  bool _obscureOpenAi = true;
  bool _testingEngine = false;
  String? _engineTest;
  String _status = '';

  /// What the last status line was: an error is red, a success green and a
  /// neutral note grey. Without this a failed key test looked exactly like a
  /// saved one.
  AppTone _statusTone = AppTone.info;
  bool _busy = false;

  /// True while what is on screen differs from what is stored. Cleared by a
  /// successful save: the warning is a claim about the stored value, and a
  /// warning that survives a successful save is a lie the user has to learn to
  /// ignore.
  bool _dirty = false;

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
    _openAiBase.dispose();
    _openAiModel.dispose();
    _openAiKey.dispose();
    _openAiHeaders.dispose();
    _openAiOrganization.dispose();
    _engine.dispose();
    _outputDir.dispose();
    _pktVersion.dispose();
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

  void _say(String message, {AppTone tone = AppTone.info}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusTone = tone;
    });
  }

  /// Detect what this key can use, then recommend the latest stable model.
  /// Runs on save, on opening the picker, and (debounced) while typing a key.
  Future<void> _detect({bool announce = true}) async {
    final s = context.read<SettingsService>();
    final key = _key.text.trim().isEmpty
        ? (await s.getApiKey() ?? '')
        : _key.text.trim();
    if (!mounted) return;
    setState(() {
      if (announce) {
        _busy = true;
        _status = 'Detecting the models this key can use...';
        _statusTone = AppTone.info;
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
        if (announce) {
          _status = _detectedNote!;
          _statusTone = models.isEmpty ? AppTone.warning : AppTone.success;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _detected = null;
        _detectedNote = e.toString().replaceFirst('Exception: ', '');
        if (announce) {
          _status = _detectedNote!;
          _statusTone = AppTone.danger;
        }
      });
    } finally {
      if (mounted && announce) setState(() => _busy = false);
    }
  }

  void _onKeyChanged(String value) {
    setState(() => _dirty = true);
    _detectDebounce?.cancel();
    _detectDebounce = Timer(const Duration(milliseconds: 1200), () {
      if (value.trim().length >= 20) _detect(announce: false);
    });
  }

  /// Open the picker, and store the chosen model.
  Future<void> _pickModel() async {
    final s = context.read<SettingsService>();
    final key = _key.text.trim().isEmpty
        ? (await s.getApiKey() ?? '')
        : _key.text.trim();
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
    _say('Model set to ${chosen.trim()}.', tone: AppTone.success);
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final s = context.read<SettingsService>();
    final k = await s.getApiKey();
    final openAiKey = await s.getOpenAiKey();
    _key.text = k ?? '';
    _gns3.text = s.gns3Endpoint;
    _gns3User.text = s.gns3User;
    _gns3Pass.text = s.gns3Pass;
    _openAiBase.text = s.openAiBaseUrl;
    _openAiModel.text = s.openAiModel;
    _openAiKey.text = openAiKey ?? '';
    _openAiHeaders.text = s.openAiHeaders;
    _openAiOrganization.text = s.openAiOrganization;
    _engine.text = s.engineBase;
    _outputDir.text = s.outputDir;
    _pktVersion.text = s.packetTracerVersion;
    if (mounted) setState(() {});
  }

  Future<void> _saveAndTest() async {
    setState(() {
      _busy = true;
      _status = 'Saving + testing...';
      _statusTone = AppTone.info;
    });
    try {
      final s = context.read<SettingsService>();
      // setApiKey answers whether the value survived the round trip, so the
      // screen never says "saved" about a write that did not stick.
      final stored = await s.setApiKey(_key.text);
      if (!stored) {
        _say(
          'The key could not be read back from secure storage, so it was not '
          'saved. Re-enter it, and check the platform keychain if this '
          'repeats.',
          tone: AppTone.danger,
        );
        return;
      }
      await s.setGns3Endpoint(_gns3.text);
      await s.setGns3Credentials(_gns3User.text, _gns3Pass.text);
      await s.setOpenAiBaseUrl(_openAiBase.text);
      await s.setOpenAiModel(_openAiModel.text);
      await s.setOpenAiOrganization(_openAiOrganization.text);
      final headersSaved = await s.setOpenAiHeaders(_openAiHeaders.text);
      final openAiSaved = await s.setOpenAiKey(_openAiKey.text);
      if (!headersSaved || !openAiSaved) {
        _say(
          'Provider credentials could not be read back from secure storage. Check the device keychain and try again.',
          tone: AppTone.danger,
        );
        return;
      }
      final key = _key.text.trim();
      String? err;
      String? providerResult;
      if (s.usesOpenAi) {
        final result = await ProviderChatService(
          config: s.providerConfig,
          geminiKey: await s.getApiKey() ?? '',
          openaiKey: await s.getOpenAiKey() ?? '',
          contextTokens: s.contextBudget,
        ).testConnection();
        providerResult = '${result['message'] ?? 'No response from provider.'}';
        if (result['ok'] != true) err = providerResult;
      } else if (key.isNotEmpty) {
        // Detect first: the saved model may be one this key cannot use, and
        // the recommendation is only trustworthy once the list is real.
        await _detect(announce: false);
        final detected = _detected;
        if (detected != null && !detected.contains(s.model)) {
          final best = GeminiModelCatalog.recommend([
            for (final n in detected) GeminiModelInfo(name: n),
          ]);
          if (best != null) await s.setModel(best.name);
        }
        err = await GeminiService().testKey(apiKey: key, model: s.model);
      }
      if (!mounted) return;
      // Push the credential AND the auto-learning switches now, so a toggle
      // takes effect without waiting for the next build to re-push it.
      try {
        if (!SettingsService.isMobile) {
          await EngineConfigurationSync.push(s, AutopilotService.of(context));
        }
      } catch (_) {
        // The sidecar may be offline; the setting is saved regardless and
        // will ride along on the next build's push.
      }
      _dirty = false;
      _say(
        s.usesOpenAi
            ? err == null
                  ? 'Provider settings saved and the connection answered.'
                  : 'Provider test failed: $err'
            : key.isEmpty
            ? 'Settings saved. The chat answers from the offline assistant.'
            : err == null
            ? 'Key valid for ${s.model}. ${_detectedNote ?? ''}'.trim()
            : 'Key test failed: $err',
        tone: err == null ? AppTone.success : AppTone.danger,
      );
    } catch (e) {
      _say('Error: $e', tone: AppTone.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _listModels() async {
    final s = context.read<SettingsService>();
    await _detect(announce: true);
    if (!mounted || _detected == null) return;
    final key = _key.text.trim().isEmpty
        ? (await s.getApiKey() ?? '')
        : _key.text.trim();
    if (!mounted) return;
    await showGeminiModelPicker(context, apiKey: key, currentModel: s.model);
  }

  Future<void> _showChangelog() async {
    final s = context.read<SettingsService>();
    if (kChangelogEntries.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("What's new"),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final entry in kChangelogEntries) ...[
                  Text(
                    '${entry.version}  -  ${entry.date}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppTheme.s6),
                  for (final change in entry.changes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '•  ',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Expanded(
                            child: Text(
                              change,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: AppTheme.s12),
                ],
                Text(
                  'Seen version: ${s.seenChangelog.isEmpty ? 'none' : s.seenChangelog}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await s.markChangelogSeen(kChangelogEntries.first.version);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Mark as seen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService>();
    return AppPage(
      maxWidth: 900,
      header: AppPageHeader(
        eyebrow: 'Configure',
        title: 'Settings',
        description:
            'One place for provider, privacy, Packet Tracer, file, and appearance settings.',
        actions: [
          FilledButton.icon(
            onPressed: _busy ? null : _saveAndTest,
            icon: _busy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_busy ? 'Testing...' : 'Save + test provider'),
          ),
        ],
      ),
      children: [
        if (_status.trim().isNotEmpty)
          AppBanner(
            tone: _statusTone,
            icon: _statusTone == AppTone.info ? Icons.sync : null,
            message: _status,
          ),
        if (_dirty)
          AppBanner(
            tone: AppTone.warning,
            message:
                'Unsaved changes - press Save + test provider to store them.',
          ),
        _modelPanel(s),
        _targetsPanel(s),
        _automationPanel(s),
        _appearancePanel(s),
        _aboutPanel(s),
      ],
    );
  }

  // --- model access --------------------------------------------------------

  Widget _modelPanel(SettingsService s) {
    final scheme = Theme.of(context).colorScheme;
    return AppSection(
      title: 'Model access (BYOK)',
      subtitle: 'Optional. Keys are stored in the OS keychain, never logged.',
      children: [
        AppPanel(
          icon: Icons.smart_toy_outlined,
          title: 'Active assistant',
          subtitle:
              'Choose the service used for model-written answers. Planning and local .pkt tools still work without a key.',
          children: [
            DropdownButtonFormField<String>(
              initialValue: s.providerName,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'AI provider'),
              items: const [
                DropdownMenuItem(value: 'gemini', child: Text('Google Gemini')),
                DropdownMenuItem(
                  value: 'openai',
                  child: Text('OpenAI-compatible provider'),
                ),
              ],
              onChanged: (value) {
                if (value != null) s.setProviderName(value);
              },
            ),
          ],
        ),
        AppPanel(
          icon: Icons.key_outlined,
          title: 'API key',
          subtitle: 'Gemini key · Free keys: aistudio.google.com',
          trailing: AppTag(
            label: _key.text.trim().isEmpty ? 'offline' : 'key set',
            tone: _key.text.trim().isEmpty ? AppTone.neutral : AppTone.success,
          ),
          children: [
            TextField(
              controller: _key,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'Gemini API key',
                hintText: 'AIza...',
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
                      onPressed: () => setState(() {
                        _key.clear();
                        _dirty = true;
                      }),
                    ),
                  ],
                ),
              ),
              onChanged: _onKeyChanged,
            ),
          ],
        ),
        AppPanel(
          icon: Icons.cloud_outlined,
          title: 'OpenAI-compatible provider',
          subtitle:
              'Optional. Supports hosted gateways and local runtimes such as Ollama.',
          children: [
            TextField(
              controller: _openAiBase,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.groq.com/openai/v1',
              ),
              onChanged: (_) => setState(() => _dirty = true),
            ),
            const SizedBox(height: AppTheme.s8),
            TextField(
              controller: _openAiModel,
              decoration: const InputDecoration(labelText: 'Model id'),
              onChanged: (_) => setState(() => _dirty = true),
            ),
            const SizedBox(height: AppTheme.s8),
            TextField(
              controller: _openAiOrganization,
              decoration: const InputDecoration(
                labelText: 'Organization (optional)',
              ),
              onChanged: (_) => setState(() => _dirty = true),
            ),
            const SizedBox(height: AppTheme.s8),
            TextField(
              controller: _openAiKey,
              obscureText: _obscureOpenAi,
              decoration: InputDecoration(
                labelText: 'Provider API key',
                helperText: 'Leave empty to clear the saved key.',
                suffixIcon: IconButton(
                  tooltip: _obscureOpenAi ? 'Show key' : 'Hide key',
                  onPressed: () =>
                      setState(() => _obscureOpenAi = !_obscureOpenAi),
                  icon: Icon(
                    _obscureOpenAi ? Icons.visibility : Icons.visibility_off,
                  ),
                ),
              ),
              onChanged: (_) => setState(() => _dirty = true),
            ),
            const SizedBox(height: AppTheme.s8),
            TextField(
              controller: _openAiHeaders,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Extra headers (optional)',
                helperText: 'One Header: value pair per line.',
              ),
              onChanged: (_) => setState(() => _dirty = true),
            ),
            const SizedBox(height: AppTheme.s8),
            LocalModelSection(
              settings: s,
              baseUrl: _openAiBase,
              modelId: _openAiModel,
              onNote: (message) => _say(message, tone: AppTone.info),
            ),
          ],
        ),
        AppPanel(
          icon: Icons.auto_awesome_outlined,
          title: 'Model and context',
          subtitle:
              _detectedNote ??
              'Press Save + Test Key to detect the models this key can use.',
          children: [
            if (!s.usesOpenAi)
              AppField(
                label: 'Model',
                help:
                    'The dropdown lists what this key can actually use once '
                    'detection has run.',
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(
                          'model-${(_detected ?? const <String>[]).length}-${s.model}',
                        ),
                        initialValue: s.model,
                        items: modelChoices(s.model)
                            .map(
                              (m) => DropdownMenuItem(value: m, child: Text(m)),
                            )
                            .toList(),
                        onChanged: (v) => v == null ? null : s.setModel(v),
                        decoration: const InputDecoration(isDense: true),
                      ),
                    ),
                    const SizedBox(width: AppTheme.s8),
                    IconButton.filledTonal(
                      tooltip: 'Detect models for this key and choose one',
                      onPressed: _busy ? null : _pickModel,
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                    ),
                  ],
                ),
              ),
            AppField(
              label: 'Chat context budget',
              help:
                  'How much conversation the chat holds before older turns '
                  'are summarized into memory. Default 256k.',
              child: DropdownButtonFormField<int>(
                initialValue: s.contextBudget,
                isExpanded: true,
                items:
                    (<int>{
                          32768,
                          131072,
                          ContextBudget.defaultContextTokens,
                          1048576,
                          s.contextBudget,
                        }.toList()..sort())
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
                decoration: const InputDecoration(isDense: true),
              ),
            ),
            if (!SettingsService.isMobile)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Include live run context in chat'),
                subtitle: const Text(
                  'Adds the current Packet Tracer run summary to relevant prompts.',
                ),
                value: s.liveContext,
                onChanged: s.setLiveContext,
              ),
            AppField(
              label: 'Runtime context window',
              help:
                  'Detect automatically unless you need to set the model runtime window yourself.',
              child: DropdownButtonFormField<int>(
                initialValue: s.runtimeWindow,
                isExpanded: true,
                items:
                    (<int>{
                          0,
                          2048,
                          4096,
                          8192,
                          16384,
                          32768,
                          131072,
                          s.runtimeWindow,
                        }.toList()..sort())
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(
                              value == 0
                                  ? 'Detect automatically'
                                  : '${value ~/ 1024}k tokens',
                            ),
                          ),
                        )
                        .toList(),
                onChanged: (value) => s.setRuntimeWindow(value ?? 0),
                decoration: const InputDecoration(isDense: true),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Show context diagnostics in the debug console',
              ),
              value: s.contextDebug,
              onChanged: s.setContextDebug,
            ),
            if (!s.usesOpenAi)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _listModels,
                      icon: const Icon(Icons.list_alt_outlined, size: 18),
                      label: const Text('Browse available models'),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: AppTheme.s6),
            Text(
              'With no key the chat answers from the offline assistant and '
              'the planner stays deterministic - the app never needs a key '
              'to work.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }

  // --- targets -------------------------------------------------------------

  Widget _targetsPanel(SettingsService s) {
    return AppSection(
      title: 'Where builds go',
      subtitle: 'Choose the builder and compatibility reference used by plans.',
      children: [
        AppPanel(
          icon: Icons.memory_outlined,
          title: 'Packet Tracer compatibility',
          subtitle:
              'The bundled device templates are sourced from Packet Tracer ${PacketTracerCatalog.instance.version}. Set the version installed on your PC to see compatibility warnings in the catalog.',
          children: [
            TextField(
              controller: _pktVersion,
              decoration: const InputDecoration(
                labelText: 'Installed Packet Tracer version',
                hintText: 'For example, 9.0.0.0810',
                helperText: 'Leave blank when unknown.',
              ),
              onSubmitted: (value) => s.setPacketTracerVersion(value),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () async {
                  await s.setPacketTracerVersion(_pktVersion.text);
                  if (mounted) {
                    _say('Packet Tracer version saved.', tone: AppTone.success);
                  }
                },
                icon: const Icon(Icons.save_outlined, size: 17),
                label: const Text('Save version'),
              ),
            ),
          ],
        ),
        AppPanel(
          icon: Icons.device_hub_outlined,
          title: 'Packet Tracer build engine',
          subtitle: SettingsService.engineHint(_engine.text),
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                SettingsService.isMobile
                    ? 'Build .pkt files on this device'
                    : 'Prefer on-device .pkt building',
              ),
              subtitle: Text(
                SettingsService.isMobile
                    ? 'Uses the bundled templates. Turn this off to use the PC engine below.'
                    : 'Uses bundled templates first; the PC engine is still available for live Packet Tracer runs.',
              ),
              value: s.preferOnDevicePkt,
              onChanged: s.setPreferOnDevicePkt,
            ),
            TextField(
              controller: _engine,
              decoration: InputDecoration(
                labelText: SettingsService.isMobile
                    ? 'PC engine address (optional)'
                    : 'Engine address',
                helperText: SettingsService.engineHint(_engine.text),
                helperMaxLines: 4,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppTheme.s8),
            Wrap(
              spacing: AppTheme.s8,
              runSpacing: AppTheme.s8,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    await s.setEngineBase(_engine.text);
                    if (!mounted) return;
                    if (s.engineBaseError.isNotEmpty) {
                      _say(s.engineBaseError, tone: AppTone.danger);
                    } else {
                      _engine.text = s.engineBase;
                      _say('Engine address saved.', tone: AppTone.success);
                    }
                  },
                  icon: const Icon(Icons.save_outlined, size: 17),
                  label: const Text('Save address'),
                ),
                OutlinedButton.icon(
                  onPressed: _testingEngine ? null : _testEngine,
                  icon: _testingEngine
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering_outlined, size: 17),
                  label: const Text('Test connection'),
                ),
              ],
            ),
            if (_engineTest != null)
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.s8),
                child: Text(_engineTest!),
              ),
          ],
        ),
        AppPanel(
          icon: Icons.folder_outlined,
          title: 'Generated .pkt files',
          subtitle: SettingsService.isMobile
              ? 'Android asks where each generated file should be saved.'
              : 'Choose the default folder for generated and repaired files.',
          children: [
            if (!SettingsService.isMobile) ...[
              TextField(
                controller: _outputDir,
                decoration: const InputDecoration(
                  labelText: 'Output folder',
                  helperText: 'Leave empty to use the engine default folder.',
                ),
              ),
              Wrap(
                spacing: AppTheme.s8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _chooseOutputFolder(s),
                    icon: const Icon(Icons.folder_open_outlined, size: 17),
                    label: const Text('Choose folder'),
                  ),
                  FilledButton.tonal(
                    onPressed: () async {
                      await s.setOutputDir(_outputDir.text);
                      if (mounted) {
                        _say('Output folder saved.', tone: AppTone.success);
                      }
                    },
                    child: const Text('Save folder'),
                  ),
                ],
              ),
            ] else
              const Text(
                'After a file is ready, use Save to choose a destination through Android.',
              ),
          ],
        ),
        AppPanel(
          icon: Icons.device_hub_outlined,
          title: 'Default target',
          children: [
            Wrap(
              spacing: AppTheme.s8,
              runSpacing: AppTheme.s8,
              children: [
                for (final target in SettingsService.supportedTargets)
                  ChoiceChip(
                    label: Text(target),
                    avatar: Icon(_targetIcon(target), size: 15),
                    selected: s.defaultTarget == target,
                    onSelected: (_) => s.setDefaultTarget(target),
                  ),
              ],
            ),
          ],
        ),
        if (!SettingsService.isMobile)
          AppPanel(
            icon: Icons.hub_outlined,
            title: 'GNS3 server',
            subtitle:
                'GNS3 2.2+ requires HTTP auth by default (user admin). '
                'Credentials are sent as Basic auth on every call.',
            children: [
              AppField(
                label: 'Endpoint',
                child: TextField(
                  controller: _gns3,
                  decoration: const InputDecoration(
                    hintText: 'http://127.0.0.1:3080',
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppField(
                      label: 'User',
                      child: TextField(
                        controller: _gns3User,
                        decoration: const InputDecoration(hintText: 'admin'),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppTheme.s10),
                  Expanded(
                    child: AppField(
                      label: 'Password',
                      child: TextField(
                        controller: _gns3Pass,
                        obscureText: _obscureGns3,
                        decoration: InputDecoration(
                          suffixIcon: IconButton(
                            tooltip: 'show/hide',
                            icon: Icon(
                              _obscureGns3
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                            onPressed: () =>
                                setState(() => _obscureGns3 = !_obscureGns3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _testEngine() async {
    final address = _engine.text.trim();
    setState(() {
      _testingEngine = true;
      _engineTest = 'Checking $address…';
    });
    String result;
    try {
      final healthy = await AutopilotService(base: address).healthy;
      result = healthy
          ? 'Connected to $address.'
          : 'No response from $address. Check that the PC sidecar is running and both devices can reach it.';
    } catch (error) {
      result =
          'Could not reach $address: ${error.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() {
      _testingEngine = false;
      _engineTest = result;
    });
  }

  Future<void> _chooseOutputFolder(SettingsService settings) async {
    String? selected;
    try {
      selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose a folder for Packet Tracer files',
      );
    } catch (error) {
      _say('Could not open the folder picker: $error', tone: AppTone.warning);
      return;
    }
    if (selected == null || selected.trim().isEmpty) return;
    final resolved = await PktExportService.resolveFolder(selected);
    if (resolved.dir == null) {
      _say('That folder cannot be used: ${resolved.why}', tone: AppTone.danger);
      return;
    }
    _outputDir.text = resolved.dir!.path;
    await settings.setOutputDir(resolved.dir!.path);
    if (mounted) _say('Output folder saved.', tone: AppTone.success);
  }

  static IconData _targetIcon(String target) => switch (target) {
    'packet-tracer' => Icons.wifi_tethering,
    'cisco' => Icons.terminal_outlined,
    'aws' => Icons.cloud_outlined,
    _ => Icons.hub_outlined,
  };

  // --- automation ----------------------------------------------------------

  Widget _automationPanel(SettingsService s) {
    return AppSection(
      title: 'Privacy and automation',
      subtitle: 'What the app may do without being asked.',
      children: [
        AppPanel(
          icon: Icons.lock_outline,
          title: 'Private / Offline Mode',
          subtitle:
              'Disables model requests and web search. Local planning only.',
          trailing: Switch(
            value: s.privateMode,
            onChanged: (v) => s.setPrivateMode(v),
          ),
          children: [
            if (context.watch<EngineConfigurationSync?>()?.error.isNotEmpty ??
                false)
              Text(context.watch<EngineConfigurationSync?>()!.error),
          ],
        ),
        if (!SettingsService.isMobile)
          AppPanel(
            icon: Icons.psychology_outlined,
            title: 'Learning',
            subtitle: 'Improvements are only ever trusted after they verify.',
            children: [
              _SwitchRow(
                title: 'Let the engine ask the selected model when stuck',
                subtitle:
                    'On a rejected command the engine asks your selected model for a '
                    'replacement, tries it, and remembers it only if the '
                    'terminal proves it worked. Off in Private Mode.',
                value: s.llmFix,
                onChanged: (v) => s.setLlmFix(v),
              ),
              const AppDivider(),
              _SwitchRow(
                title: 'Learn automatically',
                subtitle:
                    'After a run that keeps failing the same way, the engine '
                    'looks for a fix on its own - no button press. A fix is '
                    'still only trusted after it verifies on screen.',
                value: s.autoLearn,
                onChanged: (v) => s.setAutoLearn(v),
              ),
              _SwitchRow(
                indent: true,
                title: 'Propose fixes after a failing run',
                subtitle:
                    'When a run ends with recurring failures, ask the model '
                    'for a hypothesis without waiting for you to press '
                    'Suggest.',
                value: s.autoSuggest,
                onChanged: s.autoLearn ? (v) => s.setAutoSuggest(v) : null,
              ),
              _SwitchRow(
                indent: true,
                title: 'Verify fixes on screen automatically',
                subtitle:
                    'Run one bounded teach pass to prove a proposed fix on '
                    'the real Packet Tracer window, and promote it only if the '
                    'screen agrees.',
                value: s.autoTeach,
                onChanged: s.autoLearn ? (v) => s.setAutoTeach(v) : null,
              ),
            ],
          ),
      ],
    );
  }

  // --- appearance ----------------------------------------------------------

  Widget _appearancePanel(SettingsService s) {
    return AppSection(
      title: 'Appearance',
      subtitle: 'The theme applies everywhere at once.',
      children: [
        AppPanel(
          icon: Icons.palette_outlined,
          title: 'Theme',
          children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: 'system',
                  icon: Icon(Icons.brightness_auto_outlined, size: 16),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: 'light',
                  icon: Icon(Icons.light_mode_outlined, size: 16),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: 'dark',
                  icon: Icon(Icons.dark_mode_outlined, size: 16),
                  label: Text('Dark'),
                ),
              ],
              selected: {
                const ['system', 'light', 'dark'].contains(s.themeMode)
                    ? s.themeMode
                    : 'system',
              },
              onSelectionChanged: (values) => s.setThemeMode(values.first),
            ),
          ],
        ),
      ],
    );
  }

  // --- about ---------------------------------------------------------------

  Widget _aboutPanel(SettingsService s) {
    final scheme = Theme.of(context).colorScheme;
    if (SettingsService.isMobile) {
      return AppSection(
        title: 'About and requirements',
        subtitle: 'Tools that run here, and what needs a computer.',
        children: [
          AppPanel(
            icon: Icons.phone_android_outlined,
            tone: AppTone.success,
            title: 'Available on this phone',
            children: const [
              _Requirement(
                icon: Icons.hub_outlined,
                text: 'Plan and preview network designs.',
              ),
              _Requirement(
                icon: Icons.category_outlined,
                text: 'Browse Packet Tracer device and cable models.',
              ),
              _Requirement(
                icon: Icons.save_outlined,
                text: 'Build .pkt files locally and save them through Android.',
              ),
              _Requirement(
                icon: Icons.calculate_outlined,
                text: 'Use network calculations and plan checks offline.',
              ),
            ],
          ),
          AppPanel(
            icon: Icons.desktop_windows_outlined,
            title: 'Needs a computer',
            children: const [
              _Requirement(
                icon: Icons.mouse_outlined,
                text:
                    'Controlling a live Packet Tracer window and reading its CLI.',
              ),
              _Requirement(
                icon: Icons.pause_circle_outline,
                text: 'Starting, pausing, or stopping a live desktop run.',
              ),
            ],
          ),
          AppPanel(
            icon: Icons.folder_outlined,
            title: 'Saving files',
            children: const [
              _Requirement(
                icon: Icons.save_alt_outlined,
                text:
                    'Android asks where each finished .pkt file should be saved.',
              ),
            ],
          ),
        ],
      );
    }
    return AppSection(
      title: 'About and requirements',
      subtitle: 'Packet Tracer automation needs a specific setup.',
      children: [
        AppPanel(
          icon: Icons.sports_esports_outlined,
          title: 'PT Autopilot requirements',
          tone: AppTone.info,
          children: [
            _Requirement(
              icon: Icons.open_in_full,
              text: 'Packet Tracer open, maximized and focused',
            ),
            _Requirement(
              icon: Icons.desktop_windows_outlined,
              text: 'Display at 100% scaling, no overlays',
            ),
            _Requirement(
              icon: Icons.mouse_outlined,
              text: 'Do not touch mouse or keyboard during a run',
            ),
            _Requirement(
              icon: Icons.terminal_outlined,
              text: 'Sidecar: python sidecar/pt_autopilot.py',
            ),
            const SizedBox(height: AppTheme.s8),
            Wrap(
              spacing: AppTheme.s8,
              runSpacing: AppTheme.s8,
              children: [
                OutlinedButton.icon(
                  onPressed: _showChangelog,
                  icon: const Icon(Icons.new_releases_outlined, size: 18),
                  label: const Text("What's new"),
                ),
                OutlinedButton.icon(
                  onPressed: () => FirstRunTour(settings: s).show(context),
                  icon: const Icon(Icons.tour_outlined, size: 18),
                  label: const Text('Replay the tour'),
                ),
              ],
            ),
          ],
        ),
        AppPanel(
          icon: Icons.folder_outlined,
          title: 'Where your data lives',
          children: [
            AppKeyValue(
              label: 'Memory database',
              value: '%USERPROFILE%\\Documents\\netbuilder\\memory.db',
              mono: true,
            ),
            const AppKeyValue(
              label: 'API keys',
              value: 'OS secure storage (Windows Credential Manager)',
            ),
            const AppKeyValue(
              label: 'Built .pkt files',
              value: "The engine's pkt_output folder, with a manifest",
            ),
            const SizedBox(height: AppTheme.s8),
            Text(
              'Nothing leaves this machine unless a model call is made, and '
              'Private Mode stops those entirely.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

/// A switch with a title and an explanation, laid out like a settings row
/// rather than a `ListTile` with its own padding rules.
class _SwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool indent;

  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.indent = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: indent ? AppTheme.s16 : 0,
        top: AppTheme.s4,
        bottom: AppTheme.s4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: onChanged == null
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.s12),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _Requirement extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Requirement({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppTheme.s8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
