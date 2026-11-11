import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Keeps a running agent task alive when the user leaves the app.
///
/// On Android this drives [NoahForegroundService] (foreground service +
/// partial wake lock + progress notification) through the
/// `zagents/background` method channel. While the service runs, Android
/// cannot freeze or kill the process, so the Dart agent loop and the
/// headless WebView automation keep working off-screen.
///
/// Everything is best-effort: a platform that does not implement the
/// channel (tests, unsupported OEM restriction) is swallowed and reported
/// through [lastOperationSucceeded] instead of ever crashing the app.
abstract class BackgroundRun {
  /// Starts the background hold. [title] is the notification title,
  /// [text] its initial body (e.g. "Processing…").
  Future<void> start({required String title, required String text});

  /// Replaces the notification body with the current agent step.
  Future<void> updateStatus(String text);

  /// Releases the hold and removes the notification.
  Future<void> stop();

  /// v1.42.0: starts (or refreshes) the PER-CHAT running notification for
  /// [sessionId]. Every active chat gets its own notification — title,
  /// live step text, and a tap action that reopens exactly that
  /// conversation — which makes parallel background runs individually
  /// visible and reachable, on top of the aggregate foreground service.
  Future<void> startSession({
    required String sessionId,
    required String title,
    required String text,
  });

  /// v1.42.0: replaces the per-chat notification body with the current
  /// agent step. No-op when the session has no live notification.
  Future<void> updateSessionStatus({
    required String sessionId,
    required String text,
  });

  /// v1.42.0: removes the per-chat notification for [sessionId] (run
  /// finished, stopped, or force-stopped). No-op when absent.
  Future<void> stopSession(String sessionId);

  /// Whether the background hold is considered active right now.
  bool get isActive;

  /// Posts a local "task finished" notification (v1.18.0). Used when an
  /// agent run completes while the app is NOT in the foreground. [title]
  /// and [text] are the notification strings; [sessionId] is attached to
  /// the tap intent so the app can reopen that conversation.
  Future<bool> notifyDone({
    required String title,
    required String text,
    String? sessionId,
  });

  /// Returns the session id carried by the launch/tap intent (set when
  /// the user taps a done-notification), or null. Draining CONSUMES the
  /// pending value.
  Future<String?> drainPendingSession();

  /// Asks Android to exempt the app from battery optimization
  /// (v1.28.0): the single biggest reliability lever for long background
  /// runs on stock Android (Doze) and many OEM ROMs. Returns true when
  /// the system dialog was shown. Best-effort on all platforms.
  Future<bool> requestIgnoreBatteryOptimization();

  /// Whether Android currently reports the app as exempt from battery
  /// optimization. False on platforms without the query (tests).
  Future<bool> isIgnoringBatteryOptimization();
}

class BackgroundRunService implements BackgroundRun {
  static const MethodChannel _channel = MethodChannel('zagents/background');

  bool _active = false;
  bool _lastOperationSucceeded = false;

  /// Number of agent runs currently holding the service. With multi
  /// session the foreground service must stay up until EVERY run finishes,
  /// so start/stop are refcounted.
  int _holds = 0;

  /// v1.42.0: sessions with a live per-chat notification right now.
  final Set<String> _sessions = <String>{};

  /// v1.42.0: POST_NOTIFICATIONS is asked for ONCE per service instance,
  /// right before the first per-chat notification would be posted. On
  /// Android 13+ an ungranted permission silently drops every
  /// notification — which would make the whole background story invisible
  /// to the user. Best-effort: the dialog is system-owned, denial is fine.
  bool _notificationPermissionAsked = false;

  /// Sessions with a live per-chat notification (v1.42.0, test/debug).
  Set<String> get activeSessionIds => Set<String>.of(_sessions);

  @override
  bool get isActive => _active;

  /// False when the platform refused or lacked the channel — surfaced in
  /// tests and useful for debugging, never surfaced as a UI error.
  bool get lastOperationSucceeded => _lastOperationSucceeded;

  @override
  Future<void> start({required String title, required String text}) async {
    _holds++;
    if (_active) return; // Service already running for another session.
    try {
      _lastOperationSucceeded =
          await _channel.invokeMethod<bool>('start', <String, dynamic>{
            'title': title,
            'text': text,
          }) ??
          false;
      _active = _lastOperationSucceeded;
    } catch (_) {
      // MissingPluginException (tests) or platform failure: the agent run
      // continues in the foreground as before — never crash.
      _active = false;
      _lastOperationSucceeded = false;
    }
  }

  @override
  Future<void> updateStatus(String text) async {
    if (!_active) return;
    try {
      await _channel.invokeMethod<bool>('update', <String, dynamic>{
        'text': text,
      });
    } catch (_) {
      // A failed progress update must never abort the agent loop.
    }
  }

  @override
  Future<void> stop() async {
    if (_holds > 0) _holds--;
    if (_holds > 0 || !_active) return;
    _active = false;
    _sessions.clear();
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {
      // Even if the channel call fails, the Dart side considers the hold
      // released; the native side also has safety valves (wake lock
      // timeout, service stop on task completion).
    }
  }

  @override
  Future<void> startSession({
    required String sessionId,
    required String title,
    required String text,
  }) async {
    _sessions.add(sessionId);
    if (!_notificationPermissionAsked) {
      _notificationPermissionAsked = true;
      try {
        await _channel.invokeMethod<bool>('requestNotificationPermission');
      } catch (_) {
        // Missing handler (tests) or OEM quirk: posting simply stays
        // best-effort, as it always was.
      }
    }
    try {
      await _channel.invokeMethod<bool>('startSession', <String, dynamic>{
        'sessionId': sessionId,
        'title': title,
        'text': text,
      });
      _lastOperationSucceeded = true;
    } catch (_) {
      // The run continues regardless; the aggregate service notification
      // (started via [start]) still shows overall progress.
    }
  }

  @override
  Future<void> updateSessionStatus({
    required String sessionId,
    required String text,
  }) async {
    if (!_sessions.contains(sessionId)) return;
    try {
      await _channel.invokeMethod<bool>('updateSession', <String, dynamic>{
        'sessionId': sessionId,
        'text': text,
      });
    } catch (_) {
      // A failed per-chat progress update must never abort the run.
    }
  }

  @override
  Future<void> stopSession(String sessionId) async {
    if (!_sessions.remove(sessionId)) return;
    try {
      await _channel.invokeMethod<bool>('stopSession', <String, dynamic>{
        'sessionId': sessionId,
      });
    } catch (_) {
      // The notification is cancelled natively when the service stops
      // anyway; a failed channel call must not disturb the release.
    }
  }

  @override
  Future<bool> notifyDone({
    required String title,
    required String text,
    String? sessionId,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('notifyDone', <String, dynamic>{
            'title': title,
            'text': text,
            'sessionId': sessionId,
          }) ??
          false;
    } catch (_) {
      // Notifications are best-effort: a missing platform handler (tests)
      // or an OEM restriction must never surface as an app error.
      return false;
    }
  }

  @override
  Future<String?> drainPendingSession() async {
    try {
      return await _channel.invokeMethod<String>('getPendingSession');
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> requestIgnoreBatteryOptimization() async {
    try {
      return await _channel.invokeMethod<bool>(
            'requestIgnoreBatteryOptimization',
          ) ??
          false;
    } catch (_) {
      // Missing platform handler (tests) or an OEM restriction: never
      // surface as an app error.
      return false;
    }
  }

  @override
  Future<bool> isIgnoringBatteryOptimization() async {
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
}

/// Overridable in tests with a recording test double.
final backgroundRunServiceProvider = Provider<BackgroundRun>(
  (ref) => BackgroundRunService(),
);
