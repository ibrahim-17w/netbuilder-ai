import 'dart:async';

import 'package:flutter/material.dart';

import '../services/startup_service.dart';
import '../theme/app_theme.dart';

/// A quiet readiness strip above the shell.
///
/// Fast startup should stay invisible: the strip only appears when loading is
/// still going after 600ms, or when one subsystem fell back to safe defaults.
/// A failed memory store keeps the strip visible, with a Details action that
/// explains what is not being saved.
class StartupBanner extends StatefulWidget {
  final StartupCoordinator startup;
  final VoidCallback? onDetails;

  const StartupBanner({super.key, required this.startup, this.onDetails});

  @override
  State<StartupBanner> createState() => _StartupBannerState();
}

class _StartupBannerState extends State<StartupBanner> {
  Timer? _slowTimer;
  bool _showSlow = false;

  @override
  void initState() {
    super.initState();
    widget.startup.addListener(_onChanged);
    _onChanged();
  }

  @override
  void didUpdateWidget(StartupBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startup != widget.startup) {
      oldWidget.startup.removeListener(_onChanged);
      widget.startup.addListener(_onChanged);
      _onChanged();
    }
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    widget.startup.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final snapshot = widget.startup.value;
    if (snapshot.isLoading) {
      _slowTimer ??= Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        setState(() => _showSlow = true);
      });
    } else {
      _slowTimer?.cancel();
      _slowTimer = null;
      if (_showSlow && mounted) {
        setState(() => _showSlow = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.startup.value;
    if (snapshot.isReady || (snapshot.isLoading && !_showSlow)) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final failed = snapshot.isDegraded;
    return Material(
      color: failed ? scheme.errorContainer : scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.s12,
          AppTheme.s6,
          AppTheme.s8,
          AppTheme.s6,
        ),
        child: Row(
          children: [
            if (failed)
              Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: scheme.onErrorContainer,
              )
            else
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: AppTheme.s8),
            Expanded(
              child: Text(
                _message(snapshot),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: failed
                      ? scheme.onErrorContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (failed && widget.onDetails != null)
              TextButton(
                onPressed: widget.onDetails,
                style: TextButton.styleFrom(
                  foregroundColor: scheme.onErrorContainer,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Details'),
              ),
          ],
        ),
      ),
    );
  }

  String _message(StartupSnapshot snapshot) {
    if (snapshot.isDegraded) {
      final failed = snapshot.failedLabels.join(', ');
      if (snapshot.isLoading) {
        return 'Reduced startup: $failed could not load. '
            'Waiting for ${snapshot.loadingLabels.join(', ')}.';
      }
      return 'Reduced startup: $failed could not load; safe defaults are active.';
    }
    return 'Starting ${snapshot.loadingLabels.join(', ')}...';
  }
}
