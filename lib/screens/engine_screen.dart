import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/engine_status.dart';
import '../services/settings_service.dart';
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
    final theme = Theme.of(context);
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
      body: ListView(
        padding: const EdgeInsets.all(AppTheme.s16),
        children: [
          _statusCard(theme),
          const SizedBox(height: AppTheme.s12),
          _actionsCard(theme),
          const SizedBox(height: AppTheme.s12),
          _addressCard(theme),
          const SizedBox(height: AppTheme.s12),
          _offlineCard(theme),
          const SizedBox(height: AppTheme.s12),
          _logCard(theme),
        ],
      ),
    );
  }

  Widget _statusCard(ThemeData theme) {
    final phase = _engine.phase;
    final colour = switch (phase) {
      EngineState.up => theme.colorScheme.primary,
      EngineState.down => theme.colorScheme.error,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    final label = switch (phase) {
      EngineState.up => 'Running',
      EngineState.down => 'Not running',
      EngineState.checking => 'Checking...',
      EngineState.starting => 'Starting...',
      EngineState.unknown => 'Unknown',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  switch (phase) {
                    EngineState.up => Icons.check_circle_outline,
                    EngineState.down => Icons.cloud_off_outlined,
                    _ => Icons.hourglass_empty,
                  },
                  color: colour,
                ),
                const SizedBox(width: AppTheme.s8),
                Text(label,
                    style: theme.textTheme.titleMedium?.copyWith(color: colour)),
                const Spacer(),
                if (_busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.s8),
            Text(_engine.summary, style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppTheme.s12),
            _fact(theme, 'Address', _engine.base),
            if (_engine.version.isNotEmpty)
              _fact(theme, 'Engine version', _engine.version),
            _fact(
              theme,
              'Drives Packet Tracer',
              _engine.isUp
                  ? (_engine.hasRpa ? 'Yes' : 'No - RPA packages missing')
                  : '-',
            ),
            _fact(
              theme,
              'Reads the CLI by OCR',
              _engine.isUp ? (_engine.hasOcr ? 'Yes' : 'No') : '-',
            ),
            _fact(
              theme,
              'Started by this app',
              _engine.logPath == null ? 'Not yet' : 'Yes',
            ),
          ],
        ),
      ),
    );
  }

  Widget _fact(ThemeData theme, String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 170,
              child: Text(
                label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(
              child: SelectableText(value, style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      );

  Widget _actionsCard(ThemeData theme) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s12),
          child: Wrap(
            spacing: AppTheme.s8,
            runSpacing: AppTheme.s8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => _run(() => _engine.ensure(force: true)),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start the engine'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(() => _engine.restart()),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Restart'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _run(() => _engine.stop()),
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
              TextButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  final report = await _engine.diagnose();
                  await Clipboard.setData(ClipboardData(text: report));
                  messenger?.showSnackBar(
                    const SnackBar(content: Text('Engine report copied')),
                  );
                },
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('Copy a report'),
              ),
            ],
          ),
        ),
      );

  Widget _addressCard(ThemeData theme) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Address', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'On this PC that is 127.0.0.1. On a phone the engine runs on '
                'your PC, so this must be that PC\'s address (for the Android '
                'emulator, 10.0.2.2).',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: AppTheme.s8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _address,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _applyAddress(),
                    ),
                  ),
                  const SizedBox(width: AppTheme.s8),
                  FilledButton(
                    onPressed: _busy ? null : _applyAddress,
                    child: const Text('Use this'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

  Widget _offlineCard(ThemeData theme) => Card(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.offline_bolt_outlined, size: 18),
                  const SizedBox(width: AppTheme.s6),
                  Text('What needs what',
                      style: theme.textTheme.titleSmall),
                ],
              ),
              const SizedBox(height: AppTheme.s6),
              _tier(theme, 'With no engine at all',
                  'Planning a network from plain English, IPv4/IPv6 subnet and '
                  'VLSM math, live DNS/ping/port diagnostics, the topology '
                  'preview, and every toolkit calculator.'),
              _tier(theme, 'With the engine (no Packet Tracer needed)',
                  'Generating a .pkt file from a plan, and opening, auditing, '
                  'diffing or grading an existing .pkt.'),
              _tier(theme, 'With the engine and Packet Tracer open',
                  'Building the network in the app itself - clicking, typing '
                  'config, reading the CLI back and pinging to prove it works.'),
            ],
          ),
        ),
      );

  Widget _tier(ThemeData theme, String title, String body) => Padding(
        padding: const EdgeInsets.only(top: AppTheme.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: theme.textTheme.labelLarge
                    ?.copyWith(color: theme.colorScheme.primary)),
            Text(body, style: theme.textTheme.bodySmall),
          ],
        ),
      );

  Widget _logCard(ThemeData theme) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('Engine log', style: theme.textTheme.titleSmall),
                  const SizedBox(width: AppTheme.s8),
                  Expanded(
                    child: Text(
                      _engine.logPath ?? '(none yet)',
                      style: theme.textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Reload the log',
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: _loadLog,
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.s6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 260),
                padding: const EdgeInsets.all(AppTheme.s8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppTheme.rSm),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _log.isEmpty ? 'Nothing logged yet.' : _log,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
