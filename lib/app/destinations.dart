import 'package:flutter/material.dart';

/// Every screen the shell can show, named.
///
/// The shell used to switch on bare integers (`case 3:`), and only three of
/// the eight values were ever set: the history, the build form, the memory,
/// the settings screen and the .pkt file screen existed in the code but had
/// no way in. Naming them makes "is this reachable?" a question the code can
/// answer, and the capability registry answers it for every one of them.
enum AppDestination {
  chat,
  history,
  newBuild,
  analyze,
  execution,
  memory,
  files,
  importPkts,
  settings;

  String get title => switch (this) {
    AppDestination.chat => 'Chat',
    AppDestination.history => 'Saved networks',
    AppDestination.newBuild => 'New build',
    AppDestination.analyze => 'Analyze and fix',
    AppDestination.execution => 'Build workspace',
    AppDestination.memory => 'Memory and learning',
    AppDestination.files => 'Packet Tracer files',
    AppDestination.importPkts => 'Open & inspect .pkt',
    AppDestination.settings => 'Settings',
  };

  String get description => switch (this) {
    AppDestination.chat => 'Talk to the assistant, attach evidence, approve changes',
    AppDestination.history => 'Every network this app has built, with its outcome',
    AppDestination.newBuild => 'Describe a network in a sentence and plan it',
    AppDestination.analyze => 'Audit a live lab and apply approved fixes',
    AppDestination.execution => 'Run the plan and prove it on screen',
    AppDestination.memory => 'Corrections, learned rules and the failure journal',
    AppDestination.files => 'Open, verify, back up and report on .pkt saves',
    AppDestination.importPkts =>
        'Audit, diff and grade any saved .pkt - no Packet Tracer',
    AppDestination.settings => 'Keys, provider, engine address, folders',
  };

  IconData get icon => switch (this) {
    AppDestination.chat => Icons.forum_outlined,
    AppDestination.history => Icons.history,
    AppDestination.newBuild => Icons.add_circle_outline,
    AppDestination.analyze => Icons.troubleshoot,
    AppDestination.execution => Icons.play_circle_outline,
    AppDestination.memory => Icons.psychology_outlined,
    AppDestination.files => Icons.folder_open_outlined,
    AppDestination.importPkts => Icons.manage_search,
    AppDestination.settings => Icons.tune,
  };

  /// The destinations a person can go to at any time. The execution
  /// workspace needs a build to open, so it is listed separately.
  static const alwaysAvailable = [
    AppDestination.chat,
    AppDestination.newBuild,
    AppDestination.analyze,
    AppDestination.files,
    AppDestination.importPkts,
    AppDestination.history,
    AppDestination.memory,
    AppDestination.settings,
  ];
}
