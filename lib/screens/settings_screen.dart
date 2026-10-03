import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/autopilot_service.dart';
import '../services/context_budget.dart';
import '../services/gemini_model_catalog.dart';
import '../services/gemini_service.dart';
import '../services/settings_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../widgets/gemini_model_picker.dart';
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
  bool _obscure = true;
  bool _obscureGns3 = true;
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
      final key = _key.text.trim();
      if (key.isEmpty) {
        _dirty = false;
        // Clearing the key means the chat answers offline. It does NOT turn
        // Private Mode on, and saying so was a promise the app did not keep.
        _say(
          'Key cleared. The chat answers from the offline assistant.',
          tone: AppTone.info,
        );
        return;
      }
      // Detect first: the saved model may be one this key cannot use, and
      // the recommendation is only trustworthy once the list is real.
      await _detect(announce: false);
      final detected = _detected;
      if (detected != null && !detected.contains(s.model)) {
        final best = GeminiModelCatalog.recommend([
          for (final n in detected) GeminiModelInfo(name: n),
        ]);
        if (best != null) {
          await s.setModel(best.name);
        }
      }
      final err = await GeminiService().testKey(apiKey: key, model: s.model);
      if (!mounted) return;
      // Push the credential AND the auto-learning switches now, so a toggle
      // takes effect without waiting for the next build to re-push it.
      try {
        await AutopilotService.of(context).pushLlmConfig(
          apiKey: key,
          model: s.model,
          enabled: key.isNotEmpty && !s.privateMode && s.llmFix,
          autoLearn: s.autoLearn,
          autoSuggest: s.autoLearn && s.autoSuggest,
          autoTeach: s.autoLearn && s.autoTeach,
        );
      } catch (_) {
        // The sidecar may be offline; the setting is saved regardless and
        // will ride along on the next build's push.
      }
      _dirty = false;
      _say(
        err == null
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
    await showGeminiModelPicker(
      context,
      apiKey: key,
      currentModel: s.model,
    );
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
                          Text('•  ', style: Theme.of(context).textTheme.bodySmall),
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
            'The app works with no key at all. A Gemini key only adds '
            'model-written answers on top of the offline planner and '
            'assistant.',
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
            label: Text(_busy ? 'Testing...' : 'Save + Test Key'),
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
                'Unsaved changes - press Save + Test Key to store them.',
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
          icon: Icons.key_outlined,
          title: 'API key',
          subtitle: 'Free keys: aistudio.google.com',
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
          icon: Icons.auto_awesome_outlined,
          title: 'Model and context',
          subtitle: _detectedNote ??
              'Press Save + Test Key to detect the models this key can use.',
          children: [
            AppField(
              label: 'Model',
              help: 'The dropdown lists what this key can actually use once '
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
              help: 'How much conversation the chat holds before older turns '
                  'are summarized into memory. Default 256k.',
              child: DropdownButtonFormField<int>(
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
                decoration: const InputDecoration(isDense: true),
              ),
            ),
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
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
      subtitle: 'The default target a new plan is compiled for.',
      children: [
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
        AppPanel(
          icon: Icons.hub_outlined,
          title: 'GNS3 server',
          subtitle: 'GNS3 2.2+ requires HTTP auth by default (user admin). '
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
                          onPressed: () => setState(
                            () => _obscureGns3 = !_obscureGns3,
                          ),
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
          subtitle: 'Kill-switch: disables Gemini + web search. Local only.',
          trailing: Switch(
            value: s.privateMode,
            onChanged: (v) => s.setPrivateMode(v),
          ),
          children: const [],
        ),
        AppPanel(
          icon: Icons.psychology_outlined,
          title: 'Learning',
          subtitle: 'Improvements are only ever trusted after they verify.',
          children: [
            _SwitchRow(
              title: 'Let the sidecar ask Gemini when stuck',
              subtitle:
                  'On a rejected command the sidecar asks Gemini for a '
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
              onSelectionChanged: (values) =>
                  s.setThemeMode(values.first),
            ),
          ],
        ),
      ],
    );
  }

  // --- about ---------------------------------------------------------------

  Widget _aboutPanel(SettingsService s) {
    final scheme = Theme.of(context).colorScheme;
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
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _showChangelog,
                  icon: const Icon(Icons.new_releases_outlined, size: 18),
                  label: const Text("What's new"),
                ),
                const SizedBox(width: AppTheme.s8),
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
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
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
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
