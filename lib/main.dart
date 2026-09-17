import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'models/build_record.dart';
import 'models/network_intent.dart';
import 'screens/builder_detail_screen.dart';
import 'screens/analyze_screen.dart';
import 'screens/pkt_files_screen.dart';
import 'services/autopilot_service.dart';
import 'screens/home_screen.dart';
import 'screens/memory_screen.dart';
import 'screens/new_build_screen.dart';
import 'screens/settings_screen.dart';
import 'services/build_artifact_service.dart';
import 'services/memory_service.dart';
import 'services/settings_service.dart';
import 'services/sidecar_supervisor.dart';

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
  // The packaged Windows app owns its local sidecar lifecycle. In
  // development this is best-effort and the existing manual launcher still
  // works when Python/RPA dependencies are not installed.
  unawaited(SidecarSupervisor.ensureRunning());
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider.value(value: memory),
      ],
      child: const NetBuilderApp(),
    ),
  );
}

class NetBuilderApp extends StatefulWidget {
  final bool monitorDetailSidecar;

  const NetBuilderApp({super.key, this.monitorDetailSidecar = true});
  @override
  State<NetBuilderApp> createState() => _NetBuilderAppState();
}

class _NetBuilderAppState extends State<NetBuilderApp> {
  int _tab = 0;
  BuildRecord? _openRecord;
  NetworkIntent? _openIntent;
  String _openConfig = '';
  String _activeProject = 'default';
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  void _onBuilt(BuildRecord r, NetworkIntent i, String cfg) {
    setState(() {
      _openRecord = r;
      _openIntent = i;
      _openConfig = cfg;
      _activeProject = r.projectName;
      _tab = 6; // detail tab
    });
  }

  void _openSavedBuild(BuildRecord record) {
    try {
      final restored = BuildArtifactService.restore(record);
      setState(() {
        _openRecord = restored.record;
        _openIntent = restored.intent;
        _openConfig = restored.configText;
        _activeProject = restored.intent.projectName;
        _tab = 6;
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

  Future<void> _setPaused(bool wantPause) async {
    try {
      final svc = AutopilotService();
      final res = wantPause ? await svc.pause() : await svc.resume();
      if (!mounted) return;
      final msg = (res['message'] ?? '').toString();
      _messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(msg.isEmpty
              ? (wantPause ? 'Pause requested' : 'Resume requested')
              : msg),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final titles = [
      'Projects',
      'Build',
      'Analyze',
      'Memory',
      'Settings',
      'PKT Files',
      'Detail',
    ];
    Widget body;
    switch (_tab) {
      case 0:
        body = HomeScreen(onOpen: _openSavedBuild);
        break;
      case 1:
        body = NewBuildScreen(onBuilt: _onBuilt);
        break;
      case 2:
        body = AnalyzeScreen(
          initialProject: _activeProject,
          intent: _openIntent,
        );
        break;
      case 3:
        body = const MemoryScreen();
        break;
      case 4:
        body = const SettingsScreen();
        break;
      case 5:
        body = PktFilesScreen(
          initialProject: _activeProject,
          intent: _openIntent,
          onAnalyze: (project) => setState(() {
            _activeProject = project.trim().isEmpty
                ? 'default'
                : project.trim();
            _tab = 2;
          }),
        );
        break;
      default:
        if (_openRecord != null && _openIntent != null) {
          body = BuilderDetailScreen(
            record: _openRecord!,
            intent: _openIntent!,
            configText: _openConfig,
            monitorSidecar: widget.monitorDetailSidecar,
          );
        } else {
          body = const Center(child: Text('Build something first.'));
        }
    }
    return MaterialApp(
      title: 'NetBuilder AI',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.indigo)),
      scaffoldMessengerKey: _messengerKey,
      home: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): _stopFromEscape,
          const SingleActivator(LogicalKeyboardKey.f9): _togglePauseFromKey,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: AppBar(title: Text('NetBuilder AI - ${titles[_tab]}')),
            body: body,
            // Floating run controls: visible on every tab during runs.
            // STOP cancels the job; PAUSE holds it at a safe boundary with
            // all progress kept (same as the global F9 key).
            floatingActionButton:
                (_tab == 2 || _tab == 5 || (_tab == 6 && _openRecord != null))
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FloatingActionButton.extended(
                        heroTag: 'pauseFab',
                        backgroundColor: Colors.amber.shade700,
                        icon: const Icon(Icons.pause, color: Colors.white),
                        label: const Text(
                          'PAUSE',
                          style: TextStyle(color: Colors.white),
                        ),
                        tooltip:
                            'Pause autopilot at a safe boundary (or press F9)',
                        onPressed: () => _setPaused(true),
                      ),
                      const SizedBox(height: 10),
                      FloatingActionButton.extended(
                        heroTag: 'stopFab',
                        backgroundColor: Colors.red,
                        icon: const Icon(Icons.stop, color: Colors.white),
                        label: const Text(
                          'STOP',
                          style: TextStyle(color: Colors.white),
                        ),
                        tooltip: 'Emergency stop autopilot (or press Esc)',
                        onPressed: _stopFromEscape,
                      ),
                    ],
                  )
                : null,
            bottomNavigationBar: BottomNavigationBar(
              currentIndex: _tab > 5 ? 1 : _tab,
              type: BottomNavigationBarType.fixed,
              onTap: (i) => setState(() => _tab = i),
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.hub),
                  label: 'Projects',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.add_box),
                  label: 'Build',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.fact_check),
                  label: 'Analyze',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.memory),
                  label: 'Memory',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.settings),
                  label: 'Settings',
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.description),
                  label: 'PKT Files',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
