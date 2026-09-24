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
import 'services/settings_service.dart';
import 'theme/app_theme.dart';
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
    go: _go,
    push: _push,
    openChat: ({required project, prefill = ''}) =>
        _openChat(project: project, prefill: prefill),
    openDrawer: () => _scaffoldKey.currentState?.openDrawer(),
  );

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

  Future<void> _stopFromEscape() async {
    // This binding works while the app is focused.  The sidecar also owns
    // global listeners, so the same keys work while Packet Tracer is in
    // front of Flutter: Esc = emergency stop, F9 = pause/resume.
    try {
      await AutopilotService().stop();
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(content: Text('Emergency stop requested')),
      );
    } catch (_) {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Emergency stop could not reach the sidecar.'),
        ),
      );
    }
  }

  Future<void> _togglePauseFromKey() async {
    // F9 in-app: identical to the sidecar's global F9 and the Pause button.
    try {
      final res = await AutopilotService().pauseToggle();
      if (!mounted) return;
      final state = (res['state'] ?? '').toString();
      _messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(state == 'paused'
              ? 'Autopilot paused - F9 or the Pause button resumes'
              : 'Autopilot resumed'),
        ),
      );
    } catch (_) {
      _messengerKey.currentState?.showSnackBar(
        const SnackBar(
          content: Text('Pause could not reach the sidecar.'),
        ),
      );
    }
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
          const SingleActivator(LogicalKeyboardKey.escape): _stopFromEscape,
          const SingleActivator(LogicalKeyboardKey.f9): _togglePauseFromKey,
          // The hub is the app's index: every feature, one keystroke away
          // from whatever screen the user is on.
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
            appBar: AppBar(
              title: const Text('NetBuilder AI - Network Engineer'),
              actions: [
                IconButton(
                  tooltip: 'Network toolkit',
                  icon: const Icon(Icons.calculate_outlined),
                  onPressed: () => _push(
                    NetworkToolkitScreen(intent: _openIntent),
                  ),
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
                // A rail on a desktop, the hub button and the drawer on a
                // phone. The rail is how "every screen is reachable" is
                // visible rather than merely true.
                final wide = constraints.maxWidth >= 1000;
                if (!wide) return _screen();
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _AppRail(
                      current: _destination,
                      onSelect: _go,
                      onHub: _showHub,
                      onToolkit: () => _push(
                        NetworkToolkitScreen(intent: _openIntent),
                      ),
                      hasPlan: _openIntent != null,
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _screen()),
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

/// The desktop rail: every destination, plus the two ways of reaching
/// everything else.
class _AppRail extends StatelessWidget {
  final AppDestination current;
  final void Function(AppDestination) onSelect;
  final VoidCallback onHub;
  final VoidCallback onToolkit;
  final bool hasPlan;

  const _AppRail({
    required this.current,
    required this.onSelect,
    required this.onHub,
    required this.onToolkit,
    required this.hasPlan,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final destinations = AppDestination.alwaysAvailable;
    // A fixed-width column around a scrollable rail: the rail's own width is
    // bounded here, which is what stops its extended labels from being laid
    // out against an infinite width.
    return SizedBox(
      width: 236,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s12,
              AppTheme.s12,
              AppTheme.s12,
              AppTheme.s8,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'WORKSPACE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: AppTheme.s8),
                FilledButton.tonalIcon(
                  onPressed: onHub,
                  icon: const Icon(Icons.grid_view_rounded, size: 18),
                  label: const Text('All features'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                vertical: AppTheme.s8,
                horizontal: AppTheme.s8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final destination in destinations)
                    _RailTile(
                      destination: destination,
                      selected: destination == current,
                      onTap: () => onSelect(destination),
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.s8,
              AppTheme.s8,
              AppTheme.s8,
              AppTheme.s12,
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Network toolkit',
                  onPressed: onToolkit,
                  icon: const Icon(Icons.calculate_outlined),
                ),
                const SizedBox(width: AppTheme.s4),
                Expanded(
                  child: TextButton.icon(
                    onPressed: hasPlan
                        ? () => onSelect(AppDestination.execution)
                        : null,
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: const Text('Run build'),
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

/// One destination in the rail. Written out rather than using
/// [NavigationRail] because the rail here is inside a scrollable column and
/// a tile is a smaller, more predictable thing than a rail that assumes it
/// owns a bounded height.
class _RailTile extends StatelessWidget {
  final AppDestination destination;
  final bool selected;
  final VoidCallback onTap;

  const _RailTile({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.s2),
      child: Material(
        color: selected
            ? scheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppTheme.rMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppTheme.rMd),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.s12,
              vertical: AppTheme.s10,
            ),
            child: Row(
              children: [
                Icon(
                  destination.icon,
                  size: 18,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppTheme.s12),
                Expanded(
                  child: Text(
                    destination.title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: selected ? scheme.primary : scheme.onSurface,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
