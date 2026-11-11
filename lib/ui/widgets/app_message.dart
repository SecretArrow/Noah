import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_strings.dart';
import '../theme.dart';

/// v1.49.6 — the app-wide feedback surface, replacing both the SnackBar era
/// and the v1.49.5 bottom overlay toast.
///
/// Why a dialog: users reported that anything floating near the bottom of
/// the screen (SnackBar AND the toast) covers the composer field and the
/// send/attach buttons exactly while they are typing. [showAppMessage]
/// therefore shows a compact MODAL DIALOG anchored to the CENTER of the
/// screen — it can never overlap the composer, the bottom navigation or
/// any action row.
///
/// Behaviour contract (kept deliberately compatible with the old toast so
/// existing call sites and tests keep their cadence):
/// - calling it again while a message is visible REPLACES the visible one
///   (the same `..hideCurrentSnackBar() ..showSnackBar(...)` cadence);
/// - info messages auto-dismiss after [duration] (2.6 s default) — the
///   hold is a [Timer] started by the dialog widget itself, so
///   `pumpAndSettle` in widget tests does NOT burn it (the message is
///   still visible after settling) and tree teardown cancels the timer
///   (no "Timer is still pending" test failures);
/// - error messages (`error: true`) stay until dismissed — an error the
///   user must acknowledge should not vanish on its own;
/// - the OK button (and the barrier tap) dismiss immediately.
void showAppMessage(
  BuildContext context,
  String message, {
  Key? key,
  Duration? duration,
  bool error = false,
}) {
  final String text = message.trim();
  if (text.isEmpty) return;
  final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
  // Drop the currently visible message first — a second feedback must
  // never stack two dialogs.
  final ModalRoute<void>? previous = _currentRoute;
  _currentRoute = null;
  if (previous != null && previous.isCurrent) {
    navigator.removeRoute(previous);
  }
  final CapturedThemes themes = InheritedTheme.capture(
    from: context,
    to: navigator.context,
  );
  // late: the builder closure reads `route`, so the variable must already
  // be DECLARED when the closure is created (it only ever RUNS after the
  // route is pushed below) — the same pattern the toast used for its
  // OverlayEntry.
  late final DialogRoute<void> route;
  route = DialogRoute<void>(
    context: context,
    themes: themes,
    barrierColor: Colors.black38,
    barrierDismissible: true,
    settings: const RouteSettings(name: 'app-message'),
    builder: (BuildContext dialogContext) => _AppMessageCard(
      key: key ?? const ValueKey<String>('app-message-card'),
      message: text,
      error: error,
      duration: duration,
      onExpire: () => _expireRoute(route, navigator),
      onDismissed: () {
        if (identical(_currentRoute, route)) _currentRoute = null;
      },
    ),
  );
  _currentRoute = route;
  navigator.push(route);
}

/// The currently visible message route — the replacement guard uses it to
/// drop exactly THIS route (never a user-opened dialog underneath).
ModalRoute<void>? _currentRoute;

/// Internal: expires the current info message. Library-scope so the card
/// widget receives a stable callback that knows its own route.
void _expireRoute(ModalRoute<void> route, NavigatorState navigator) {
  if (!identical(_currentRoute, route)) return;
  _currentRoute = null;
  if (route.isCurrent) navigator.removeRoute(route);
}

class _AppMessageCard extends StatefulWidget {
  const _AppMessageCard({
    required super.key,
    required this.message,
    required this.error,
    required this.onExpire,
    required this.onDismissed,
    this.duration,
  });

  final String message;
  final bool error;

  /// Fired when the info hold elapses (never scheduled for errors).
  final VoidCallback onExpire;

  /// Fired when the user dismisses via OK (barrier dismisses pop without
  /// any callback — the replacement guard handles that case too).
  final VoidCallback onDismissed;
  final Duration? duration;

  @override
  State<_AppMessageCard> createState() => _AppMessageCardState();
}

class _AppMessageCardState extends State<_AppMessageCard> {
  static const Duration _infoHold = Duration(milliseconds: 2600);

  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    // Errors must be acknowledged — only info messages expire on their
    // own. The timer is canceled in dispose, so widget-tree teardown
    // (including test teardown) never leaves it dangling.
    if (!widget.error) {
      _holdTimer = Timer(widget.duration ?? _infoHold, widget.onExpire);
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  void _dismiss() {
    widget.onDismissed();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color accent = widget.error
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    return AlertDialog(
      backgroundColor: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kDialogRadius),
      ),
      icon: Icon(
        widget.error ? Icons.error_outline : Icons.check_circle_outline,
        color: accent,
      ),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: SingleChildScrollView(
          child: Text(
            widget.message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actionsPadding: const EdgeInsets.only(bottom: 12),
      actions: <Widget>[
        TextButton(
          key: const Key('app-message-ok'),
          onPressed: _dismiss,
          child: Text(stringsOf(context).confirm),
        ),
      ],
    );
  }
}
