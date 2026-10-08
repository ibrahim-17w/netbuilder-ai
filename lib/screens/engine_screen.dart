import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/engine_status.dart';
import '../services/settings_service.dart';
import '../theme/app_kit.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';

/// Everything about the local .pkt engine, in one place.
///
/// The engine is optional by design: planning, subnet math, live diagnostics,
/// .pkt generation and .pkt auditing all run on this device without it. The
/// engine is what *drives the Packet Tracer window* (and reads its CLI by
/// OCR), so this screen says what is available, starts the engine when it is
/// not, and shows its own log when a start fails.
class EngineScreen extends StatefulWidget {
  final SettingsService? settings;

  const EngineScreen({super.key, this.settings});

  @override
  State<EngineScreen> createState() => _EngineScreenState();
}

class _EngineScreenState extends State<EngineScreen> {
  final _address = TextEditingController();
  String _log = '';
  bool _busy = false;

  EngineStatus get _engine => EngineStatus.instance;

  @override
  void initState() {
    super.initState();
    _address.text = widget.settings?.engineBase ?? _engine.base;
    _engine.addListener(_onEngine);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _engine.probe(force: true);
      await _loadLog();
    });
  }

  @override
  void dispose() {
    _engine.removeListener(_onEngine);
    _address.dispose();
    super.dispose();
  }

  void _onEngine() {
    if (mounted) setState(() {});
  }

  Future<void> _loadLog() async {
    final text = await _engine.readLogTail(lines: 80);
    if (mounted) setState(() => _log = text);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await _loadLog();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyAddress() async {
    final value = _address.text.trim();
    if (value.isEmpty) return;
    await widget.settings?.setEngineBase(value);
    _engine.setBase(value);
    await _run(() => _engine.probe(force: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Local engine'),
        actions: [
          IconButton(
            tooltip: 'Check now',
            icon: const Icon(Icons.refresh),
            onPressed: _busy
                ? null
                : () => _run(() => _engine.probe(force: true)),
          ),
        ],
      ),
      body: AppPage(
        maxWidth: 1000,
        children: [
          _statusHero(),
          _actionsPanel(),
          _addressPanel(),
          _capabilityPanel(),
          _logPanel(),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Status
  // -------------------------------------------------------------------------

  _EnginePhase _phase() => switch (_engine.phase) {
    EngineState.up => _EnginePhase(
      tone: AppTone.success,
      label: 'Running',
      icon: Icons.check_circle_outline,
    ),
    EngineState.down => _EnginePhase(
      tone: AppTone.danger,
      label: 'Not running',
      icon: Icons.cloud_off_outlined,
    ),
    EngineState.checking => _EnginePhase(
      tone: AppTone.info,
      label: 'Checking...',
      icon: Icons.hourglass_empty,
    ),
    EngineState.starting => _EnginePhase(
      tone: AppTone.accent,
      label: 'Starting...',
      icon: Icons.hourglass_top,
    ),
    EngineState.unknown => _EnginePhase(
      tone: AppTone.neutral,
      label: 'Unknown',
      icon: Icons.help_outline,
    ),
  };

  Widget _statusHero() {
    final phase = _phase();
    final theme = Theme.of(context);
    return AppPanel(
      tone: phase.tone,
      filled: true,
      leading: AppIconBubble(icon: phase.icon, tone: phase.tone, size: 40),
      title: phase.label,
      subtitle: _engine.summary,
      trailing: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : AppTag(
              label: _engine.base,
              tone: AppTone.neutral,
              icon: Icons.dns_outlined,
              mono: true,
            ),
      children: [
        const SizedBox(height: AppTheme.s4),
        Wrap(
          spacing: AppTheme.s8,
          runSpacing: AppTheme.s8,
          children: [
            _factChip(
              'Engine version',
              _engine.version.isEmpty ? 'unknown' : _engine.version,
              Icons.info_outline,
            ),
            _factChip(
              'Drives Packet Tracer',
              _engine.isUp
                  ? (_engine.hasRpa ? 'Yes' : 'No - RPA packages missing')
                  : 'Not yet',
              Icons.mouse_outlined,
              tone: _engine.isUp && !_engine.hasRpa
                  ? AppTone.warning
                  : AppTone.neutral,
            ),
            _factChip(
              'Reads the CLI by OCR',
              _engine.isUp ? (_engine.hasOcr ? 'Yes' : 'No') : 'Not yet',
              Icons.text_fields_outlined,
              tone: _engine.isUp && !_engine.hasOcr
                  ? AppTone.warning
                  : AppTone.neutral,
            ),
            _factChip(
              'Started by this app',
              _engine.logPath == null ? 'No' : 'Yes',
              Icons.play_circle_outline,
            ),
          ],
        ),
        if (_engine.isUp) ...[
          const SizedBox(height: AppTheme.s10),
          Text(
            'The engine is a helper, not a dependency: every other screen '
            'keeps working when it is down.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _factChip(
    String label,
    String value,
    IconData icon, {
    AppTone tone = AppTone.neutral,
  }) {
    final theme = Theme.of(context);
    final colors = AppPalette.tone(theme.colorScheme, tone);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.s10,
        vertical: AppTheme.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colors.fg),
          const SizedBox(width: AppTheme.s6),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                value,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Widget _actionsPanel() {
    // A phone has no engine process to start, so the buttons that start one
    // are not shown there: an offer that cannot work is worse than no offer.
    // "Copy a report" stays - it is how the phone tells someone what its
    // address is set to.
    final local = _engine.canStartLocally;
    return AppPanel(
      icon: Icons.tune,
      title: 'Controls',
      subtitle: local
          ? 'Start, restart or stop the helper that drives Packet Tracer.'
          : 'The engine runs on a PC, not on this device.',
      children: [
        if (!local)
          const AppBanner(
            tone: AppTone.info,
            message:
                'On the PC, start the app (or run python '
                'sidecar/pt_autopilot.py in the project folder), find that '
                'PC\'s address with ipconfig on Windows or `ifconfig` / '
                '`ip addr` on Linux and macOS, then enter it below as '
                'http://<pc-address>:5005 and press Test. On the Android '
                'emulator the host PC is 10.0.2.2.',
          )
        else
          Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.s12),
            child: Wrap(
              spacing: AppTheme.s8,
              runSpacing: AppTheme.s8,
              children: [
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() => _engine.ensure(force: true)),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('Start the engine'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _run(() => _engine.restart()),
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('Restart'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _run(() => _engine.stop()),
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('Stop'),
                ),
              ],
            ),
          ),
        if (!local && widget.settings != null)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Build .pkt files on this device'),
            subtitle: const Text(
              'Use the bundled template library when the engine is down - '
              'no PC needed. Turn off to always build with the engine.',
            ),
            value: widget.settings!.preferOnDevicePkt,
            onChanged: (value) {
              setState(() {});
              widget.settings!.setPreferOnDevicePkt(value);
            },
          ),
        Row(
          children: [
            TextButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.maybeOf(context);
                final report = await _engine.diagnose();
                await Clipboard.setData(ClipboardData(text: report));
                messenger?.showSnackBar(
                  const SnackBar(content: Text('Engine report copied')),
                );
              },
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Copy a report'),
            ),
          ],
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Address
  // -------------------------------------------------------------------------

  Widget _addressPanel() {
    final theme = Theme.of(context);
    return AppPanel(
      icon: Icons.dns_outlined,
      title: 'Address',
      subtitle: 'Where this app looks for the engine.',
      children: [
        AppField(
          label: 'Engine base URL',
          help:
              'On this PC that is 127.0.0.1. On a phone the engine runs on '
              'your PC, so this must be that PC\'s address (for the Android '
              'emulator, 10.0.2.2).',
          child: LayoutBuilder(
            builder: (context, constraints) {
              final field = TextField(
                controller: _address,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'http://127.0.0.1:5005',
                  prefixIcon: Icon(Icons.link, size: 18),
                ),
                onSubmitted: (_) => _applyAddress(),
              );
              final button = FilledButton(
                onPressed: _busy ? null : _applyAddress,
                child: const Text('Use this'),
              );
              if (constraints.maxWidth < 420) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field,
                    const SizedBox(height: AppTheme.s8),
                    button,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: AppTheme.s8),
                  button,
                ],
              );
            },
          ),
        ),
        if (_engine.isUp)
          Text(
            'Currently answering at ${_engine.base}.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // What needs what
  // -------------------------------------------------------------------------

  Widget _capabilityPanel() {
    return AppPanel(
      icon: Icons.layers_outlined,
      title: 'What needs what',
      subtitle: 'The engine is optional: most of the app never needs it.',
      children: const [
        _Tier(
          icon: Icons.offline_bolt_outlined,
          tone: AppTone.success,
          title: 'With no engine at all',
          body:
              'Planning a network from plain English, IPv4/IPv6 subnet and '
              'VLSM math, live DNS/ping/port diagnostics, the topology '
              'preview, and every toolkit calculator.',
        ),
        _Tier(
          icon: Icons.description_outlined,
          tone: AppTone.info,
          title: 'With the engine (no Packet Tracer needed)',
          body:
              'Generating a .pkt file from a plan, and opening, auditing, '
              'diffing or grading an existing .pkt.',
        ),
        _Tier(
          icon: Icons.smart_toy_outlined,
          tone: AppTone.accent,
          title: 'With the engine and Packet Tracer open',
          body:
              'Building the network in the app itself - clicking, typing '
              'config, reading the CLI back and pinging to prove it works.',
        ),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // Log
  // -------------------------------------------------------------------------

  Widget _logPanel() {
    final theme = Theme.of(context);
    return AppPanel(
      icon: Icons.terminal_outlined,
      title: 'Engine log',
      subtitle:
          _engine.logPath ?? 'Nothing has been started from this app yet.',
      actions: [
        IconButton(
          tooltip: 'Reload the log',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh, size: 18),
          onPressed: _loadLog,
        ),
      ],
      children: [
        AppCodeBlock(
          text: _log,
          title: 'Log tail (80 lines)',
          maxHeight: 260,
          emptyText: 'Nothing logged yet.',
          copyable: false,
        ),
        Padding(
          padding: const EdgeInsets.only(top: AppTheme.s10),
          child: Text(
            'A failed start writes its reason here - read the last few lines '
            'first.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _EnginePhase {
  final AppTone tone;
  final String label;
  final IconData icon;

  const _EnginePhase({
    required this.tone,
    required this.label,
    required this.icon,
  });
}

/// One rung of the "what needs what" ladder: a coloured bullet, a bold rung
/// name and the features it unlocks.
class _Tier extends StatelessWidget {
  final IconData icon;
  final AppTone tone;
  final String title;
  final String body;

  const _Tier({
    required this.icon,
    required this.tone,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIconBubble(icon: icon, tone: tone, size: 30),
          const SizedBox(width: AppTheme.s10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
