import 'package:flutter/material.dart';

/// Every screen the shell can show, named.
///
/// Named destinations make the app's navigation explicit. New designs start
/// in chat; the workspace is available when there is a plan to edit or verify.
enum AppDestination {
  chat,
  history,
  analyze,
  execution,
  memory,
  files,
  importPkts,
  labs,
  settings;

  String get title => switch (this) {
    AppDestination.chat => 'Chat',
    AppDestination.history => 'Saved networks',
    AppDestination.execution => 'Plan workspace',
    AppDestination.analyze => 'Analyze and fix',
    AppDestination.memory => 'Memory and learning',
    AppDestination.files => 'Packet Tracer files',
    AppDestination.importPkts => 'Open & inspect .pkt',
    AppDestination.labs => 'Practice labs',
    AppDestination.settings => 'Settings',
  };

  String get description => switch (this) {
    AppDestination.chat =>
      'Talk to the assistant, attach evidence, approve changes',
    AppDestination.history =>
      'Every network this app has built, with its outcome',
    AppDestination.execution => 'Edit, rebuild, and verify the open network',
    AppDestination.analyze => 'Audit a live lab and apply approved fixes',
    AppDestination.memory =>
      'Corrections, learned rules and the failure journal',
    AppDestination.files => 'Open, verify, back up and report on .pkt saves',
    AppDestination.importPkts =>
      'Audit, diff and grade any saved .pkt - no Packet Tracer',
    AppDestination.labs =>
      'Practice routing, services, VLANs, and security with scored goals',
    AppDestination.settings =>
      'Provider, build engine, privacy, automation and appearance',
  };

  IconData get icon => switch (this) {
    AppDestination.chat => Icons.forum_outlined,
    AppDestination.history => Icons.history,
    AppDestination.analyze => Icons.troubleshoot,
    AppDestination.execution => Icons.account_tree_outlined,
    AppDestination.memory => Icons.psychology_outlined,
    AppDestination.files => Icons.folder_open_outlined,
    AppDestination.importPkts => Icons.manage_search,
    AppDestination.labs => Icons.school_outlined,
    AppDestination.settings => Icons.tune,
  };

  /// Screens available from the main navigation. Settings has one app-bar
  /// entry; the plan workspace appears only when a plan is open.
  static const alwaysAvailable = [
    AppDestination.chat,
    AppDestination.analyze,
    AppDestination.files,
    AppDestination.importPkts,
    AppDestination.labs,
    AppDestination.history,
    AppDestination.memory,
  ];
}
