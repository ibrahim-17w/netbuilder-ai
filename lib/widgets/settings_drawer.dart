import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/autopilot_service.dart';
import '../services/context_budget.dart';
import '../services/memory_service.dart';
import '../services/provider_chat_service.dart';
import '../services/settings_service.dart';
import '../theme/app_palette.dart';
import '../widgets/gemini_model_picker.dart';

/// The app's whole settings surface, on a sidebar: nothing else to visit.
class SettingsDrawer extends StatefulWidget {
  /// Called with the conversation name to show, so the sidebar can switch
  /// transcripts instead of only listing them.
  final void Function(String conversation)? onSwitchChat;

  /// Opens the capability hub. The drawer cannot build the hub's host itself
  /// (the host lives in the shell), so the shell passes the callback in.
  final VoidCallback? onOpenHub;

  /// Opens the network toolkit, for the same reason.
  final VoidCallback? onOpenToolkit;

  const SettingsDrawer({
    super.key,
    this.onSwitchChat,
    this.onOpenHub,
    this.onOpenToolkit,
  });

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _engine = TextEditingController();
  final _output = TextEditingController();
  final _base = TextEditingController();
  final _oaModel = TextEditingController();
  final _oaKey = TextEditingController();
  final _headers = TextEditingController();
  String? _testResult;
  bool _testing = false;
  bool _loaded = false;
  /// What secure storage actually holds right now - never a guess.
  String? _keyStatus;
  /// The last engine reachability check, shown verbatim under the field.
  String? _engineTest;
  bool _testingEngine = false;
  /// The Packet Tracer run, controlled from here because it is not something
  /// anyone touches while chatting.
  bool _runBusy = false;
  String? _runStatus;
  final _projectName = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    final s = context.read<SettingsService>();
    _model.text = s.model;
    _engine.text = s.engineBase;
    _output.text = s.outputDir;
    _base.text = s.openAiBaseUrl;
    _oaModel.text = s.openAiModel;
    _headers.text = s.openAiHeaders;
    _projectName.text = s.lastProject;
    _loaded = true;
    _refreshKeyStatus();
  }

  /// Ask secure storage what is really stored. A saved key can be unreadable
  /// after a restore or a reinstall, and saying so is better than showing an
  /// empty field and letting the user think the save never happened.
  Future<void> _refreshKeyStatus() async {
    final s = context.read<SettingsService>();
    final key = await s.getApiKey();
    if (!mounted) return;
    final unreadable = s.keyUnreadable;
    setState(() {
      if (unreadable) {
        _keyStatus = 'A key was saved on this device but could not be read '
            'back. That happens after a restore or a reinstall. Please enter '
            'it again.';
      } else if (key == null || key.trim().isEmpty) {
        _keyStatus = 'No key saved. The offline planner, the .pkt tools and '
            '.pkt generation all work without one.';
      } else {
        _keyStatus = 'A key is saved on this device (${key.trim().length} '
            'characters). It is never shown again.';
      }
    });
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    _engine.dispose();
    _output.dispose();
    _base.dispose();
    _oaModel.dispose();
    _oaKey.dispose();
    _headers.dispose();
    _projectName.dispose();
    super.dispose();
  }

  Future<void> _chooseFolder(SettingsService s) async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Folder for generated and fixed .pkt files',
    );
    if (picked == null || picked.isEmpty) return;
    await s.setOutputDir(picked);
    if (!mounted) return;
    setState(() => _output.text = picked);
    _toast('Fixed and generated .pkt files now go to $picked');
  }

  /// A real round trip whose only job is to say whether the settings work.
  /// The message it returns is shown verbatim, so the user sees the actual
  /// cause (401 / 404 / 429 / timeout) rather than "it failed".
  Future<void> _test(SettingsService s) async {
    setState(() {
      _testing = true;
      _testResult = 'Testing ${s.providerConfig.label}...';
    });
    final service = ProviderChatService(
      config: s.providerConfig,
      geminiKey: await s.getApiKey() ?? '',
      openaiKey: await s.getOpenAiKey() ?? '',
      contextTokens: s.contextBudget,
    );
    final result = await service.testConnection();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result['message']?.toString() ?? 'No result.';
    });
  }

  /// Ask the address in the field whether anything is actually listening.
  ///
  /// Nothing is discovered automatically here: a phone cannot find the PC on
  /// its own, so the useful thing is to say plainly whether the address the
  /// user typed answered, naming it, instead of letting them guess.
  Future<void> _testEngine() async {
    final address = _engine.text.trim();
    setState(() {
      _testingEngine = true;
      _engineTest = 'Calling $address ...';
    });
    String result;
    try {
      final ok = await AutopilotService(base: address).healthy;
      result = ok
          ? 'Reachable: $address answered.'
          : 'No answer from $address.'
                '${SettingsService.isMobile ? ' On a phone this has to be the '
                      'PC that runs the sidecar, and both must be on the same '
                      'network.' : ' Start the sidecar, or check the port.'}';
    } catch (e) {
      result = 'Could not reach $address: '
          '${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() {
      _testingEngine = false;
      _engineTest = result;
    });
  }

  /// Detect what the stored key can use and let the user pick, with the
  /// latest stable version recommended. The chosen id lands in the field,
  /// so 'Save model' remains the single place that commits it.
  Future<void> _pickModel(SettingsService s) async {
    final key = await s.getApiKey() ?? '';
    if (!mounted) return;
    if (key.trim().isEmpty) {
      _toast('Save a Gemini key first - the model list is detected from it.');
      return;
    }
    final chosen = await showGeminiModelPicker(
      context,
      apiKey: key,
      currentModel: _model.text.trim().isEmpty ? s.model : _model.text.trim(),
    );
    if (chosen == null || chosen.trim().isEmpty || !mounted) return;
    setState(() => _model.text = chosen.trim());
    await s.setModel(chosen.trim());
    _toast('Model set to ${chosen.trim()}.');
  }

  /// The current chat and the previous ones. Tapping one opens that
  /// conversation; the current one is highlighted.
  Widget _chatList(SettingsService s) {
    final memory = context.read<MemoryService>();
    if (!memory.ready) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text(
          'Chat history is not available on this device yet.',
          style: TextStyle(fontSize: 12),
        ),
      );
    }
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: memory.conversations(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        final chats = snapshot.data ?? const <Map<String, dynamic>>[];
        if (chats.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(
              'No chats yet - this is the first one.',
              style: TextStyle(fontSize: 12),
            ),
          );
        }
        return Column(
          children: [
            for (final chat in chats)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                selected: '${chat['id']}' == s.lastProject,
                leading: const Icon(Icons.forum_outlined, size: 18),
                title: Text(
                  '${chat['title']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${chat['messages']} messages'),
                onTap: () {
                  widget.onSwitchChat?.call('${chat['id']}');
                  Navigator.of(context).pop();
                },
                // The options a chat needs. Delete asks first, and the list
                // is re-read afterwards so the row really goes.
                trailing: PopupMenuButton<String>(
                  tooltip: 'Chat options',
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: (value) {
                    if (value == 'delete') _confirmDeleteChat('${chat['id']}');
                  },
                  itemBuilder: (menuContext) => const [
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.delete_outline, size: 18),
                        title: Text('Delete chat'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  AutopilotService _autopilot(SettingsService s) =>
      AutopilotService(base: s.engineBase);

  /// Pause the autopilot at a safe boundary, or resume it.
  Future<void> _togglePause() async {
    final s = context.read<SettingsService>();
    setState(() {
      _runBusy = true;
      _runStatus = 'Talking to the engine...';
    });
    String result;
    try {
      final svc = _autopilot(s);
      if (!await svc.healthy) {
        result = AutopilotService.startHint;
      } else {
        final res = await svc.pauseToggle();
        result = (res['state'] ?? '').toString() == 'paused'
            ? 'Autopilot paused at a safe boundary.'
            : 'Autopilot resumed.';
      }
    } catch (e) {
      result = 'Could not change the run: '
          '${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() {
      _runBusy = false;
      _runStatus = result;
    });
  }

  /// Emergency stop.
  Future<void> _stopRun() async {
    final s = context.read<SettingsService>();
    setState(() {
      _runBusy = true;
      _runStatus = 'Stopping...';
    });
    String result;
    try {
      final svc = _autopilot(s);
      if (!await svc.healthy) {
        result = AutopilotService.startHint;
      } else {
        await svc.stop();
        result = 'Emergency stop requested.';
      }
    } catch (e) {
      result = 'Stop failed: ${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() {
      _runBusy = false;
      _runStatus = result;
    });
  }

  /// The audit ledger, shown where the rest of the records live.
  Future<void> _showLedger() async {
    final s = context.read<SettingsService>();
    setState(() {
      _runBusy = true;
      _runStatus = 'Reading the ledger...';
    });
    String body;
    try {
      final report = await _autopilot(s).pktLedger();
      final lines = <String>[
        'Entries: ${report['count'] ?? 0}',
        'Applied changes: ${report['applied'] ?? 0}',
        'Rejections: ${report['rejected'] ?? 0}',
        'Undos: ${report['undone'] ?? 0}',
        'Ledger file: ${report['path'] ?? ''}',
        '',
        for (final e in ((report['entries'] as List?) ?? const []))
          if (e is Map)
            '${e['at']}  ${e['event']}  '
                '${e['device'] ?? e['id'] ?? ''}  ${e['decision'] ?? ''}',
      ];
      body = lines.join('\n');
    } catch (e) {
      body = 'Could not read the ledger: '
          '${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() => _runBusy = false);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Audit ledger'),
        content: SingleChildScrollView(
          child: SelectableText(
            body,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Deleting a conversation is not undoable, so it is confirmed first.
  Future<void> _confirmDeleteChat(String conversation) async {
    final memory = context.read<MemoryService>();
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this chat?'),
        content: Text(
          'Everything said in "$conversation" is removed from this device. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (answer != true || !mounted) return;
    try {
      await memory.clearChat(conversation: conversation);
      if (!mounted) return;
      setState(() {});
      _toast('Deleted "$conversation".');
    } catch (e) {
      if (!mounted) return;
      _toast('Could not delete it: '
          '${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsService>();
    final theme = Theme.of(context);
    // A fixed 380px sidebar is wider than a small phone, and the layout
    // overflows. Take most of the screen when there is not enough room.
    final screenWidth = MediaQuery.of(context).size.width;
    final drawerWidth = screenWidth < 420 ? screenWidth * 0.86 : 380.0;
    return Drawer(
      width: drawerWidth,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('Settings', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Your chats, and everything the app needs - there is no other '
              'screen.',
              style: TextStyle(
                fontSize: 12,
                color: AppPalette.mutedText(theme.colorScheme),
              ),
            ),
            const Divider(height: 24),

            // ---- CHATS -------------------------------------------
            // A chat is named by the project context. "New chat" starts one
            // under a fresh name, so the list below is real history rather
            // than the same transcript under different labels.
            // Nothing here may overflow: the drawer is 380 wide and the
            // header carries a label plus a button.
            Row(
              children: [
                Flexible(
                  child: Text(
                    'Chats',
                    style: theme.textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    final now = DateTime.now();
                    final name =
                        'chat ${now.hour}:'
                        '${now.minute.toString().padLeft(2, '0')}';
                    widget.onSwitchChat?.call(name);
                    Navigator.of(context).pop();
                  },
                  child: const Text('New chat'),
                ),
              ],
            ),
            _chatList(s),
            const Divider(height: 24),

            const Divider(height: 24),

            // ---- THE RUN AND ITS RECORD --------------------------
            // These used to sit on the chat screen. A run is started, paused
            // and audited in a different frame of mind than chatting, so they
            // live here now.
            Text('Packet Tracer run', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _runBusy ? null : _togglePause,
                    child: const Text('Pause / resume'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _runBusy ? null : _stopRun,
                    child: const Text('Stop'),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _runBusy ? null : _showLedger,
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: const Text('Ledger'),
              ),
            ),
            if (_runStatus != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_runStatus!, style: const TextStyle(fontSize: 12)),
              ),

            const Divider(height: 24),
            Text('Project and context', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            TextField(
              controller: _projectName,
              onChanged: (value) => s.setLastProject(value),
              decoration: const InputDecoration(
                labelText: 'Project context',
                helperText: 'Names this chat, and keeps its history together.',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Live context'),
              subtitle: const Text('Include the live run summary in the '
                  'prompt, so "what is it stuck on?" is answerable.'),
              value: s.liveContext,
              onChanged: (value) => s.setLiveContext(value),
            ),

            // ---- WHICH BRAIN -------------------------------------
            Text('AI provider', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: s.providerName,
              items: const [
                DropdownMenuItem(
                  value: 'gemini',
                  child: Text('Google Gemini'),
                ),
                DropdownMenuItem(
                  value: 'openai',
                  child: Text('OpenAI-compatible (free models OK)'),
                ),
              ],
              onChanged: (v) => s.setProviderName(v ?? 'gemini'),
              decoration: const InputDecoration(
                labelText: 'Active provider',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (s.usesOpenAi) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _base,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'https://api.groq.com/openai/v1',
                  helperText: 'Everything up to /v1. Free tiers: Groq, '
                      'OpenRouter, Cerebras, Together. Local: '
                      'http://127.0.0.1:11434/v1 (Ollama, no key).',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _oaModel,
                decoration: const InputDecoration(
                  labelText: 'Model id',
                  helperText: 'Type any id - a new model never needs an '
                      'app update.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _oaKey,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API key for this provider',
                  helperText: 'Stored on this device only, masked here and '
                      'never logged. Leave empty for a local server.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _headers,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Extra headers (optional)',
                  hintText: 'X-Title: my app',
                  helperText: 'One `Header: value` per line.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton(
                    onPressed: () async {
                      await s.setOpenAiBaseUrl(_base.text);
                      await s.setOpenAiModel(_oaModel.text);
                      await s.setOpenAiHeaders(_headers.text);
                      if (_oaKey.text.trim().isNotEmpty) {
                        await s.setOpenAiKey(_oaKey.text);
                        _oaKey.clear();
                      }
                      if (mounted) setState(() {});
                      _toast('Provider settings saved.');
                    },
                    child: const Text('Save provider'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () async {
                      await s.setOpenAiBaseUrl(_base.text);
                      await s.setOpenAiModel(_oaModel.text);
                      await s.setOpenAiHeaders(_headers.text);
                      if (_oaKey.text.trim().isNotEmpty) {
                        await s.setOpenAiKey(_oaKey.text);
                        _oaKey.clear();
                      }
                      await _test(s);
                    },
                    child: const Text('Test connection'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            if (!s.usesOpenAi)
              OutlinedButton(
                onPressed: () => _test(s),
                child: const Text('Test connection (Gemini)'),
              ),
            if (_testing) const LinearProgressIndicator(minHeight: 2),
            if (_testResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _testResult!,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            const Divider(height: 24),
            Text('AI (optional)', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            TextField(
              controller: _key,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'Gemini API key',
                helperText: 'Stored on this device and never shown again. '
                    'Saving an empty field clears it. Without a key the '
                    'offline planner, the audit and .pkt generation still '
                    'work.',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_keyStatus != null) ...[
              const SizedBox(height: 6),
              Text(_keyStatus!, style: const TextStyle(fontSize: 12)),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      // Only claim success when the key reads back.
                      final ok = await s.setApiKey(_key.text.trim());
                      _key.clear();
                      await _refreshKeyStatus();
                      if (!mounted) return;
                      _toast(
                        ok
                            ? 'Key saved and read back - it survives a '
                                  'restart.'
                            : 'This device refused to store the key, so '
                                  'nothing was saved. Try again, or use a '
                                  'keyless setup.',
                      );
                    },
                    child: const Text('Save key'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    await s.setApiKey('');
                    await _refreshKeyStatus();
                    if (mounted) _toast('Key cleared.');
                  },
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _model,
              decoration: InputDecoration(
                labelText: 'Model',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: 'Detect the models this key can use, and choose '
                      'one (latest stable is recommended)',
                  icon: const Icon(Icons.auto_awesome_outlined),
                  onPressed: () => _pickModel(s),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pickModel(s),
                    icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                    label: const Text('Detect models for this key'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => s.setModel(_model.text.trim()),
                  child: const Text('Save model'),
                ),
              ],
            ),

            const Divider(height: 24),
            Text('Chat context', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
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
                labelText: 'Context budget',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),

            const Divider(height: 24),
            Text('Offline engine (.pkt work)',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            TextField(
              controller: _engine,
              // The hint follows what is typed, because the difference between
              // "the PC that runs the sidecar" and "this phone" is the whole
              // reason the app looked broken on Android.
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Engine address',
                helperText: SettingsService.engineHint(_engine.text),
                helperMaxLines: 4,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      await s.setEngineBase(_engine.text);
                      if (!mounted) return;
                      setState(() => _engine.text = s.engineBase);
                      _toast('Engine set to ${s.engineBase}');
                    },
                    child: const Text('Save engine'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: _testingEngine ? null : _testEngine,
                    child: const Text('Test'),
                  ),
                ),
              ],
            ),
            if (_testingEngine)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (_engineTest != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _engineTest!,
                  style: const TextStyle(fontSize: 12),
                ),
              ),

            const Divider(height: 24),
            Text('Output folder', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            TextField(
              controller: _output,
              decoration: const InputDecoration(
                labelText: 'Save every .pkt here',
                helperText: 'Generated saves and the fixed files after a fix '
                    'are written here. Empty = the engine default.',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => _chooseFolder(s),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Choose folder'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    await s.setOutputDir(_output.text);
                    if (mounted) {
                      _toast(s.outputDir.isEmpty
                          ? 'Using the engine default folder.'
                          : 'Saving to ${s.outputDir}');
                    }
                  },
                  child: const Text('Save folder'),
                ),
              ],
            ),

            const Divider(height: 24),
            Text('Privacy', style: theme.textTheme.titleSmall),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: s.privateMode,
              title: const Text('Private mode'),
              subtitle: const Text(
                'Never call the model; plan and audit offline only.',
                style: TextStyle(fontSize: 12),
              ),
              onChanged: (v) => s.setPrivateMode(v),
            ),

            const Divider(height: 24),
            // ---- EVERYTHING ELSE ---------------------------------
            // The hub is the app's index: every capability, searchable. On a
            // phone this drawer is the main way around, so the way in has to
            // be here, not only in the app bar of a wide window.
            Text('Everything else', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.grid_view_rounded),
              title: const Text('All features'),
              subtitle: const Text(
                'Search every capability: subnet maths, VLSM, diagnostics, '
                'exports, the ledger, .pkt tools',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () {
                Navigator.of(context).pop();
                widget.onOpenHub?.call();
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.calculate_outlined),
              title: const Text('Network toolkit'),
              subtitle: const Text(
                'Subnet calculator, VLSM, summarization, ACL masks, live '
                'diagnostics and the config exporters',
                style: TextStyle(fontSize: 12),
              ),
              onTap: () {
                Navigator.of(context).pop();
                widget.onOpenToolkit?.call();
              },
            ),

            const Divider(height: 24),
            Text('Appearance', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
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
              selected: {s.themeMode},
              onSelectionChanged: (value) => s.setThemeMode(value.first),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'A reading app gets used in a lit office and at night; this '
                'does not have to follow the operating system.',
                style: TextStyle(fontSize: 12),
              ),
            ),

            const Divider(height: 24),
            Text('Handy', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'In the chat: /scan <path>  /folder <path>  /ledger  /pc <host>  '
              '/budget <tokens>  /key <value>  /help',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
