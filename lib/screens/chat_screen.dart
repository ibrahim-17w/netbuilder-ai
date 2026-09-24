import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../widgets/chat_markdown.dart';
import '../models/chat_message.dart';
import '../models/network_intent.dart';
import '../services/adapters/packet_tracer_adapter.dart';
import '../services/autopilot_service.dart';
import '../services/casual_english.dart';
import '../services/chat_service.dart';
import '../services/generation_control.dart';
import '../services/provider_chat_service.dart';
import '../services/context_budget.dart';
import '../services/engine_status.dart';
import '../services/memory_service.dart';
import '../services/offline_assistant_service.dart';
import '../services/planner_memory_service.dart';
import '../services/planner_suggestions_service.dart';
import '../services/rule_packs_service.dart';
import '../services/settings_service.dart';
import '../services/gemini_model_catalog.dart';
import '../services/tool_runtime.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../widgets/gemini_model_picker.dart';

/// A real conversation with the model, with screenshots attached.
///
/// Design rules this screen keeps:
///
/// * The model proposes; the user approves. Every action it returns is shown
///   as a card with its own button, and nothing is typed into Packet Tracer
///   without that click. A chat window is not a reason to hand a model the
///   keyboard.
/// * Attachments come from evidence the engine already produced (`/shots`)
///   or from a file the user picks. There is no new dependency for this:
///   file_picker is already in the app.
/// * Anything the user approves that is worth reusing (a rule, a preference)
///   is written to the same memory the planner reads, so a correction given
///   in the chat actually changes the next plan.
class ChatScreen extends StatefulWidget {
  final String initialProject;
  final void Function(String project)? onOpenProject;

  /// Text the composer opens with. The capability hub uses it to send the
  /// user here with the question already written - "explain the plan",
  /// "what is wrong?" - so a button in the hub ends in a sent message
  /// instead of an empty box.
  final String initialDraft;

  const ChatScreen({
    super.key,
    this.initialProject = 'default',
    this.onOpenProject,
    this.initialDraft = '',
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _project = TextEditingController();
  final _scroll = ScrollController();
  /// Named so "Edit and resend" can put the caret back in the composer where
  /// the user just sent the text.
  final _composerFocus = FocusNode();
  // The provider facade: Gemini or any OpenAI-compatible endpoint, chosen
  // in Settings. Nothing else in this screen knows which one is active.
  ProviderChatService? _chat;

  /// The context ceiling in force, read from Settings on load.
  int _contextTokens = ContextBudget.defaultContextTokens;

  /// The text of a message that could not be answered, kept so the user
  /// can retry without typing it again.
  String? _failedText;
  String _geminiKey = '';
  String _openAiKey = '';

  List<ChatMessage> _messages = [];
  List<ChatImage> _pending = [];
  bool _busy = false;
  /// The structured plan from the user's own words. It is what the
  /// `.pkt` builder compiles, so generation does not depend on the model.
  NetworkIntent? _lastIntent;

  /// The conversation this screen is showing. A conversation is named by the
  /// project context, which is how the sidebar lists and switches them.
  String get _conversation {
    final name = _project.text.trim();
    return name.isEmpty ? 'default' : name;
  }
  /// null = not checked yet. A false means the .pkt engine is not
  /// answering, which is the state the user needs to be told about.
  bool? _engineReachable;
  bool _engineStarting = false;
  /// Lets a streaming answer be stopped without losing what was written.
  final GenerationControl _generation = GenerationControl();
  bool _liveContext = true;
  String _target = 'packet-tracer';
  /// The capture the tools are allowed to read from, once one is
  /// scanned. Empty means there is nothing to investigate yet.
  String _capturePath = '';
  String _status = '';
  /// Whether the transcript is scrolled to the newest message. A chat that
  /// silently yanks the viewport while you are reading an old answer is worse
  /// than one that offers a button.
  bool _atBottom = true;
  /// Set when a jump-to-latest is waiting to be tapped, so the pill can say
  /// how much is waiting instead of just "down".
  int _unseen = 0;

  @override
  void initState() {
    super.initState();
    _project.text = widget.initialProject.trim().isEmpty
        ? 'default'
        : widget.initialProject.trim();
    if (widget.initialDraft.trim().isNotEmpty) {
      _input.text = widget.initialDraft;
    }
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    // Find out whether the .pkt engine answers before the user tries
    // anything, so an unreachable address is stated up front with a way
    // to fix it instead of being discovered inside a chat bubble.
    // The app starts the engine itself, so the banner follows that status
    // rather than believing only its own first probe.
    EngineStatus.instance.addListener(_onEngineStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkEngine());
  }

  /// Keep the banner honest while the engine is coming up (or has just
  /// died). Busy states are ignored: "still trying" is not "unreachable".
  void _onEngineStatus() {
    final status = EngineStatus.instance;
    if (status.phase == EngineState.checking ||
        status.phase == EngineState.starting ||
        status.phase == EngineState.unknown) {
      return;
    }
    final ok = status.isUp;
    if (!mounted || ok == _engineReachable) return;
    setState(() => _engineReachable = ok);
  }

  @override
  void dispose() {
    EngineStatus.instance.removeListener(_onEngineStatus);
    _scroll.removeListener(_onScroll);
    _composerFocus.dispose();
    _input.dispose();
    _project.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // 80px of slack: "at the bottom" should mean what a person means by it,
    // not floating-point equality with maxScrollExtent.
    final atBottom =
        position.pixels >= position.maxScrollExtent - 80;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _unseen = 0;
      });
    }
  }

  /// Provider lookups are nullable on purpose: this screen must render even
  /// when it is mounted without the app's providers (a widget test booting
  /// the shell, or any future reuse). A missing provider should cost the chat
  /// its memory and settings, never its ability to draw.
  SettingsService? get _settings {
    try {
      return context.read<SettingsService>();
    } catch (_) {
      return null;
    }
  }

  MemoryService? get _memory {
    try {
      return context.read<MemoryService>();
    } catch (_) {
      return null;
    }
  }

  /// Rules/preferences the user taught the app, so the keyless answer
  /// evolves the same way the build screen's plan does.
  Future<List<String>> _learnedRules() async {
    final mem = _memory;
    if (mem == null || !mem.ready) return const [];
    try {
      return (await mem.allRules()).map((r) => r.ruleText).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, String>> _learnedPrefs() async {
    final mem = _memory;
    if (mem == null || !mem.ready) return const {};
    try {
      return await mem.allPrefs();
    } catch (_) {
      return const {};
    }
  }

  Future<void> _load() async {
    final settings = _settings;
    final mem = _memory;
    if (settings != null) {
      _geminiKey = await settings.getApiKey() ?? '';
      _openAiKey = await settings.getOpenAiKey() ?? '';
    }
    if (mounted && settings != null) {
      setState(() {
        _target = settings.defaultTarget;
        _contextTokens = settings.contextBudget;
      _liveContext = settings.liveContext;
        _chat = _withTools(ProviderChatService(
          config: settings.providerConfig,
          geminiKey: _geminiKey,
          openaiKey: _openAiKey,
          contextTokens: settings.contextBudget,
        ));
      });
      // Ask the engine whether it is there, so the answer is known before the
      // user tries anything. No .pkt job works without it.
      _checkEngine();
      // Reopen the conversation the user was last in.
      if (widget.initialProject.trim().isEmpty &&
          settings.lastProject.isNotEmpty) {
        _project.text = settings.lastProject;
      }
    }
    if (mem == null || !mem.ready) return;
    try {
      // Load the whole stored conversation: the context budget decides
      // what reaches the model, not this query.
      final history = await mem.recentChat(
        limit: 5000,
        conversation: _conversation,
      );
      if (!mounted) return;
      setState(() => _messages = history);
      _jumpToEnd();
    } catch (_) {}
  }

  void _jumpToEnd({bool animate = true}) {
    _unseen = 0;
    _atBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (!animate) {
        _scroll.jumpTo(target);
        return;
      }
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  /// A new message (or a new chunk of a streaming one) arrived. If the reader
  /// is at the bottom this follows along; if they scrolled up to read, it
  /// leaves the viewport alone and counts what is waiting.
  /// True while the assistant owes an answer: busy, and the last turn is the
  /// user's. That is exactly the window where "typing" is the honest state.
  bool get _waiting =>
      _busy && (_messages.isEmpty || _messages.last.isUser);

  void _noteNewMessage({bool animate = false}) {
    if (_atBottom) {
      _jumpToEnd(animate: animate);
      return;
    }
    if (mounted) setState(() => _unseen++);
  }

  // --- context -----------------------------------------------------------

  /// Everything the model should know before it answers: the app's rules,
  /// what the user already taught it, the cross-run blockers, and - when the
  /// user asked for it - where the current run actually is.
  Future<String> _buildContext(MemoryService? mem) async {
    var rules = <String>[];
    var prefs = <String, String>{};
    if (mem != null && mem.ready) {
      try {
        rules = (await mem.allRules()).map((r) => r.ruleText).toList();
        prefs = await mem.allPrefs();
      } catch (_) {}
    }
    final svc = _engine();
    final blockers = await svc.blockerLines(project: _project.text.trim());
    final unsupported = await svc.provenUnsupported();
    final live = _liveContext ? await _liveState(svc) : '';
    return ChatService.systemContext(
      target: _target,
      rulePacks: _rulePackBlock(),
      learnedRules: rules,
      preferences: prefs,
      knownBlockers: blockers,
      unsupportedCapabilities: unsupported,
      liveState: live,
    );
  }

  String _rulePackBlock() {
    try {
      return RulePacksService.packs
          .where((p) => p.targets.contains('all') || p.targets.contains(_target))
          .take(20)
          .map((p) => '- [${p.id}] ${p.rule}')
          .join('\n');
    } catch (_) {
      return '';
    }
  }

  /// The live picture: run counters, the last events, and what is failing.
  /// Best-effort - a stopped sidecar just means no live section.
  Future<String> _liveState(AutopilotService svc) async {
    final sb = StringBuffer();
    try {
      final summary = await svc.runSummary();
      sb.writeln('project: ${_project.text.trim()}');
      sb.writeln('ok: ${summary['ok']}  phase: ${summary['phase']}');
      sb.writeln(
        'devices done=${summary['devices_done']} '
        'skipped=${summary['devices_skipped']}  '
        'errors recovered=${summary['errors_recovered']} '
        'unrecovered=${summary['errors_unrecovered']}  '
        'red links=${summary['links_red']}  '
        'pings failed=${summary['pings_failed']}  '
        'server failures=${summary['srv_failed']}  '
        'CLI blocks=${summary['cli_context_blocks']}',
      );
      final skipped = (summary['known_blockers_skipped'] as List? ?? const []);
      if (skipped.isNotEmpty) {
        sb.writeln('steps the engine gave up on:');
        for (final item in skipped.take(6)) {
          sb.writeln('  - $item');
        }
      }
    } catch (_) {
      sb.writeln('(sidecar run summary unavailable)');
    }
    try {
      final events = await svc.events(limit: 40);
      if (events.isNotEmpty) {
        sb.writeln('recent journal events (oldest first):');
        for (final event in events) {
          final recovered = event['recovered'];
          sb.writeln(
            '  [${event['kind']}] ${event['device'] ?? ''} '
            '${event['detail'] ?? ''}'
            '${recovered == null ? '' : recovered == true ? ' (recovered)' : ' (NOT recovered)'}',
          );
        }
      }
    } catch (_) {}
    return sb.toString();
  }

  // --- sending -----------------------------------------------------------

  /// The offline engine for THIS build: the local sidecar on a
  /// desktop, or the PC running that sidecar when the app is on a
  /// phone (set it with /pc - the device has no Python of its own).
  AutopilotService _engine() => AutopilotService(
    base: _settings?.engineBase ?? 'http://127.0.0.1:5005',
  );

  /// Slash commands keep EVERYTHING in the chat: there is no settings
  /// screen any more, so the key, model and budget are set here.
  Future<bool> _handleCommand(String text) async {
    final lower = text.trim().toLowerCase();
    if (lower == '/help' || lower == 'help me') {
      _appendSystem(
        'Things you can do right here:\n'
        '- Attach a Packet Tracer save (.pkt) with the router button, or '
        'type `/scan C:\\path\\to\\lab.pkt` - I decrypt and audit it '
        'offline, with no Packet Tracer involved.\n'
        '- Approve, Reject or Modify each proposed fix; approved fixes are '
        'edited into a NEW .pkt and encrypted again.\n'
        '- `/build` - compile the plan into a real .pkt offline, with no\n'
        '  Packet Tracer. Works with or without an API key.\n'
        '- `/ledger` - every capture, decision, change and export on record.\n'
        '- `/key <value>` - store the Gemini key without echoing it.\n'
        '- `/model <name>` and `/budget <tokens>` - model and context size.\n'
        '- `/models` - detect what this key can use and pick, with the '
        'latest stable version recommended.\n'
        '- Or just ask a networking question.',
      );
      return true;
    }
    if (lower == '/ledger' || lower == 'ledger' ||
        lower == 'show the ledger' || lower == 'show the audit ledger') {
      await _showLedger();
      return true;
    }
    if (lower == '/build' ||
        lower == '/generate' ||
        lower == 'build the pkt' ||
        lower == 'generate the pkt' ||
        lower == 'build a pkt') {
      await _buildPktFromPlan();
      return true;
    }
    if (lower.startsWith('/scan ')) {
      final path = text.trim().substring(6).trim();
      await _scanPkt(path, path.split(RegExp(r'[\\/]')).last);
      return true;
    }
    if (lower.startsWith('/pc')) {
      final settings = _settings;
      final arg = text.trim().length > 3
          ? text.trim().substring(3).trim()
          : '';
      if (settings == null) return true;
      if (arg.isEmpty || arg.toLowerCase() == 'status') {
        _appendSystem(
          'Offline engine: `${settings.engineBase}`.\n'
          'On a phone the .pkt work runs on a PC: start the sidecar '
          'there (`python pt_autopilot.py`) and point the app at it, '
          'e.g. `/pc 192.168.1.20:5005`. On an Android emulator the '
          'host is `/pc 10.0.2.2:5005`.',
        );
        return true;
      }
      await settings.setEngineBase(arg);
      final svc = _engine();
      final up = await svc.healthy;
      _appendSystem(
        up
            ? 'Engine set to `${settings.engineBase}` and it answered. '
                  'Attach a .pkt or `/scan <path>`.'
            : 'Engine set to `${settings.engineBase}`, but nothing '
                  'answered there yet. Start the sidecar on that '
                  'machine and try again.',
      );
      return true;
    }
    if (lower.startsWith('/key ')) {
      final value = text.trim().substring(5).trim();
      final settings = _settings;
      if (settings == null) return true;
      // Only report success when the key reads back, and never echo any
      // part of the key - not even its last characters.
      final ok = await settings.setApiKey(value);
      _appendSystem(
        value.isEmpty
            ? 'Key cleared. The offline planner, the .pkt tools and .pkt '
                  'generation all still work with no key.'
            : ok
            ? 'Key stored (${value.trim().length} characters) and read back, '
                  'so it will survive a restart. It is never shown again and '
                  'never written into this conversation.'
            : 'This device refused to store the key, so nothing was saved. '
                  'Try again, or carry on without one - everything except the '
                  'model works without a key.',
      );
      return true;
    }
    if (lower.startsWith('/model ')) {
      final settings = _settings;
      if (settings == null) return true;
      await settings.setModel(text.trim().substring(7).trim());
      _appendSystem('Model set to ${text.trim().substring(7).trim()}.');
      return true;
    }
    if (lower == '/models') {
      final settings = _settings;
      if (settings == null) return true;
      final key = _geminiKey.trim().isNotEmpty
          ? _geminiKey
          : (await settings.getApiKey() ?? '');
      if (key.trim().isEmpty) {
        _appendSystem(
          'No Gemini key is stored, so there is nothing to detect from. '
          'Save one with `/key <value>` first.',
        );
        return true;
      }
      _appendSystem('Detecting the models this key can use...');
      try {
        final models = await GeminiModelCatalog().fetchFor(key);
        final best = GeminiModelCatalog.recommend(models);
        final lines = StringBuffer()
          ..writeln('**${models.length} chat model(s) available to this '
              'key**, best first:')
          ..writeln();
        for (final m in models.take(12)) {
          final mark = m.name == (best?.name ?? '')
              ? ' - **recommended (latest stable)**'
              : m.name == settings.model
                  ? ' - **current**'
                  : '';
          lines.writeln('- `${m.name}`$mark');
        }
        if (models.length > 12) lines.writeln('- ...and ${models.length - 12} more');
        _appendSystem(lines.toString());
        if (!mounted) return true;
        final chosen = await showGeminiModelPicker(
          context,
          apiKey: key,
          currentModel: settings.model,
        );
        if (chosen != null && chosen.trim().isNotEmpty) {
          await settings.setModel(chosen.trim());
          _appendSystem('Model set to ${chosen.trim()}.');
        }
      } catch (e) {
        _appendSystem('Model detection failed: '
            '${e.toString().replaceFirst('Exception: ', '')}');
      }
      return true;
    }
    if (lower.startsWith('/budget ')) {
      final settings = _settings;
      final value = int.tryParse(text.trim().substring(8).trim());
      if (settings == null) return true;
      if (value == null) {
        _appendSystem('Usage: /budget 262144  (tokens, 8k..1M)');
        return true;
      }
      await settings.setContextBudget(value);
      setState(() {
        _contextTokens = settings.contextBudget;
        _chat = _withTools(ProviderChatService(
          config: settings.providerConfig,
          geminiKey: _geminiKey,
          openaiKey: _openAiKey,
          contextTokens: settings.contextBudget,
        ));
      });
      _appendSystem('Context budget is now $value tokens.');
      return true;
    }
    return false;
  }

  void _appendSystem(String text) {
    final turn = ChatMessage(
      role: 'model',
      text: text,
      createdAt: DateTime.now().toIso8601String(),
    );
    if (!mounted) return;
    setState(() => _messages = [..._messages, turn]);
    _jumpToEnd();
  }

  Future<void> _pickPkt() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Choose a Packet Tracer save (.pkt/.pka)',
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.single;
      final path = picked.path ?? '';
      if (path.isEmpty) {
        _appendSystem('That picker returned no file path.');
        return;
      }
      await _scanPkt(path, picked.name);
    } catch (e) {
      _appendSystem('Could not open that file: $e');
    }
  }

  /// Give the model the engine's tools, once a capture is in play.
  ///
  /// Before a `.pkt` has been scanned there is nothing for the tools to read,
  /// so chat keeps its plain behaviour. Afterwards the model can look things
  /// up for itself: read tools answer from the engine, and any change it
  /// proposes still goes through the Approve/Reject gate (spec §8).
  ProviderChatService _withTools(ProviderChatService chat) {
    if (_capturePath.trim().isEmpty) return chat;
    chat.toolRuntime = ToolRuntime(
      config: chat.config,
      sidecarBase: _settings?.engineBase ?? 'http://127.0.0.1:5005',
      geminiKey: _geminiKey,
      openaiKey: _openAiKey,
      capturePath: _capturePath,
    );
    return chat;
  }

  /// Compile the current plan into a real .pkt, offline: no Packet Tracer,
  /// no window, no clicks. Answers in the chat either way, including when the
  /// sidecar is not running or there is no plan yet.
  Future<void> _buildPktFromPlan() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _status = 'Compiling the plan into a .pkt (no Packet Tracer)...';
    });
    _jumpToEnd();
    final result = await _compilePkt();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = '';
      _messages = [
        ..._messages,
        ChatMessage(
          role: 'model',
          text: result.text,
          createdAt: DateTime.now().toIso8601String(),
          actions: result.actions,
        ),
      ];
    });
    _jumpToEnd();
  }

  /// The work behind [_buildPktFromPlan]: returns what to say and which
  /// follow-up actions the answer earned. Never throws - a failure is a
  /// message, because a stack trace in the chat helps nobody.
  Future<({String text, List<ChatAction> actions})> _compilePkt() async {
    final intent = _lastIntent;
    if (intent == null) {
      return (
        text: 'There is no plan to compile yet.\n\n'
            'Describe the network you want - for example "2 routers, 3 '
            'switches, 12 PCs and OSPF" - and then build it. No API key is '
            'needed for this.',
        actions: const <ChatAction>[],
      );
    }
    try {
      final svc = _engine();
      if (!await svc.healthy) {
        return (text: AutopilotService.startHint, actions: const <ChatAction>[]);
      }
      final plan = PacketTracerAdapter.autopilotPlan(intent);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[^0-9]'), '')
          .substring(0, 12);
      final res = await svc.pktGenerate(
        plan,
        filename: 'netbuilder-$stamp.pkt',
        project: _project.text.trim(),
      );
      final path = '${res['path'] ?? ''}';
      if (path.isEmpty) {
        return (
          text: 'The generator ran but reported no file, so nothing was '
              'written.',
          actions: const <ChatAction>[],
        );
      }
      // The tool layer may now read this capture, and the model may be asked
      // about it.
      _capturePath = path;
      final warnings = (res['warnings'] as List?) ?? const [];
      final body = StringBuffer()
        ..writeln('**Built a .pkt from your plan.**')
        ..writeln()
        ..writeln('- File: `$path`')
        ..writeln('- Devices: ${res['deviceCount'] ?? '?'}, '
            'links: ${res['linkCount'] ?? '?'}');
      if (warnings.isEmpty) {
        body.writeln('- Warnings: none');
      } else {
        body.writeln('- Warnings:');
        for (final w in warnings) {
          body.writeln('    - $w');
        }
      }
      body
        ..writeln()
        ..writeln('This ran offline - no Packet Tracer and no screen. The '
            'plan came from your own words, so the file is the same whether '
            'or not an API key is set: a key changes how I explain things, '
            'not what gets built. Open it in Packet Tracer to check it, or '
            'analyze it here.')
        ..writeln();
      return (
        text: body.toString(),
        actions: [
          ChatAction(
            kind: 'pkt_scan',
            summary: 'Analyze the generated file',
            payload: {
              'path': path,
              'name': path.split(RegExp(r'[\\/]')).last,
            },
          ),
        ],
      );
    } catch (e) {
      return (
        text: 'I could not build the .pkt: '
            '${e.toString().replaceFirst('Exception: ', '')}',
        actions: const <ChatAction>[],
      );
    }
  }

  /// Decrypt and audit a .pkt completely offline: no Packet Tracer, no
  /// window, no clicks. Findings come back as Approve/Reject cards.
  Future<void> _scanPkt(String path, String name) async {
    final ask = ChatMessage(
      role: 'user',
      text: 'Analyze this capture offline: $name',
      createdAt: DateTime.now().toIso8601String(),
    );
    setState(() {
      _messages = [..._messages, ask];
      _busy = true;
      _status = 'Decrypting and auditing $name (no Packet Tracer)...';
    });
    _jumpToEnd();
    try {
      final svc = _engine();
      // Say plainly what the file is before trying to read it: a .pcap
      // gets an explanation, not a decode error.
      final ident = await svc.pktIdentify(path);
      if (ident['isPkt'] != true) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _status = '';
        });
        _appendSystem(
          '${ident['message'] ?? 'That file is not a .pkt save.'}',
        );
        return;
      }
      // From here on the model may investigate this capture with the
      // engine's read-only tools (spec §2/§3).
      _capturePath = path;
      final report = await svc.pktAudit(
        path,
        project: _project.text.trim(),
      );
      final turn = ChatMessage(
        role: 'model',
        text: _auditText(report, name, path),
        actions: _fixActions(report, path, name),
        createdAt: DateTime.now().toIso8601String(),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '';
        _messages = [..._messages, turn];
      });
      _jumpToEnd();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Could not read that capture: '
            '${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  String _auditText(
    Map<String, dynamic> report,
    String name,
    String path,
  ) {
    final devices = (report['devices'] as List?) ?? const [];
    final findings = <Map<String, dynamic>>[];
    for (final d in devices) {
      for (final f in (((d as Map)['findings'] as List?) ?? const [])) {
        findings.add(Map<String, dynamic>.from(f as Map));
      }
    }
    final high =
        findings.where((f) => '${f['severity']}'.toLowerCase() == 'high').length;
    final b = StringBuffer()
      ..writeln('**Capture decrypted and audited offline.** Packet Tracer '
          'was not opened.')
      ..writeln()
      ..writeln('- File: `$name`')
      ..writeln('- Path: `$path`')
      ..writeln('- Devices: ${devices.length}, links: ${report['linkCount'] ?? '?'}, '
          'findings: ${findings.length} ($high high)')
      ..writeln('- Key: the save container was decrypted with the built-in '
          'Packet Tracer codec; no credential of yours is involved or shown.');
    if (findings.isEmpty) {
      b..writeln()
       ..writeln('Nothing to fix: the saved configuration matches the '
           'topology. Ask me anything about it.');
    } else {
      b..writeln()
       ..writeln('**Prioritised findings** - approve a fix below and I edit '
           'the save and encrypt it back:');
      for (final f in findings.take(12)) {
        b.writeln('- [${f['severity'] ?? 'info'}] ${f['device'] ?? ''} - '
            '${f['text'] ?? ''}');
      }
    }
    return b.toString();
  }

  List<ChatAction> _fixActions(
    Map<String, dynamic> report,
    String path,
    String name,
  ) {
    final out = <ChatAction>[];
    for (final d in ((report['devices'] as List?) ?? const [])) {
      final dev = (((d as Map)['name'] ?? '')).toString();
      for (final f in (((d['findings'] as List?) ?? const []))) {
        final m = Map<String, dynamic>.from(f as Map);
        final cli = ((m['fix_cli'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
        if (cli.isEmpty) continue;
        out.add(
          ChatAction(
            kind: 'pkt_fix',
            summary: '${m['text'] ?? 'fix'}   ->   ${cli.join(' ; ')}',
            payload: {
              'path': path,
              'name': name,
              'device': dev,
              'id': '${m['id'] ?? ''}',
              'severity': '${m['severity'] ?? ''}',
              'text': '${m['text'] ?? ''}',
              'fix_cli': cli,
            },
          ),
        );
      }
    }
    return out;
  }

  Future<String> _applyPktFix(ChatAction action) async {
    final payload = action.payload;
    final fix = <String, dynamic>{
      'id': payload['id'],
      'device': payload['device'],
      'severity': payload['severity'],
      'text': payload['text'],
      'fix_cli': payload['fix_cli'],
    };
    final res = await _engine().pktApplyFixes({
      'path': payload['path'],
      'fixes': [fix],
      'outName': payload['name'],
      'project': _project.text.trim(),
    });
    // Spec §9: do not take the fix at its word. Re-audit the file that came
    // out and check the finding is actually gone before saying it is fixed.
    final verdict = await _verifyRepair(
      beforePath: '${payload['path'] ?? ''}',
      afterPath: '${res['path'] ?? ''}',
      findingId: '${fix['id'] ?? ''}',
    );
    final turn = ChatMessage(
      role: 'model',
      text: '${_appliedText(res, fix)}$verdict',
      actions: [
        ChatAction(
          kind: 'pkt_undo',
          summary: 'Undo this change (restores the save from before it)',
          payload: {'entryId': '${res['entryId'] ?? ''}'},
        ),
        const ChatAction(
          kind: 'ledger',
          summary: 'Show the audit ledger',
          payload: {},
        ),
      ],
      createdAt: DateTime.now().toIso8601String(),
    );
    if (mounted) {
      setState(() => _messages = [..._messages, turn]);
      _jumpToEnd();
    }
    return 'Applied and re-encrypted. The original save was not modified.';
  }

  String _appliedText(Map<String, dynamic> res, Map<String, dynamic> fix) {
    final sha = '${res['sha256'] ?? ''}';
    final b = StringBuffer()
      ..writeln('**Approved fix applied, and the save was encrypted back.**')
      ..writeln()
      ..writeln('- Device: ${fix['device']}')
      ..writeln('- Result: `${res['name'] ?? ''}`')
      ..writeln('- Path: `${res['path'] ?? ''}`')
      ..writeln('- SHA-256: `${sha.length >= 16 ? sha.substring(0, 16) : sha}...`')
      ..writeln('- Bytes: ${res['bytes'] ?? '?'}')
      ..writeln();
    for (final d in ((res['diffs'] as List?) ?? const [])) {
      final m = Map<String, dynamic>.from(d as Map);
      b.writeln('**${m['device']}**');
      for (final c in ((m['changes'] as List?) ?? const [])) {
        final row = Map<String, dynamic>.from(c as Map);
        b.writeln('- ${row['section']}: `${row['command']}`');
      }
      for (final line in ((m['diff'] as List?) ?? const [])) {
        b.writeln('    $line');
      }
      b.writeln();
    }
    b.writeln('The original save was NOT modified - this is a new file. '
        'Open it in Packet Tracer, or Undo to go back.');
    return b.toString();
  }

  /// Re-audit the result and report what the engine actually finds now.
  ///
  /// A failure here never invalidates the applied change: it is reported as
  /// applied-but-unverified rather than silently assumed to have worked.
  Future<String> _verifyRepair({
    required String beforePath,
    required String afterPath,
    required String findingId,
  }) async {
    if (beforePath.trim().isEmpty || afterPath.trim().isEmpty) return '';
    try {
      final engine = _engine();
      final project = _project.text.trim();
      final before = await engine.pktAudit(beforePath, project: project);
      final after = await engine.pktAudit(afterPath, project: project);
      final result = await engine.verifyRepair(
        before: before,
        after: after,
        fixes: [
          {'id': findingId},
        ],
      );
      final summary = '${result['summary'] ?? ''}'.trim();
      if (summary.isEmpty) return '';
      return '\n---\n**Verification:** $summary\n';
    } catch (e) {
      return '\n---\n**Verification:** could not be run ('
          '${e.toString().replaceFirst('Exception: ', '')}). '
          'The change is applied but unverified.\n';
    }
  }

  Future<String> _undoPktFix(ChatAction action) async {
    final res = await _engine().pktUndo(
      entryId: '${action.payload['entryId'] ?? ''}',
    );
    _appendSystem(
      '**Undone.** The save from before that change was restored as '
      '`${res['name'] ?? ''}` (`${res['path'] ?? ''}`). The fixed file is '
      'untouched, so you can compare them.',
    );
    return 'Restored the previous state.';
  }

  Future<String> _showLedger() async {
    final report = await _engine().pktLedger();
    final b = StringBuffer()
      ..writeln('**Audit ledger**')
      ..writeln()
      ..writeln('- Entries: ${report['count'] ?? 0}')
      ..writeln('- Applied changes: ${report['applied'] ?? 0}')
      ..writeln('- Rejections: ${report['rejected'] ?? 0}')
      ..writeln('- Undos: ${report['undone'] ?? 0}')
      ..writeln('- Ledger file: `${report['path'] ?? ''}`')
      ..writeln();
    for (final e in ((report['entries'] as List?) ?? const [])) {
      final row = Map<String, dynamic>.from(e as Map);
      b.writeln('- ${row['at']}  **${row['event']}**  '
          '${row['device'] ?? row['id'] ?? ''}  ${row['decision'] ?? ''}');
    }
    b.writeln();
    b.writeln('Keys are never recorded - a secret command is stored as '
        '•••••••• in the ledger.');
    _appendSystem(b.toString());
    return 'Ledger shown.';
  }

  /// MODIFY: edit the proposed commands before approving them. The edited
  /// list goes through exactly the same gate as an untouched approval.
  Future<void> _modifyAction(
    int messageIndex,
    int actionIndex,
    ChatAction action,
  ) async {
    final controller = TextEditingController(
      text: (action.payload['fix_cli'] as List?)?.join('\n') ?? '',
    );
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modify this fix'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${action.payload['device']}: ${action.payload['text'] ?? ''}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                minLines: 3,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: 'Commands, one per line',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Approve edited'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (edited == null) return;
    final cli = edited
        .split(RegExp(r'[\n;]'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (cli.isEmpty) {
      _appendSystem('Nothing left to apply after the edit.');
      return;
    }
    final payload = Map<String, dynamic>.from(action.payload)..['fix_cli'] = cli;
    setState(() => _busy = true);
    String outcome;
    try {
      outcome = await _applyPktFix(
        ChatAction(
          kind: 'pkt_fix',
          summary: 'edited: ${cli.join(' ; ')}',
          payload: payload,
        ),
      );
    } catch (e) {
      outcome = 'Not applied: ${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = outcome;
      final message = _messages[messageIndex];
      _messages = [..._messages];
      _messages[messageIndex] = message.copyWith(
        executed: [...message.executed, actionIndex.toString()],
      );
    });
  }

  Future<void> _rejectAction(
    int messageIndex,
    int actionIndex,
    ChatAction action,
  ) async {
    setState(() => _busy = true);
    String outcome;
    try {
      await _engine().pktReject(
        action.payload,
        capture: '${action.payload['name'] ?? ''}',
      );
      outcome = 'Rejected. Nothing was written, exported or changed - the '
          'decision is on the ledger.';
    } catch (e) {
      outcome = 'Could not record the rejection: '
          '${e.toString().replaceFirst('Exception: ', '')}';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = outcome;
      final message = _messages[messageIndex];
      _messages = [..._messages];
      _messages[messageIndex] = message.copyWith(
        executed: [...message.executed, actionIndex.toString()],
      );
    });
  }

  /// Put a message on the clipboard verbatim, and say so.
  ///
  /// The confirmation is part of the feature: without it a tap looks like it
  /// did nothing. A clipboard that refuses is reported rather than swallowed.
  Future<void> _copyMessage(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Copied'),
          duration: Duration(seconds: 1),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not copy: $e')),
      );
    }
  }

  /// Stop the answer as it streams. Whatever was already written stays; the
  /// turn simply stops growing.
  void _cancelGeneration() {
    if (!_busy) return;
    _generation.cancel();
    setState(() {
      _busy = false;
      _status = 'Stopped.';
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if ((text.isEmpty && _pending.isEmpty) || _busy) return;
    // Slash commands answer in the chat itself - there is no settings
    // screen to go to any more.
    if (await _handleCommand(text)) {
      _input.clear();
      return;
    }
    final settings = _settings;
    final mem = _memory;
    final attachments = List<ChatImage>.from(_pending);
    _input.clear();
    setState(() {
      _busy = true;
      _pending = [];
      _status = 'Thinking...';
    });
    final token = _generation.begin();

    // Parse the request into a structured plan on every turn, so
    // "build the .pkt" always has something real to compile. This is the same
    // parse the offline planner uses, so the result does not depend on
    // whether a model answered.
    try {
      final normalized = CasualEnglish.normalize(text);
      final brief = normalized.trim().isEmpty ? text : normalized;
      // A follow-up that names no device keeps the standing plan instead of
      // letting the parser's empty-brief fallback invent a fresh 1-router
      // 1-switch lab - which is how "ok build the packet tracer file" used to
      // replace a 12-device plan with a 2-device one.
      _lastIntent = NetworkIntent.planAfterFollowUp(
        previous: _lastIntent,
        parsed: NetworkIntent.parseSimple('chat', brief),
        brief: brief,
      );
    } catch (_) {
      // Keep the previous plan rather than losing it to a parse failure.
    }
    final userTurn = ChatMessage(
      role: 'user',
      text: text,
      images: attachments,
      createdAt: DateTime.now().toIso8601String(),
    );
    setState(() => _messages = [..._messages, userTurn]);
    _jumpToEnd();
    if (mem != null && mem.ready) {
      try {
        await mem.logChat(userTurn, conversation: _conversation);
      } catch (_) {}
    }

    if (settings == null) {
      _appendError('<no settings provider>');
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      final key = await settings.getApiKey();
      final appContext = await _buildContext(mem);
      // STREAM the answer in, the way a chat model does: the bubble grows
      // as tokens arrive instead of the user staring at a spinner.
      final live = StringBuffer();
      ChatMessage? partial;
      await for (final piece in (_chat ??= _withTools(ProviderChatService(
        config: settings.providerConfig,
        geminiKey: key ?? '',
        openaiKey: _openAiKey,
        contextTokens: _contextTokens,
      ))).streamWithTools(
        history: _messages.where((m) => !m.isError).toList(),
        text: text,
        systemContext: appContext,
        attachments: attachments,
      )) {
        // The user may have pressed stop while this was arriving.
        if (!_generation.isCurrent(token)) break;
        live.write(piece);
        if (!mounted) return;
        setState(() {
          final liveTurn = ChatMessage(
            role: 'model',
            text: live.toString(),
            createdAt: DateTime.now().toIso8601String(),
          );
          if (partial == null) {
            _messages = [..._messages, liveTurn];
            partial = liveTurn;
          } else {
            _messages = [..._messages]..last = liveTurn;
          }
        });
        // Follow the answer as it arrives, but never drag the viewport away
        // from someone who scrolled up to reread an earlier answer.
        _noteNewMessage();
      }
      final reply = ChatService.parseReply(live.toString());
      final turn = ChatMessage(
        role: 'model',
        text: reply.text.isEmpty && reply.actions.isEmpty
            ? '(the model returned nothing usable)'
            : reply.text,
        actions: reply.actions,
        createdAt: DateTime.now().toIso8601String(),
      );
      if (!mounted) return;
      setState(() {
        // The live bubble becomes the final turn (with its action cards)
        // rather than being left behind as a duplicate.
        if (partial != null && _messages.isNotEmpty) {
          _messages = [..._messages]..last = turn;
        } else {
          _messages = [..._messages, turn];
        }
        _status = reply.questions.isEmpty
            ? ''
            : 'The assistant asks: ${reply.questions.join('  |  ')}';
      });
      _jumpToEnd();
      if (mem != null && mem.ready) {
        try {
          await mem.logChat(turn, conversation: _conversation);
        } catch (_) {}
      }
    } catch (e) {
      // No key, no quota, model busy, no network: answer from the offline
      // assistant so the user still gets a normal, advisory reply. If even
      // that fails, the typed message is put back so Enter retries it.
      try {
        await _appendOfflinePlan(text, e);
        _failedText = null;
      } catch (offlineError) {
        if (mounted) {
          setState(() {
            _failedText = text;
            _input.text = text;
            _status = 'Could not answer ($offlineError). Your message is '
                'still in the box - press Enter to retry.';
          });
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Answer a message without the model, using the deterministic planner and
  /// the offline assistant. This is what makes the keyless chat a normal
  /// conversation instead of an error: it always says something useful, and
  /// when it cannot plan, it asks for what it needs.
  Future<void> _appendOfflinePlan(String text, Object error) async {
    final normalized = CasualEnglish.normalize(text);
    NetworkIntent? plan;
    List<String> suggestions = const [];
    try {
      final parsed = NetworkIntent.parseSimple(
        'offline-chat',
        normalized.isEmpty ? text : normalized,
      );
      final withMemory = PlannerMemoryService.apply(
        parsed,
        rules: await _learnedRules(),
        preferences: await _learnedPrefs(),
      );
      plan = withMemory;
      // The offline planner is the one that always exists, so its plan is
      // what the builder offers to compile. Same retention rule as the
      // online path: a follow-up that names no device keeps the standing
      // plan instead of replacing it with the parser's default lab.
      _lastIntent = NetworkIntent.planAfterFollowUp(
        previous: _lastIntent,
        parsed: withMemory,
        brief: normalized.isEmpty ? text : normalized,
      );
      suggestions = PlannerSuggestionsService.forIntent(
        withMemory,
        target: _target,
      );
    } catch (_) {
      plan = null;
    }
    final reason = error
        .toString()
        .replaceFirst('Exception: ', '')
        .split('\n')
        .first
        .trim();
    final reply = OfflineAssistantService.reply(
      rawText: text,
      normalized: normalized,
      target: _target,
      plan: plan,
      suggestions: suggestions,
      modelError: reason,
      // The offline assistant is stateless without this: the turns are
      // how it remembers what the user asked first.
      history: _messages.where((m) => !m.isError).toList(),
    );
    final turn = ChatMessage(
      role: 'model',
      text: reply.text,
      createdAt: DateTime.now().toIso8601String(),
      // Offered whether or not a key is set: the plan is already parsed, so
      // the .pkt can be built either way.
      actions: plan == null
          ? const <ChatAction>[]
          : const [
              ChatAction(
                kind: 'pkt_generate',
                summary: 'Build a .pkt from this plan (offline, no Packet '
                    'Tracer)',
                payload: <String, dynamic>{},
              ),
            ],
    );
    if (!mounted) return;
    setState(() {
      _messages = [..._messages, turn];
      _status = reply.questions.isEmpty
          ? ''
          : 'The assistant asks: ${reply.questions.join('  |  ')}';
    });
    _jumpToEnd();
  }

  void _appendError(String message) {
    final turn = ChatMessage(
      role: 'system',
      text: 'Could not reach the model: $message',
      createdAt: DateTime.now().toIso8601String(),
    );
    if (!mounted) return;
    setState(() => _messages = [..._messages, turn]);
    _jumpToEnd();
  }

  // --- attachments -------------------------------------------------------

  Future<void> _pickImageFiles() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (picked == null) return;
      for (final file in picked.files) {
        List<int>? bytes = file.bytes;
        if (bytes == null && file.path != null) {
          bytes = await File(file.path!).readAsBytes();
        }
        if (bytes == null) continue;
        final result = await _chat!.persistImage(
          bytes: bytes,
          name: file.name,
          mimeType: _mimeFor(file.name),
        );
        if (!mounted) return;
        if (!result.ok) {
          setState(() => _status = result.error);
          continue;
        }
        setState(() => _pending = [..._pending, result.image!]);
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Could not attach: $e');
    }
  }

  /// Attach a screenshot the run already saved. This is the useful one: the
  /// engine wrote the exact frame it was looking at when it got stuck.
  Future<void> _attachScreenshot() async {
    List<Map<String, dynamic>> shots;
    try {
      shots = await _engine().shots();
    } catch (e) {
      if (mounted) {
        setState(() => _status = AutopilotService.startHint);
      }
      return;
    }
    if (!mounted) return;
    if (shots.isEmpty) {
      setState(
        () => _status =
            'No evidence screenshots yet - run a build first, or attach an '
            'image file of your own.',
      );
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView.builder(
        itemCount: shots.length,
        itemBuilder: (context, index) {
          final shot = shots[index];
          final bytes = (shot['bytes'] as num?)?.toInt() ?? 0;
          return ListTile(
            dense: true,
            leading: const Icon(Icons.image_outlined),
            title: Text(shot['name']?.toString() ?? ''),
            subtitle: Text(
              '${shot['modified'] ?? ''}  ·  ${(bytes / 1024).round()} KB',
            ),
            onTap: () => Navigator.pop(context, shot['name']?.toString()),
          );
        },
      ),
    );
    if (choice == null || choice.isEmpty) return;
    setState(() => _status = 'Loading $choice...');
    final shot = await _engine().shot(choice);
    final encoded = (shot['data'] ?? '').toString();
    if (encoded.isEmpty) {
      if (mounted) setState(() => _status = 'Could not read $choice.');
      return;
    }
    final result = await _chat!.persistImage(
      bytes: base64Decode(encoded),
      name: choice,
      mimeType: 'image/png',
    );
    if (!mounted) return;
    setState(() {
      if (result.ok) {
        _pending = [..._pending, result.image!];
        _status = '';
      } else {
        _status = result.error;
      }
    });
  }

  Future<void> _pasteText() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = (data?.text ?? '').trim();
      if (text.isEmpty) {
        if (mounted) {
          setState(
            () => _status =
                'The clipboard has no text. (Image paste needs a clipboard '
                'plugin this app does not ship; save the screenshot and use '
                'the image button instead.)',
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _input.text = _input.text.isEmpty ? text : '${_input.text}\n$text';
        _status = '';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Clipboard read failed: $e');
    }
  }

  String _mimeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    return 'image/png';
  }

  // --- approving an action ----------------------------------------------

  Future<void> _runAction(int messageIndex, int actionIndex) async {
    final message = _messages[messageIndex];
    final action = message.actions[actionIndex];
    final mem = _memory;
    setState(() => _busy = true);
    String outcome;
    try {
      switch (action.kind) {
        case 'save_rule':
          final rule = (action.payload['rule'] ?? '').toString().trim();
          if (mem == null || !mem.ready) {
            outcome = 'Memory is not ready, so nothing was saved.';
            break;
          }
          if (rule.isEmpty) {
            outcome = 'That rule was empty.';
            break;
          }
          final targets =
              (action.payload['targets'] ?? 'all').toString().trim();
          await mem.addRule(rule, targets: targets.isEmpty ? 'all' : targets);
          outcome = 'Rule saved - the planner will use it from now on.';
          break;
        case 'save_preference':
          final key = (action.payload['key'] ?? '').toString().trim();
          if (mem == null || !mem.ready) {
            outcome = 'Memory is not ready, so nothing was saved.';
            break;
          }
          if (key.isEmpty) {
            outcome = 'That preference had no name.';
            break;
          }
          await mem.setPref(key, (action.payload['value'] ?? '').toString());
          outcome = 'Preference saved.';
          break;
        case 'paste_cli':
        case 'config_pcs':
          outcome = await _startSidecarFix(action);
          break;
        case 'run_control':
          outcome = await _runControl(action);
          break;
        case 'pkt_fix':
          outcome = await _applyPktFix(action);
          break;
        case 'pkt_undo':
          outcome = await _undoPktFix(action);
          break;
        case 'pkt_scan':
          final scanPath = '${action.payload['path'] ?? ''}';
          if (scanPath.isEmpty) {
            outcome = 'That card has no file path.';
            break;
          }
          await _scanPkt(scanPath, '${action.payload['name'] ?? scanPath}');
          outcome = 'Re-analyzed.';
          break;
        case 'pkt_generate':
          await _buildPktFromPlan();
          outcome = '';
          break;
        case 'ledger':
          outcome = await _showLedger();
          break;
        case 'open_project':
          final project = (action.payload['project'] ?? '').toString().trim();
          if (project.isEmpty) {
            outcome = 'No project name in that action.';
            break;
          }
          widget.onOpenProject?.call(project);
          outcome = 'Opened $project for review.';
          break;
        default:
          outcome = 'Unsupported action: ${action.kind}';
      }
    } catch (e) {
      outcome = 'Failed: ${e.toString().replaceFirst('Exception: ', '')}';
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = outcome;
      final executed = [...message.executed, actionIndex.toString()];
      final updated = message.copyWith(executed: executed);
      _messages = [..._messages];
      _messages[messageIndex] = updated;
    });
    if (mem != null && mem.ready && message.id != null) {
      try {
        await mem.updateChat(message.id!, _messages[messageIndex]);
      } catch (_) {}
    }
  }

  /// CLI / desktop corrections go through the same verified path as any other
  /// fix run: `mode: fixes` re-verifies on screen and reports honestly.
  Future<String> _startSidecarFix(ChatAction action) async {
    final svc = _engine();
    if (!await svc.healthy) return AutopilotService.startHint;
    final steps = <Map<String, dynamic>>[];
    if (action.kind == 'paste_cli') {
      final raw = (action.payload['configs'] as Map?) ?? const {};
      final configs = <String, String>{};
      raw.forEach((key, value) {
        final device = key.toString().trim();
        final body = value.toString().trim();
        if (device.isNotEmpty && body.isNotEmpty) configs[device] = body;
      });
      if (configs.isEmpty) return 'Nothing to type - the action had no CLI.';
      steps.add({
        'action': 'paste_cli',
        'configs': configs,
        'typing_delay_ms': 25,
      });
    } else {
      final raw = (action.payload['pcs'] as Map?) ?? const {};
      final pcs = <String, Map<String, String>>{};
      raw.forEach((key, value) {
        if (value is! Map) return;
        final device = key.toString().trim();
        final ip = (value['ip'] ?? '').toString().trim();
        if (device.isEmpty || ip.isEmpty) return;
        pcs[device] = {
          'ip': ip,
          'mask': (value['mask'] ?? '255.255.255.0').toString().trim(),
          'gw': (value['gw'] ?? '').toString().trim(),
        };
      });
      if (pcs.isEmpty) return 'Nothing to set - the action had no valid IPs.';
      steps.add({'action': 'config_pcs', 'pcs': pcs});
    }
    await svc.start({
      'project': _project.text.trim(),
      'steps': steps,
      'mode': 'fixes',
    });
    return 'Started a fix run. It verifies on screen and reports what it '
        'could not prove - watch the Detail tab, and use PAUSE/STOP here.';
  }

  Future<String> _runControl(ChatAction action) async {
    final svc = _engine();
    if (!await svc.healthy) return AutopilotService.startHint;
    final command = (action.payload['command'] ?? 'pause').toString().toLowerCase();
    switch (command) {
      case 'resume':
        await svc.resume();
        return 'Resume requested.';
      case 'stop':
        await svc.stop();
        return 'Stop requested.';
      default:
        await svc.pause();
        return 'Pause requested - the run parks at its next safe boundary.';
    }
  }

  // --- build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // The chat is the screen. Everything that used to sit in a strip above
    // it - the project field, the live-context chip, the run controls - now
    // lives behind the Tools button below or in Settings, each with a label.
    // Nothing was removed, only moved.
    return Column(
      children: [
        _conversationHeader(),
        if (_engineReachable == false) _engineBanner(),
        Expanded(
          child: _messages.isEmpty
              ? _emptyState()
              : Stack(
                  children: [
                    Semantics(
                      container: true,
                      label: 'Conversation with the NetBuilder assistant',
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        // The typing bubble is for the wait before an answer
                        // starts. Once the answer is streaming in, its own
                        // bubble is already there and a second one would be a
                        // placeholder under a growing message.
                        itemCount: _messages.length + (_waiting ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _messages.length) {
                            return const _TypingBubble();
                          }
                          return _bubble(index);
                        },
                      ),
                    ),
                    if (!_atBottom && _messages.isNotEmpty)
                      Positioned(
                        right: AppTheme.s16,
                        bottom: AppTheme.s12,
                        child: _JumpToLatest(
                          unseen: _unseen,
                          onTap: () => _jumpToEnd(),
                        ),
                      ),
                  ],
                ),
        ),
        if (_status.isNotEmpty)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(_status, style: const TextStyle(fontSize: 12)),
                ),
                // RETRY: a failed turn keeps the typed message, so this
                // re-sends it without any retyping.
                if (_failedText != null)
                  TextButton(
                    onPressed: _busy ? null : _retry,
                    child: const Text('Retry'),
                  ),
              ],
            ),
          ),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        _contextBar(),
        _composer(),
      ],
    );
  }

  /// The conversation's own bar: which chat this is, how much is in it, and
  /// the two things you do to a conversation rather than inside it.
  ///
  /// This is what makes the chat feel like a chat app rather than one long
  /// scroll: a name, a size, a way to start another one and a way to clear
  /// it - none of which should require opening the settings sidebar.
  Widget _conversationHeader() {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AppTheme.s16,
        AppTheme.s6,
        AppTheme.s8,
        AppTheme.s6,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      // A 360px phone has no room for a name, a count and two labelled
      // buttons. On a narrow window the label goes and the icon stays, which
      // is the same control with a tooltip instead of a caption - never a
      // missing control.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final roomy = constraints.maxWidth >= 420;
          return Row(
            children: [
              Icon(
                Icons.forum_outlined,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: AppTheme.s8),
              Flexible(
                child: Text(
                  _conversation,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (roomy) ...[
                const SizedBox(width: AppTheme.s8),
                Text(
                  '${_messages.length} message(s) · $_target',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const Spacer(),
              if (roomy)
                TextButton.icon(
                  onPressed: _busy ? null : _startNewChat,
                  icon: const Icon(Icons.add_comment_outlined, size: 16),
                  label: const Text('New chat'),
                )
              else
                IconButton(
                  tooltip: 'New chat',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.add_comment_outlined, size: 18),
                  onPressed: _busy ? null : _startNewChat,
                ),
              IconButton(
                tooltip: 'Clear this conversation',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                onPressed: _busy ? null : _clearChat,
              ),
            ],
          );
        },
      ),
    );
  }

  /// Open a fresh conversation. The old one keeps its own transcript in
  /// memory and stays in the sidebar, so nothing is lost by starting over.
  Future<void> _startNewChat() async {
    final now = DateTime.now();
    final name =
        'chat ${now.hour}:${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    setState(() {
      _project.text = name;
      _messages = [];
      _status = '';
      _unseen = 0;
    });
    await _load();
  }

  /// Says plainly that the `.pkt` engine cannot be reached, and offers the
  /// one thing that fixes it.
  ///
  /// Before this, that fact only appeared inside a chat bubble, after the user
  /// had already tried something - which is what made the Android build feel
  /// broken. On a phone the reason is specific and worth naming: the address
  /// has to be the PC, never the phone itself.
  Widget _engineBanner() {
    final address = _settings?.engineBase ?? '';
    final mobile = SettingsService.isMobile;
    final status = EngineStatus.instance;
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: Icon(Icons.cloud_off_outlined, size: 18),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    mobile
                        ? 'No .pkt engine at $address. On a phone the engine '
                              'runs on your PC, so this must be that PC\'s '
                              'address - not 127.0.0.1.'
                        : 'No .pkt engine at $address. Planning, tools and '
                              '.pkt files all work without it.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            // The actions wrap: at a phone width this banner must not be the
            // thing that overflows the chat.
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (_engineStarting)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  TextButton(
                    onPressed: _startEngine,
                    child: const Text('Start engine'),
                  ),
                TextButton(
                  onPressed: () => Scaffold.maybeOf(context)?.openDrawer(),
                  child: const Text('Set address'),
                ),
                IconButton(
                  tooltip: 'Check again',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: status.isBusy ? null : _checkEngine,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Ask the engine whether anything answers there. Never assumed - and
  /// answered from [EngineStatus]'s cache, so a missing engine cannot make
  /// the chat feel slow.
  Future<void> _checkEngine() async {
    final ok = await EngineStatus.instance.probe();
    if (!mounted) return;
    setState(() => _engineReachable = ok);
  }

  /// The banner's own "make it work" button: start the engine from here
  /// instead of sending the user to a terminal.
  Future<void> _startEngine() async {
    setState(() => _engineStarting = true);
    final ok = await EngineStatus.instance.ensure(force: true);
    if (!mounted) return;
    setState(() {
      _engineStarting = false;
      _engineReachable = ok;
    });
    if (!ok) {
      _appendSystem(
        'I could not start the local engine.\n${EngineStatus.instance.summary}\n'
        'Everything except driving Packet Tracer still works. Open '
        '"Local engine status" from the feature hub for the full report.',
      );
    } else {
      _appendSystem('Local engine is running. Packet Tracer builds are ready.');
    }
  }

  /// The two capture actions, and a way through to everything else.
  ///
  /// Run controls, the ledger, GNS3, live context and the project name are not
  /// touched while chatting, so they live in Settings now; this sheet keeps only
  /// what a person actually reaches for mid-conversation.
  void _openTools() {
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHeader(theme, 'Capture'),
              ListTile(
                leading: const Icon(Icons.build_circle_outlined),
                title: const Text('Build a .pkt from the current plan'),
                subtitle: const Text('Offline - no Packet Tracer, no key '
                    'needed'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _buildPktFromPlan();
                },
              ),
              ListTile(
                leading: const Icon(Icons.router_outlined),
                title: const Text('Analyze a .pkt'),
                subtitle: const Text('Decrypt, audit and propose fixes'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _pickPkt();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Clear this conversation'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _clearChat();
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                subtitle: const Text('Run controls, ledger, GNS3, live '
                    'context, project, API key, folders'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Scaffold.maybeOf(context)?.openDrawer();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetHeader(ThemeData theme, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
  );

  Future<void> _clearChat() async {
    final mem = _memory;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear this conversation?'),
        content: const Text(
          'Saved rules and preferences stay. Only the chat history is '
          'deleted - the attachments are left on disk.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (mem != null && mem.ready) {
      try {
        await mem.clearChat();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _messages = [];
      _status = '';
    });
  }

  /// The first thing a new user sees, so it does two jobs: says what this is
  /// for, and offers the openers that show the range in one tap. A blank box
  /// under "Ask me anything" is where people freeze.
  Widget _emptyState() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      // Scrollable so a short phone screen shrinks this instead of
      // overflowing it (360x640 used to overflow the Column by 11px).
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.s20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // The assistant's mark: one quiet gradient orb, the only
              // decoration on the empty screen.
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [scheme.primary, scheme.tertiary],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.25),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Icon(Icons.auto_awesome, size: 26, color: scheme.onPrimary),
              ),
              const SizedBox(height: AppTheme.s16),
              Text(
                'How can I help your network today?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: AppTheme.s8),
              Text(
                'Describe a lab, attach a screenshot, or drop in a .pkt save - '
                'I plan it, audit it and prove it with you. Nothing changes '
                'until you approve it.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppPalette.mutedText(scheme),
                ),
              ),
              const SizedBox(height: AppTheme.s24),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Start with one of these',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(height: AppTheme.s10),
              // Starter prompts as cards, one or two across depending on the
              // room there is. A chip row hid what each opener actually did;
              // a card can say it.
              LayoutBuilder(
                builder: (context, constraints) {
                  const gap = AppTheme.s10;
                  final twoAcross = constraints.maxWidth >= 560;
                  final cardWidth = twoAcross
                      ? (constraints.maxWidth - gap) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final opener in _openers)
                        SizedBox(
                          width: cardWidth,
                          child: _openerCard(opener),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _openerCard(({String label, String prompt, IconData icon}) opener) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: AppPalette.neutralFill(scheme),
      borderRadius: BorderRadius.circular(AppTheme.rMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        onTap: () => _useOpener(opener),
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.s12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppTheme.s10),
                ),
                child: Icon(opener.icon, size: 18, color: scheme.primary),
              ),
              const SizedBox(width: AppTheme.s10),
              Expanded(
                child: Text(
                  opener.label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_upward_rounded,
                size: 16,
                color: AppPalette.mutedText(scheme),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Four ways in, each one a capability the app actually has: plan a
  /// network, check an address, hunt a fault, or read a saved file.
  static const _openers = <({String label, String prompt, IconData icon})>[
    (
      label: 'Design a small office network',
      prompt:
          'Design a small office network: 1 router, 2 switches, a few PCs, '
          'DHCP and internet access. Then explain the addressing.',
      icon: Icons.design_services_outlined,
    ),
    (
      label: 'Check this subnet',
      prompt:
          'Check the addressing in this plan: are any addresses duplicated, '
          'do the subnets overlap, and is every gateway valid?',
      icon: Icons.calculate_outlined,
    ),
    (
      label: 'Why is my lab broken?',
      prompt:
          'Something is not working in this lab. Ask me for the evidence you '
          'need, then tell me the most likely cause and how to prove it.',
      icon: Icons.troubleshoot,
    ),
    (
      label: 'Explain this config',
      prompt:
          'Read the configuration I am about to paste and explain what it '
          'does, line by line, in plain English.',
      icon: Icons.description_outlined,
    ),
    (
      label: 'Plan a VLAN lab',
      prompt:
          'Plan a VLAN lab with trunks, inter-VLAN routing and a management '
          'VLAN, and tell me what to verify on each device.',
      icon: Icons.account_tree_outlined,
    ),
  ];

  /// Put the opener in the composer rather than sending it: the user keeps
  /// control of their own first message, and can edit the wording first.
  void _useOpener(({String label, String prompt, IconData icon}) opener) {
    setState(() => _input.text = opener.prompt);
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  Widget _bubble(int index) {
    final message = _messages[index];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isUser = message.isUser;
    final isError = message.isError;
    final stamped = _stamp(message.createdAt);
    final dark = scheme.brightness == Brightness.dark;

    // Modern chat anatomy: the assistant's answer sits on the page itself -
    // the words are the interface - while the user's turns are the only
    // strongly filled bubbles. Ownership reads at a glance, and a long
    // answer reads like a document instead of a card pile.
    final fill = isError
        ? AppPalette.dangerFill(scheme)
        : isUser
        ? scheme.primary
        : AppPalette.neutralFill(scheme);
    final ink = isError
        ? AppPalette.danger(scheme)
        : isUser
        ? scheme.onPrimary
        : scheme.onSurface;

    return Semantics(
      label: isUser ? 'You said' : 'Assistant said',
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppTheme.s14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment:
              isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (!isUser) _avatar(isUser, isError),
            if (!isUser) const SizedBox(width: AppTheme.s10),
            Flexible(
              child: Column(
                crossAxisAlignment:
                    isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  _messageHeader(isUser, isError, stamped),
                  Container(
                    // ~66 characters at 14px: the reading-optimised measure
                    // (preset 03, Information Architects).
                    constraints: const BoxConstraints(
                      maxWidth: AppTheme.readingMeasure,
                    ),
                    padding: const EdgeInsets.fromLTRB(
                      AppTheme.s14,
                      AppTheme.s12,
                      AppTheme.s14,
                      AppTheme.s12,
                    ),
                    decoration: BoxDecoration(
                      color: fill,
                      borderRadius: BorderRadius.circular(AppTheme.rLg),
                      // A whisper of elevation under an assistant answer on
                      // light surfaces; on dark, separation is contrast.
                      boxShadow: dark || isUser || isError
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.05),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              ),
                            ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (message.text.trim().isNotEmpty)
                          // The bubble chooses the ink, so text and fill can
                          // never disagree (the invisible-text bug class).
                          DefaultTextStyle(
                            style: (theme.textTheme.bodyMedium ??
                                    const TextStyle())
                                .copyWith(color: ink, height: 1.5),
                            // Headings, bullets, fenced code and tables
                            // render as such; selection is kept so commands
                            // can be copied.
                            child: SelectionArea(
                              child: ChatMarkdownView(source: message.text),
                            ),
                          ),
                        if (message.images.isNotEmpty) ...[
                          const SizedBox(height: AppTheme.s8),
                          Wrap(
                            spacing: AppTheme.s6,
                            runSpacing: AppTheme.s6,
                            children: [
                              for (final image in message.images)
                                _thumbnail(image),
                            ],
                          ),
                        ],
                        if (message.actions.isNotEmpty) ...[
                          const SizedBox(height: AppTheme.s8),
                          for (var i = 0; i < message.actions.length; i++)
                            _actionCard(index, i, message.actions[i],
                                message.executed.contains(i.toString())),
                        ],
                      ],
                    ),
                  ),
                  // The message's own controls, OUTSIDE the bubble: copy,
                  // answer again, remember - quiet utilities under the turn.
                  _messageActions(index, message, isUser),
                ],
              ),
            ),
            if (isUser) const SizedBox(width: AppTheme.s10),
            if (isUser) _avatar(isUser, isError),
          ],
        ),
      ),
    );
  }

  /// Who said it and when. The name is a label rather than a badge: the
  /// bubble's own alignment already says who spoke, and this is the part a
  /// person scans when they come back to a conversation an hour later.
  Widget _messageHeader(bool isUser, bool isError, String stamped) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s4, left: 2, right: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isError
                ? 'App'
                : isUser
                ? 'You'
                : 'Assistant',
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (stamped.isNotEmpty) ...[
            const SizedBox(width: AppTheme.s6),
            Text(
              stamped,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.7,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _avatar(bool isUser, bool isError) {
    final scheme = Theme.of(context).colorScheme;
    // The assistant gets the one saturated mark in the conversation - a
    // solid primary disc with a sparkle - so "who can act on the world"
    // is visible without reading a word. The user stays quiet.
    final background = isError
        ? AppPalette.dangerFill(scheme)
        : isUser
        ? scheme.surfaceContainerHighest
        : scheme.primary;
    final foreground = isError
        ? AppPalette.danger(scheme)
        : isUser
        ? scheme.onSurfaceVariant
        : scheme.onPrimary;
    final icon = isError
        ? Icons.report_gmailerrorred_outlined
        : isUser
        ? Icons.person_outline
        : Icons.auto_awesome;
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.s18),
      child: CircleAvatar(
        radius: 14,
        backgroundColor: background,
        child: Icon(icon, size: 15, color: foreground),
      ),
    );
  }

  /// HH:mm from the stored ISO string, or '' when the row has no timestamp
  /// (older transcripts) - an invented time would be worse than none.
  static String _stamp(String createdAt) {
    final parsed = DateTime.tryParse(createdAt);
    if (parsed == null) return '';
    final local = parsed.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  /// The row under a message. Always visible rather than hover-only: hover
  /// does not exist on a tablet, and a control that appears only on hover is a
  /// control half the users never find.
  Widget _messageActions(int index, ChatMessage message, bool isUser) {
    final theme = Theme.of(context);
    final muted = AppPalette.mutedText(theme.colorScheme);
    final style = TextButton.styleFrom(
      foregroundColor: muted,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.s8),
      minimumSize: const Size(0, 30),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: theme.textTheme.labelSmall,
    );
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.s4),
      child: Row(
        children: [
          TextButton.icon(
            style: style,
            onPressed: () => _copyMessage(message.text),
            icon: const Icon(Icons.copy_all_outlined, size: 14),
            label: const Text('Copy'),
          ),
          if (isUser)
            TextButton.icon(
              style: style,
              onPressed: _busy
                  ? null
                  : () {
                      // Editing and resending in one step: the text goes back
                      // into the composer, where it can be changed before it
                      // is sent again.
                      setState(() {
                        _input.text = message.text;
                        _input.selection = TextSelection.collapsed(
                          offset: _input.text.length,
                        );
                      });
                      _composerFocus.requestFocus();
                    },
              icon: const Icon(Icons.edit_outlined, size: 14),
              label: const Text('Edit and resend'),
            )
          else ...[
            TextButton.icon(
              style: style,
              onPressed: _busy ? null : _regenerate,
              icon: const Icon(Icons.refresh, size: 14),
              label: const Text('Answer again'),
            ),
            TextButton.icon(
              style: style,
              onPressed: _busy
                  ? null
                  : () => _rememberFromMessage(message),
              icon: const Icon(Icons.bookmark_add_outlined, size: 14),
              label: const Text('Remember as a rule'),
            ),
          ],
        ],
      ),
    );
  }

  /// Ask the same question again. It re-sends the user turn before this one,
  /// which is the only way to get a different answer for the same question.
  Future<void> _regenerate() async {
    final lastUser = _messages.lastWhere(
      (m) => m.isUser,
      orElse: () => const ChatMessage(role: 'user', text: ''),
    );
    if (lastUser.text.trim().isEmpty) {
      _appendSystem('There is nothing to answer again yet.');
      return;
    }
    _input.text = lastUser.text;
    await _send();
  }

  /// Store the answer as a rule the planner reads. The value of a correction
  /// is that it changes the next plan, not just this conversation - which is
  /// what the memory already does, so this writes there.
  Future<void> _rememberFromMessage(ChatMessage message) async {
    final mem = _memory;
    if (mem == null || !mem.ready) {
      _appendSystem(
        'Memory is not available in this session, so the rule was not saved.',
      );
      return;
    }
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _RuleDialog(initial: message.text),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      await mem.addRule(text.trim());
      _appendSystem('Saved as a rule: ${text.trim()}');
    } catch (e) {
      _appendSystem('Could not save that rule: $e');
    }
  }

  Widget _thumbnail(ChatImage image) {
    final file = File(image.path);
    return Tooltip(
      message: '${image.name} ${image.sizeLabel}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: file.existsSync()
            ? Image.file(
                file,
                width: 120,
                height: 80,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _brokenThumb(image),
              )
            : _brokenThumb(image),
      ),
    );
  }

  Widget _brokenThumb(ChatImage image) => Container(
    width: 120,
    height: 80,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).dividerColor),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      'missing\n${image.name}',
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 10),
    ),
  );

  Widget _actionCard(int messageIndex, int actionIndex, ChatAction action,
      bool done) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = action.touchesPacketTracer
        ? AppPalette.warning(scheme)
        : scheme.primary;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        border: Border(left: BorderSide(color: accent, width: 3)),
        boxShadow: [
          BoxShadow(
            color: scheme.outlineVariant.withValues(alpha: 0.55),
            blurRadius: 0,
            spreadRadius: 0.8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                action.touchesPacketTracer
                    ? Icons.warning_amber_rounded
                    : Icons.bolt_outlined,
                size: 18,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  action.label,
                  style: const TextStyle(fontSize: 13, height: 1.35),
                ),
              ),
            ],
          ),
          if (action.touchesPacketTracer)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 26),
              child: Text(
                'Approving this types into Packet Tracer and is verified on '
                'screen afterwards.',
                style: TextStyle(
                  fontSize: 11,
                  color: AppPalette.warning(scheme),
                ),
              ),
            ),
          _actionPayload(action),
          const SizedBox(height: 6),
          done
              ? Row(
                  children: [
                    Icon(Icons.check_circle,
                        size: 18, color: AppPalette.success(scheme)),
                    const SizedBox(width: 4),
                    Text(
                      'Done',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppPalette.success(scheme),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // THE APPROVAL GATE: nothing is written, exported
                    // or applied until Approve is pressed. Reject is
                    // recorded and has no side effects at all.
                    if (action.kind == 'pkt_fix') ...[
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _rejectAction(
                                  messageIndex,
                                  actionIndex,
                                  action,
                                ),
                        child: const Text('Reject'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _modifyAction(
                                  messageIndex,
                                  actionIndex,
                                  action,
                                ),
                        child: const Text('Modify'),
                      ),
                    ],
                    const Spacer(),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _runAction(messageIndex, actionIndex),
                      child: Text(
                        action.kind == 'pkt_generate'
                            ? 'Build .pkt'
                            : 'Approve',
                      ),
                    ),
                  ],
                ),
        ],
      ),
    );
  }

  /// The exact payload, always shown before the button is pressed.
  ///
  /// A one-line label ("type CLI on 2 devices") is not enough to approve
  /// commands with: the entire value of the gate is that a person reads what
  /// will be typed *before* it is typed. Hiding the payload behind an approve
  /// button would make this card a rubber stamp.
  Widget _actionPayload(ChatAction action) {
    final lines = <String>[];
    switch (action.kind) {
      case 'paste_cli':
        final configs = (action.payload['configs'] as Map?) ?? const {};
        configs.forEach((device, body) {
          lines.add('$device:');
          for (final line in body.toString().split('\n')) {
            if (line.trim().isEmpty) continue;
            lines.add('    ${line.trim()}');
          }
        });
        break;
      case 'config_pcs':
        final pcs = (action.payload['pcs'] as Map?) ?? const {};
        pcs.forEach((device, value) {
          if (value is! Map) return;
          final mask = (value['mask'] ?? '').toString().trim();
          final gateway = (value['gw'] ?? '').toString().trim();
          lines.add(
            '$device: ip ${value['ip']}'
            '${mask.isEmpty ? '' : ' / $mask'}'
            '${gateway.isEmpty ? '' : '  gateway $gateway'}',
          );
        });
        break;
      case 'save_rule':
        lines.add((action.payload['rule'] ?? '').toString().trim());
        break;
      case 'save_preference':
        lines.add('${action.payload['key']} = ${action.payload['value']}');
        break;
      case 'run_control':
        lines.add((action.payload['command'] ?? '').toString());
        break;
      case 'open_project':
        lines.add((action.payload['project'] ?? '').toString());
        break;
    }
    final body = lines.where((line) => line.trim().isNotEmpty).join('\n');
    if (body.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8, left: 26),
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: AppPalette.infoFill(scheme),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        child: SelectableText(
          body,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }

  /// Re-send the turn that failed, straight from the retry button.
  Future<void> _retry() async {
    final text = _failedText;
    if (text == null || text.trim().isEmpty) return;
    _failedText = null;
    _input.text = text;
    await _send();
  }

  /// Reading-first context meter (preset 03): one quiet line saying how much
  /// of the context budget this conversation uses, and whether earlier turns
  /// have been compacted into memory.
  Widget _contextBar() {
    final plan = ContextBudget.plan(
      history: _messages.where((m) => !m.isError).toList(),
      systemContext: '',
      pendingText: _input.text,
      budgetTokens: _contextTokens,
    );
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
      child: Row(
        children: [
          Icon(
            Icons.memory_outlined,
            size: 13,
            color: AppPalette.mutedText(theme.colorScheme),
          ),
          const SizedBox(width: 6),
          // Both parts are flexible so a narrow window (or a long
          // number) ellipsises instead of overflowing.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    'Context ${_thousands(plan.tokensUsed)} / '
                    '${_thousands(plan.budgetTokens)} tokens '
                    '(${(plan.usedFraction * 100).toStringAsFixed(1)}%)',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: AppPalette.mutedText(theme.colorScheme),
                    ),
                  ),
                ),
                if (plan.summarized) ...[
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      '${plan.turnsSummarized} earlier message(s) '
                      'summarized into memory',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _thousands(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }

  Widget _composer() {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_pending.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final image in _pending)
                      InputChip(
                        avatar: const Icon(Icons.image_outlined, size: 16),
                        label: Text(image.name, style: const TextStyle(fontSize: 12)),
                        onDeleted: () => setState(
                          () => _pending = _pending
                              .where((i) => i.path != image.path)
                              .toList(),
                        ),
                      ),
                  ],
                ),
              ),
            // One unified composer capsule - field, attach and send inside a
            // single rounded surface, the way a modern chat input reads.
            Container(
              padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
              decoration: BoxDecoration(
                color: AppPalette.raised(scheme),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.8),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // One media picker, the way a chat app has one: every way
                  // of attaching something lives behind it, and the chat keeps
                  // its space.
                  PopupMenuButton<String>(
                    tooltip: 'Attach',
                    enabled: !_busy,
                    icon: const Icon(Icons.add_circle_outline),
                    onSelected: (value) {
                      if (value == 'image') {
                        _pickImageFiles();
                      } else if (value == 'screenshot') {
                        _attachScreenshot();
                      } else if (value == 'pkt') {
                        _pickPkt();
                      } else if (value == 'paste') {
                        _pasteText();
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'image',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.add_photo_alternate_outlined),
                          title: Text('Photo or image file'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'screenshot',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.photo_library_outlined),
                          title: Text('Screenshot from the run'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'pkt',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.router_outlined),
                          title: Text('Packet Tracer save (.pkt)'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'paste',
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.content_paste),
                          title: Text('Paste clipboard text'),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    // ENTER SENDS, SHIFT+ENTER ADDS A LINE.  A
                    // CallbackShortcuts sits closer to the field than the
                    // app-wide text-editing shortcuts, so it wins for a
                    // bare Enter while Shift+Enter falls through to the
                    // default newline.  TextInputAction.send also makes an
                    // on-screen Android keyboard show a Send key.
                    child: CallbackShortcuts(
                      bindings: <ShortcutActivator, VoidCallback>{
                        const SingleActivator(LogicalKeyboardKey.enter):
                            _send,
                        const SingleActivator(LogicalKeyboardKey.numpadEnter):
                            _send,
                      },
                      child: TextField(
                        controller: _input,
                        focusNode: _composerFocus,
                        enabled: !_busy,
                        autofocus: true,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.send,
                        decoration: InputDecoration(
                          // labelText gives the field a real accessible
                          // name; the hint teaches the shortcuts.
                          labelText: 'Message',
                          hintText: 'Ask a question, or describe what to do '
                              '(Enter sends - Shift+Enter = new line)',
                          // The capsule IS the field's surface: the fill and
                          // outline are removed so the input melts into it.
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                  ),
                  // Everything else the app can do, labelled, in one sheet.
                  IconButton(
                    tooltip: 'Tools: run, capture, and integrations',
                    icon: const Icon(Icons.tune),
                    onPressed: _busy ? null : _openTools,
                  ),
                  const SizedBox(width: 2),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: scheme.primary,
                      boxShadow: [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.30),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: IconButton.filled(
                      tooltip: _busy ? 'Stop generating' : 'Send',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        foregroundColor: scheme.onPrimary,
                        elevation: 0,
                      ),
                      icon: _busy
                          ? const Icon(Icons.stop)
                          : const Icon(Icons.send),
                      onPressed: _busy ? _cancelGeneration : _send,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "The assistant is working": three dots that breathe, next to the same
/// avatar an answer will use, so the wait is visibly the assistant's turn.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.s18),
            child: CircleAvatar(
              radius: 14,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.smart_toy_outlined,
                size: 15,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.s8),
          Padding(
            padding: const EdgeInsets.only(top: AppTheme.s16),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.s12,
                vertical: AppTheme.s10,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppTheme.rLg),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.6,
                  ),
                ),
              ),
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: AppTheme.s4),
                      Opacity(
                        // Each dot peaks a third of a cycle later than the
                        // last: the pulse reads as motion, not as a blink.
                        opacity: 0.3 +
                            0.7 *
                                (1 -
                                        (((_controller.value + i / 3) % 1) -
                                                0.5)
                                            .abs() /
                                            0.5)
                                    .clamp(0, 1),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.onSurfaceVariant,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The pill that appears when the transcript is scrolled away from the
/// newest message. It says how much is waiting, because "jump to latest"
/// does not tell you whether it is worth tapping.
class _JumpToLatest extends StatelessWidget {
  final int unseen;
  final VoidCallback onTap;

  const _JumpToLatest({required this.unseen, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 2,
      color: theme.colorScheme.inverseSurface,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.s14,
            vertical: AppTheme.s8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (unseen > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.s6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.inversePrimary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$unseen',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onInverseSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: AppTheme.s6),
              ],
              Text(
                unseen > 0 ? 'new' : 'Latest',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onInverseSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: AppTheme.s4),
              Icon(
                Icons.arrow_downward,
                size: 14,
                color: theme.colorScheme.onInverseSurface,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The dialog behind "Remember as a rule": the text is editable before it is
/// saved, because an answer is prose and a rule has to be an instruction the
/// planner can actually follow.
class _RuleDialog extends StatefulWidget {
  final String initial;

  const _RuleDialog({required this.initial});

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: _distil(widget.initial),
  );

  /// Keep the first sentence or two: a rule is read by the planner on every
  /// turn, so it has to be short enough to be worth its tokens.
  static String _distil(String raw) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= 240) return text;
    final cut = text.substring(0, 240);
    final stop = cut.lastIndexOf('. ');
    return stop > 40 ? cut.substring(0, stop + 1) : '$cut...';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.bookmark_add_outlined),
      title: const Text('Remember this as a rule'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Rules are read before every plan this app makes, so the next '
              'build already follows it. Edit it into one instruction.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.s12),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'The rule',
                hintText:
                    'Always use /30 between routers and document the link',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save rule'),
        ),
      ],
    );
  }
}
