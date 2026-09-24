import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// What changed in each release. Newest first. Shown in the changelog card
/// and reusable as the tour's "what's new" page. One entry per version -
/// keep it to the things a user would actually notice.
const List<({String version, String date, List<String> changes})>
    kChangelogEntries = [
  (
    version: '2.1',
    date: 'September 2026',
    changes: [
      'Verify a finished build with real pings and see pass/fail evidence',
      'Dry-run a plan first: what gets built, before anything is typed',
      'Open and audit any saved .pkt - even grade it against a target plan',
      'Topology preview: see the network drawn before you build it',
      'New coverage: ASA policy + NAT, IPv6 dual-stack, wireless SSIDs, '
          'voice (CME), RADIUS EAP',
      'Build history dashboard and secrets stored in the OS keychain',
    ],
  ),
];

/// The first-run tour: a short, dismissible walkthrough of what the app can
/// do, shown once.  Every panel ends in an action, not just text.
class FirstRunTour extends StatelessWidget {
  final SettingsService settings;
  final VoidCallback? onDone;

  /// Called only when the user reaches the end. Skipping is an exit, not a
  /// commitment, so it must not trigger whatever this starts.
  final VoidCallback? onFinish;

  const FirstRunTour({
    super.key,
    required this.settings,
    this.onDone,
    this.onFinish,
  });

  Future<void> show(BuildContext context) async {
    if (settings.tourDone) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => this,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <({String title, String body, IconData icon})>[
      (
        title: 'Describe it. It builds it.',
        body:
            'Type a network in plain English - "2 routers, a switch, 3 PCs, '
            'DHCP and AAA on a server, firewalls, IPv6" - and the app plans '
            'it, validates it, and builds it in Packet Tracer.',
        icon: Icons.chat_bubble_outline,
      ),
      (
        title: 'Preview before you commit',
        body:
            'Dry-run the plan to see exactly what would be placed, cabled, '
            'typed and configured - with warnings for anything that looks '
            'wrong. The topology preview draws it first.',
        icon: Icons.slow_motion_video,
      ),
      (
        title: 'Proof it works',
        body:
            'After a build, Verify runs real pings across the network and '
            'shows pass/fail evidence per test. Open any saved .pkt to '
            'audit, diff or grade it.',
        icon: Icons.verified_outlined,
      ),
      (
        title: 'Everything is a button',
        body:
            'Every feature in the app - planning, tools, audits, corrections '
            '- is in the Action Hub, searchable from the chat box. Nothing '
            'is hidden behind a menu you have to know about.',
        icon: Icons.grid_view_outlined,
      ),
    ];

    return Dialog(
      child: DefaultTabController(
        length: pages.length,
        child: SizedBox(
          width: 420,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TabPageSelector(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  selectedColor: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 12),
                // Fixed height, scrollable pages: long copy must never
                // overflow the dialog on a small window.
                SizedBox(
                  height: 200,
                  child: TabBarView(
                    children: [
                      for (final p in pages)
                        SingleChildScrollView(
                          child: Column(
                            children: [
                              Icon(p.icon, size: 44,
                                  color: Theme.of(context).colorScheme.primary),
                              const SizedBox(height: 14),
                              Text(p.title,
                                  style: Theme.of(context).textTheme.titleLarge),
                              const SizedBox(height: 8),
                              Text(
                                p.body,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // A Builder so the button context sits BELOW the
                // DefaultTabController it reads - the widget's own context is
                // above it, which throws.
                Builder(
                  builder: (buttonContext) {
                    final controller = DefaultTabController.of(buttonContext);
                    // AnimatedBuilder so the last page's button can say what
                    // it actually does instead of a permanent 'Next'.
                    return AnimatedBuilder(
                      animation: controller,
                      builder: (context, _) => Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () async {
                              await settings.markTourDone();
                              if (buttonContext.mounted) {
                                Navigator.of(buttonContext).pop();
                              }
                              onDone?.call();
                            },
                            child: const Text('Skip'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () async {
                              if (controller.index < pages.length - 1) {
                                controller.animateTo(controller.index + 1);
                                return;
                              }
                              await settings.markTourDone();
                              if (buttonContext.mounted) {
                                Navigator.of(buttonContext).pop();
                              }
                              onFinish?.call();
                            },
                            child: Text(
                              controller.index < pages.length - 1
                                  ? 'Next'
                                  : 'Show me around',
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact "what's new" card shown (once per version) at the top of the
/// Action Hub so existing users see what changed without a full tour.
class ChangelogCard extends StatelessWidget {
  final SettingsService settings;

  const ChangelogCard({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    // Rebuild on dismiss: the card must vanish the moment it is dismissed,
    // not the next time the hub is opened.
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => _card(context),
    );
  }

  Widget _card(BuildContext context) {
    if (kChangelogEntries.isEmpty) return const SizedBox.shrink();
    final latest = kChangelogEntries.first;
    if (settings.seenChangelog == latest.version) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome, size: 18,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'New in ${latest.version} (${latest.date})',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Dismiss',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () =>
                      settings.markChangelogSeen(latest.version),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final change in latest.changes)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('  •  ', style: theme.textTheme.bodySmall),
                    Expanded(
                      child: Text(change, style: theme.textTheme.bodySmall),
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
