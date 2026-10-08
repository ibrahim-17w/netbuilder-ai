import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import '../theme/app_palette.dart';

/// One one-tap preset: a local runtime and the address its
/// OpenAI-compatible server listens on out of the box.
class _LocalPreset {
  final String label;
  final String url;
  const _LocalPreset(this.label, this.url);
}

/// The "Local model (fully offline)" subsection of the AI provider settings.
///
/// Ollama, LM Studio and llama.cpp always worked - they speak the
/// OpenAI-compatible dialect - but the only mention lived in the helper text
/// under Base URL, which is how first-class local support ends up buried.
/// This section makes the path explicit: pick the runtime, test it, and tap
/// a model id instead of retyping one.
///
/// The architecture is stated in the section rather than glossed over: the
/// app talks to a server the user runs. Nothing is bundled, nothing is
/// auto-started, and a phone cannot discover the PC on its own - so the
/// presets are correct starting points, not discoveries, and the app's
/// rule-based assistant keeps working when no server is there at all.
class LocalModelSection extends StatefulWidget {
  /// The drawer's Base URL controller: the test probes what the field shows
  /// (which may not be saved yet), not what storage holds.
  final TextEditingController baseUrl;

  /// The drawer's model-id field, kept in step when a model chip is tapped.
  final TextEditingController modelId;

  final SettingsService settings;

  /// Long notes go to the host's snackbar (the drawer's `_toast`) rather
  /// than stacking more standing text into an already full sidebar.
  final void Function(String message) onNote;

  const LocalModelSection({
    super.key,
    required this.settings,
    required this.baseUrl,
    required this.modelId,
    required this.onNote,
  });

  @override
  State<LocalModelSection> createState() => _LocalModelSectionState();
}

class _LocalModelSectionState extends State<LocalModelSection> {
  /// The three runtimes people actually run locally. The addresses are each
  /// server's documented default, not a guess - and they are what the
  /// failure messages in [LocalModelProber] assume when a port is known.
  static const List<_LocalPreset> _presets = [
    _LocalPreset('Ollama', 'http://127.0.0.1:11434/v1'),
    _LocalPreset('LM Studio', 'http://127.0.0.1:1234/v1'),
    _LocalPreset('llama.cpp', 'http://127.0.0.1:8080/v1'),
  ];

  bool _testing = false;

  /// The last probe result. Ephemeral on purpose: it describes a server
  /// that can be stopped the moment this drawer closes, so it is never
  /// persisted - the only thing saved is the base URL itself.
  LocalModelProbe? _probe;

  /// The address the result describes, so a field edited afterwards cannot
  /// present an old verdict as current.
  String? _probedBase;

  @override
  void initState() {
    super.initState();
    // The field can be edited after a test ran; listening (not polling the
    // server) is what keeps the reachable tag honest without waiting for
    // some other rebuild to happen along.
    widget.baseUrl.addListener(_fieldChanged);
  }

  void _fieldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.baseUrl.removeListener(_fieldChanged);
    super.dispose();
  }

  Future<void> _usePreset(_LocalPreset preset) async {
    final s = widget.settings;
    // The presets exist to un-bury local models, so the first tap also
    // moves off Gemini: a chip that needed a second manual switch in the
    // dropdown would not be one tap.
    if (!s.usesOpenAi) await s.setProviderName('openai');
    await s.setOpenAiBaseUrl(preset.url);
    setState(() {
      widget.baseUrl.text = preset.url;
      // A new address invalidates whatever the last probe saw.
      _probe = null;
      _probedBase = null;
    });
    // A saved cloud key is left alone on purpose: localhost ignores it, and
    // deleting credentials the user may want back is not a preset's job.
    widget.onNote('${preset.label} set as the base URL. A local server '
        'needs no API key - leave the key field empty.');
  }

  Future<void> _test() async {
    final base = widget.baseUrl.text.trim();
    setState(() {
      _testing = true;
      _probe = null;
    });
    final result = await LocalModelProber.probe(baseUrl: base);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _probe = result;
      _probedBase = base;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final theme = Theme.of(context);
    final base = widget.baseUrl.text.trim();
    // The indicator only claims what was actually seen: this exact address,
    // probed by hand, with the field untouched since. No polling - a server
    // that stops after the test says so in the chat, not in a light here.
    final reachable = _probe != null &&
        _probe!.reachable &&
        _probedBase == base &&
        LocalModelProber.isLocal(base);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                'Local model (fully offline)',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (reachable) ...[
              const SizedBox(width: 6),
              Icon(
                Icons.check_circle_outline,
                size: 14,
                color: AppPalette.success(theme.colorScheme),
              ),
              const SizedBox(width: 2),
              Text(
                'reachable',
                style: TextStyle(
                  fontSize: 11,
                  color: AppPalette.success(theme.colorScheme),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final preset in _presets)
              ActionChip(
                label: Text(preset.label),
                tooltip: preset.url,
                onPressed: () => _usePreset(preset),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          // The honest shape of the feature: a local server the user runs,
          // reached the same way a cloud gateway is - and no server at all
          // is a supported state, not an error.
          'The app talks to a model server you run yourself; none is '
          'bundled or started by the app. With no server at all, the '
          'rule-based assistant still answers.'
          '${SettingsService.isMobile ? ' On a phone, 127.0.0.1 is the '
                'phone itself - use the PC\'s LAN address, or 10.0.2.2 in '
                'the Android emulator.' : ''}',
          style: TextStyle(
            fontSize: 12,
            color: AppPalette.mutedText(theme.colorScheme),
          ),
        ),
        if (s.usesOpenAi) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _testing ? null : _test,
            child: const Text('Test local server'),
          ),
          if (_testing)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_probe != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _probe!.message,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          // A successful test is also the model list. Tapping an id puts it
          // in the Model id field and saves it, which is the difference
          // between "the server is up" and a setup that can chat.
          if (_probe != null && _probe!.reachable && _probe!.models.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final id in _probe!.models)
                    ActionChip(
                      label: Text(id),
                      tooltip: 'Use this model',
                      onPressed: () {
                        widget.modelId.text = id;
                        s.setOpenAiModel(id);
                        widget.onNote('Model set to $id.');
                      },
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}
