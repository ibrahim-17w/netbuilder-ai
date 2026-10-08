import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app/destinations.dart';
import 'models/build_record.dart';
import 'models/network_intent.dart';
import 'screens/build_workspace_screen.dart';
import 'screens/analyze_screen.dart';
import 'screens/chat_screen.dart';
import 'widgets/action_hub.dart';
import 'widgets/settings_drawer.dart';
import 'screens/import_screen.dart';
import 'screens/pkt_files_screen.dart';
import 'services/capability_registry.dart';
import 'services/autopilot_service.dart';
import 'screens/home_screen.dart';
import 'screens/memory_screen.dart';
import 'screens/new_build_screen.dart';
import 'screens/network_toolkit_screen.dart';
import 'screens/settings_screen.dart';
import 'services/build_artifact_service.dart';
import 'services/memory_service.dart';
import 'services/engine_status.dart';
import 'services/layout_engine.dart';
import 'services/layout_intent.dart';
import 'services/settings_service.dart';
import 'theme/app_theme.dart';
import 'widgets/app_sidebar.dart';
import 'widgets/whats_new.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsService();
  final memory = MemoryService();
  try {
    await settings.load();
  } catch (_) {}
  try {
    await memory.init();
  } catch (_) {}
  // ONE engine client for the whole app, reading the address the user set.
  // The address is resolved per request, so changing it in Settings takes
  // effect everywhere at once - and no screen can quietly talk to loopback
  // instead of the machine the user pointed the app at.
  final autopilot = AutopilotService(baseProvider: () => settings.engineBase);
  // The app owns the engine's lifecycle: it starts it, follows the address
  // the user sets, and reports what happened. Nothing about this blocks the
  // first frame - a missing engine is a state the UI shows, not an error
  // thrown at launch.
  final engine = EngineStatus.instance;
  engine.setBase(settings.engineBase);
  settings.addListener(() => engine.setBase(settings.engineBase));
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: memory),
        Provider<AutopilotService>.value(value: autopilot),
      ],
      child: const NetBuilderApp(),
    ),
  );
  unawaited(engine.ensure());
}

class NetBuilderApp extends StatefulWidget {
  final bool monitorDetailSidecar;

  const NetBuilderApp({super.key, this.monitorDetailSidecar = true});
  @override
  State<NetBuilderApp> createState() => _NetBuilderAppState();
}

class _NetBuilderAppState extends State<NetBuilderApp> {
  // CHAT-FIRST: the app opens straight into the conversation, the way an
  // AI app does. Every other screen is one tap away - the rail on a desktop,
  // the hub button, or Ctrl+K - and deep links still work, because this is
  // just the initial destination.
  AppDestination _destination = AppDestination.chat;
  BuildRecord? _openRecord;
  NetworkIntent? _openIntent;
  String _openConfig = '';
  String _activeProject = 'default';
  /// Text the chat composer should open with, when a hub action sends the
  /// user there to ask something specific.
  String _chatDraft = '';
  /// Bumped when a new conversation is started, so the chat screen is rebuilt
  /// with an empty transcript instead of reusing the old one's state.
  int _chatEpoch = 0;
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  // Dialogs, sheets and pushed routes need a context *below* MaterialApp,
  // where the Localizations and the Navigator live. This state's own context
  // is above it, which is exactly why opening the hub from here used to throw
  // "No MaterialLocalizations found".
  final _navKey = GlobalKey<NavigatorState>();

  BuildContext? get _shellContext => _navKey.currentContext;

  /// Providers are nullable on purpose: this shell must render even when it is
  /// mounted without them (a widget test booting the app), and a missing
  /// provider should cost a setting, never the screen.
  SettingsService? get _settings {
    try {
      return context.read<SettingsService>();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowTour());
  }

  /// The first-run tour, offered once. It waits for settings to be loaded from
  /// prefs (so a widget test booting the shell without `load()` never gets an
  /// unexpected dialog) and for the shell context the Navigator lives under.
  Future<void> _maybeShowTour() async {
    final settings = _settings;
    if (settings == null || !settings.loaded || settings.tourDone) return;
    // Let the chat paint first: the tour is an introduction, not a splash.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    final ctx = _shellContext;
    if (ctx == null || !ctx.mounted) return;
    // Finishing the tour opens the hub: the tour claims everything is a
    // button, so it should end by showing the buttons.
    await FirstRunTour(
      settings: settings,
      onFinish: _showHub,
    ).show(ctx);
  }

  void _go(AppDestination destination) {
    if (!mounted) return;
    setState(() => _destination = destination);
  }

  void _push(Widget screen) {
    _navKey.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  void _openChat({required String project, String prefill = ''}) {
    setState(() {
      final name = project.trim().isEmpty ? 'default' : project.trim();
      final isNew = name != _activeProject;
      _activeProject = name;
      _chatDraft = prefill;
      if (isNew) _chatEpoch++;
      _destination = AppDestination.chat;
    });
  }

  /// The host an action runs against. [host] is the context below MaterialApp,
  /// so a dialog an action opens is a child of this app's theme and
  /// localizations rather than a sibling of the whole tree.
  ActionContext _actionHost(BuildContext host) => ActionContext(
    context: host,
    current: _destination,
    intent: _openIntent,
    record: _openRecord,
    project: _activeProject,
    autopilot: AutopilotService.of(context),
    go: _go,
    push: _push,
    openChat: ({required project, prefill = ''}) =>
        _openChat(project: project, prefill: prefill),
    openDrawer: () => _scaffoldKey.currentState?.openDrawer(),
    applyLayout: _applyLayout,
  );

  /// Remember the drawing the user picked for the open plan, as a note, so the
  /// next build of this plan uses exactly that picture. The note is the same
  /// "layout: <style>" stamp a build already reads back, written through
  /// [LayoutRequest.noteFor] so this path and the chat redraw cannot drift.
  void _applyLayout(String style) {
    final current = _openIntent;
    if (current == null) return;
    final cleaned = [
      for (final n in current.notes)
        if (!n.toLowerCase().startsWith('layout:')) n,
    ];
    // Picking a bare style from the gallery parks nothing unless the style is
    // the grouped one, which needs devices to park. Servers are the group a
    // person means by "grouped" far more often than anything else, and the
    // gallery's grouped tile already draws exactly this.
    final parked = style == 'grouped'
        ? resolveSideNames(current, kinds: LayoutRequest.defaultSideKinds)
        : const <String>[];
    setState(() {
      _openIntent = current.copyWith(notes: [
        ...cleaned,
        LayoutRequest.noteFor(
          style,
          sideKinds: parked.isEmpty
              ? const <String>[]
              : LayoutRequest.defaultSideKinds,
          sideNames: parked,
          sideEdge: 'left',
        ),
      ]);
    });
    _messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          parked.isEmpty
              ? 'Layout set to "$style" - the next build uses it.'
              : 'Layout set to grouped - the next build parks '
                    '${parked.join(', ')} to the left.',
        ),
      ),
    );
  }

  Future<void> _showHub() async {
    final host = _shellContext;
    if (host == null) return;
    await showActionHub(host, _actionHost(host));
  }

  void _onBuilt(BuildRecord r, NetworkIntent i, String cfg) {
    setState(() {
      _openRecord = r;
      _openIntent = i;
      _openConfig = cfg;
      _activeProject = r.projectName;
      _destination = AppDestination.execution;
    });
  }

  Future<void> _openSavedBuild(BuildRecord record) async {
    try {
      // Async restore pulls AAA/VPN secrets from the OS keychain so the
      // reopened build carries the same credentials it was saved with.
      final restored = await BuildArtifactService.restoreAsync(record);
      if (!mounted) return;
      setState(() {
        _openRecord = restored.record;
        _openIntent = restored.intent;
        _openConfig = restored.configText;
        _activeProject = restored.intent.projectName;
        _destination = AppDestination.execution;
      });
    } catch (e) {
      final message = e.toString().replaceFirst('FormatException: ', '');
      _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Could not open saved project: $message')),
      );
    }
  }

  /// The visible screen, with a short cross-fade so switching destinations
  /// reads as moving between places rather than as the window repainting.
  /// The outgoing screen stays mounted for the length of the fade, so a
  /// half-finished list still paints instead of flashing empty.
  Widget _shellBody() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.01),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(_destination), child: _screen()),
    );
  }

  Widget _screen() {
    switch (_destination) {
      case AppDestination.history:
        return HomeScreen(
          onOpen: _openSavedBuild,
          onNewBuild: () => _go(AppDestination.newBuild),
        );
      case AppDestination.newBuild:
        return NewBuildScreen(onBuilt: _onBuilt);
      case AppDestination.analyze:
        return AnalyzeScreen(
          initialProject: _activeProject,
          intent: _openIntent,
        );
      case AppDestination.chat:
        return ChatScreen(
          // Keyed by conversation so switching chats rebuilds the screen with
          // that conversation's transcript instead of reusing the old state.
          key: ValueKey('chat-$_activeProject-$_chatEpoch'),
          initialProject: _activeProject,
          initialDraft: _chatDraft,
          onOpenProject: (project) => setState(() {
            _activeProject = project.trim().isEmpty
                ? 'default'
                : project.trim();
            _destination = AppDestination.analyze;
          }),
        );
      case AppDestination.memory:
        return const MemoryScreen();
      case AppDestination.settings:
        return const SettingsScreen();
      case AppDestination.files:
        return PktFilesScreen(
          initialProject: _activeProject,
          intent: _openIntent,
          onAnalyze: (project) => setState(() {
            _activeProject = project.trim().isEmpty
                ? 'default'
                : project.trim();
            _destination = AppDestination.analyze;
          }),
        );
      case AppDestination.importPkts:
        return ImportScreen(
          planLoader: () async => _openIntent
              ?.toJson(includeSecrets: false),
        );
      case AppDestination.execution:
        if (_openRecord != null && _openIntent != null) {
          return BuildWorkspaceScreen(
            record: _openRecord!,
            intent: _openIntent!,
            configText: _openConfig,
            monitorSidecar: widget.monitorDetailSidecar,
          );
        }
        return AppEmptyState(
          icon: AppDestination.execution.icon,
          title: 'No build is open yet',
          body: 'Plan a network, or open one from your saved networks, and '
              'this is where it runs and gets proven.',
          actions: [
            FilledButton.icon(
              onPressed: () => _go(AppDestination.newBuild),
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Plan a network'),
            ),
            OutlinedButton.icon(
              onPressed: () => _go(AppDestination.history),
              icon: const Icon(Icons.history),
              label: const Text('Saved networks'),
            ),
          ],
        );
    }
  }

  ThemeMode _themeMode(SettingsService? settings) => switch (settings
      ?.themeMode) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  @override
  Widget build(BuildContext context) {
    SettingsService? settings;
    try {
      settings = context.watch<SettingsService>();
    } catch (_) {
      settings = _settings;
    }
    return MaterialApp(
      title: 'NetBuilder AI',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode(settings),
      scaffoldMessengerKey: _messengerKey,
      home: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          // The hub is the app's index: every feature, one keystroke away
          // from whatever screen the user is on. Run control is deliberately
          // NOT bound to a bare key: a global Esc/F9 steals those keys from
          // Packet Tracer and from every text field, and stopping a run
          // belongs to the Stop button the user is looking at.
          const SingleActivator(LogicalKeyboardKey.keyK, control: true):
              _showHub,
          const SingleActivator(LogicalKeyboardKey.keyK, meta: true): _showHub,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            key: _scaffoldKey,
            // The sidebar lists the chats and switches between them, so
            // it needs to be able to change the active project.
            drawer: SettingsDrawer(
              onSwitchChat: (conversation) => _openChat(project: conversation),
              onOpenHub: _showHub,
              onOpenToolkit: () => _push(
                NetworkToolkitScreen(intent: _openIntent),
              ),
            ),
            // ONE header for every screen: the destination's name and what
            // it is for, the engine's live state, and the feature index. The
            // toolkit's calculator used to sit here AND on the rail AND in
            // the drawer - it now has one home (the sidebar), and this bar
            // shows state instead of repeating navigation.
            appBar: AppBar(
              title: _DestinationHeader(destination: _destination),
              actions: [
                const Padding(
                  padding: EdgeInsets.only(right: AppTheme.s8),
                  child: _AiPill(),
                ),
                const Padding(
                  padding: EdgeInsets.only(right: AppTheme.s8),
                  child: _EnginePill(),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: AppTheme.s4),
                  child: IconButton(
                    tooltip: 'All features (Ctrl+K)',
                    icon: const Icon(Icons.grid_view_rounded),
                    onPressed: _showHub,
                  ),
                ),
              ],
            ),
            body: LayoutBuilder(
              builder: (context, constraints) {
                // The sidebar on a desktop, a compact rail on a laptop, the
                // drawer and the hub on a phone. This is how "every screen is
                // reachable" is visible rather than merely true.
                final width = constraints.maxWidth;
                if (width < 1000) return _shellBody();
                final expanded = width >= 1240;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (expanded)
                      AppSidebar(
                        current: _destination,
                        onSelect: _go,
                        onHub: _showHub,
                        onToolkit: () => _push(
                          NetworkToolkitScreen(intent: _openIntent),
                        ),
                        planProject:
                            _openIntent == null ? '' : _activeProject,
                        planSummary: _openIntent == null
                            ? ''
                            : '${_openIntent!.nodes.length} device(s), '
                                  '${_openIntent!.links.length} link(s)',
                        planTarget: _openIntent == null
                            ? ''
                            : _openRecord?.target ?? '',
                        onOpenWorkspace: _openIntent == null
                            ? null
                            : () => _go(AppDestination.execution),
                      )
                    else
                      AppRail(
                        current: _destination,
                        onSelect: _go,
                        onHub: _showHub,
                        onToolkit: () => _push(
                          NetworkToolkitScreen(intent: _openIntent),
                        ),
                        hasPlan: _openIntent != null,
                      ),
                    // The sidebar and the rail carry their own edge; the
                    // content starts with a clean line instead of a second
                    // divider a pixel away from the first.
                    Expanded(child: _shellBody()),
                  ],
                );
              },
            ),
            // Run controls are FLOATING buttons, so they are shown only
            // on tabs with no bottom composer, and the chat composer's send
            // button owns the bottom-right corner there. Chat is the screen
            // the app opens on, so no float is rendered at all: Pause/Stop
            // live in the chat header and in the sidebar.
            floatingActionButton: null,
            bottomNavigationBar: null,
          ),
        ),
      ),
    );
  }
}

/// The destination's name and promise, in the top bar. The bar used to be
/// just the name; the second line is the sentence a person needs the first
/// time they land on a screen, and it costs one line of height.
class _DestinationHeader extends StatelessWidget {
  final AppDestination destination;

  const _DestinationHeader({required this.destination});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // On a narrow window only the name fits; the promise is in the hub
        // and in the screen's own header.
        final showDescription = constraints.maxWidth >= 460;
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(destination.title),
            if (showDescription)
              Text(
                destination.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The AI's state, in the top bar next to the engine's: is an API key
/// active (and for which provider), is private mode on, or is the built-in
/// planner on its own. One glance answers "will the model answer this?"
/// without opening Settings - which is why the per-answer source lines in
/// the chat were retired: the mode is a property of the app, not of each
/// message, and the app bar is where the app's state lives.
class _AiPill extends StatelessWidget {
  const _AiPill();

  @override
  Widget build(BuildContext context) {
    // The shell renders without providers in widget tests; a missing
    // SettingsService costs the pill, never the screen - the same rule the
    // shell's own nullable settings getter follows.
    final SettingsService settings;
    try {
      settings = context.watch<SettingsService>();
    } catch (_) {
      return const SizedBox.shrink();
    }
    final (detail, ok, warn) = switch ((
      settings.privateMode,
      settings.aiKeyPresent,
    )) {
      // Engine-pill brevity: 'AI on / off / private' must hold at a 360px
      // phone width beside the engine pill; the provider lives in the
      // tooltip.
      (true, _) => ('private', false, true),
      (false, true) => ('on', true, false),
      (false, false) => ('off', false, true),
    };
    return Tooltip(
      message: switch ((settings.privateMode, settings.aiKeyPresent)) {
        (true, _) => 'Private mode is on - the model is never called',
        (false, true) =>
          'AI on - API key active (${settings.providerName == 'openai' ? 'OpenAI-compatible' : 'Google Gemini'})'
              '; questions are answered by the model and learned for offline replay',
        _ => 'AI off - no API key set; the built-in planner answers '
            'everything offline',
      },
      child: AppStatusPill(label: 'AI', detail: detail, ok: ok, warn: warn),
    );
  }
}

/// The engine's live state, in the top bar: one dot and one word, so "is
/// Packet Tracer automation available?" is answered without opening
/// anything. It reports only - starting and stopping the engine stays where
/// the run is controlled, so this pill is not a second Start button.
class _EnginePill extends StatelessWidget {
  const _EnginePill();

  @override
  Widget build(BuildContext context) {
    final engine = EngineStatus.instance;
    return AnimatedBuilder(
      animation: engine,
      builder: (context, _) {
        final phase = engine.phase;
        return AppStatusPill(
          label: 'Engine',
          detail: switch (phase) {
            EngineState.up => 'up',
            EngineState.down => 'down',
            EngineState.checking || EngineState.starting => 'checking',
            EngineState.unknown => 'idle',
          },
          ok: phase == EngineState.up,
          warn: phase == EngineState.down,
        );
      },
    );
  }
}
