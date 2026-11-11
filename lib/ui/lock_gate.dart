import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/app_lock_service.dart';
import '../../services/background_service.dart';
import 'theme.dart';

/// Gate shown ABOVE the whole home surface when the app lock is enabled
/// (v1.18.0): locks on app start and every resume from the background.
/// Biometric first (when available), PIN as the always-available fallback.
/// While unlocked the gate is invisible — zero behavior change for users
/// who never enable the feature, and CI/emulator runs stay unaffected.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate>
    with WidgetsBindingObserver {
  bool _locked = false;
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _bootstrapped) return;
      _bootstrapped = true;
      final bool enabled = ref.read(settingsProvider).appLockEnabled;
      final bool hasPin = ref.read(appLockServiceProvider).hasPin;
      if (enabled && hasPin) {
        setState(() => _locked = true);
      }
      ref.read(appInForegroundProvider.notifier).state = true;
      _openPendingSession();
      _checkDueJobs();
    });
  }

  /// Deep link from a "task finished" notification (v1.18.0): the tap
  /// carried the session id; open that conversation beneath the lock
  /// surface so it is ready when the user unlocks.

  /// CronJobs catch-up (v1.51.0): on start and on every resume, fire
  /// any jobs that came due while the app was closed. Best-effort and
  /// fully guarded — a storage hiccup must never break app start.
  void _checkDueJobs() {
    try {
      unawaited(ref.read(scheduledJobRunnerProvider).checkAll());
    } catch (_) {
      // Runner unavailable (some tests): jobs simply do not fire.
    }
  }

  Future<void> _openPendingSession() async {
    try {
      final String? pending = await ref
          .read(backgroundRunServiceProvider)
          .drainPendingSession();
      if (pending == null || !mounted) return;
      final List<ChatSummary> summaries = await ref
          .read(chatStoreProvider)
          .listSummaries();
      for (final ChatSummary summary in summaries) {
        if (summary.id == pending) {
          await ref.read(chatControllerProvider.notifier).openChat(summary);
          return;
        }
      }
    } catch (_) {
      // A broken deep link must never block app startup.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool inForeground = state == AppLifecycleState.resumed;
    ref.read(appInForegroundProvider.notifier).state = inForeground;
    if (state == AppLifecycleState.resumed && _bootstrapped) {
      final bool enabled = ref.read(settingsProvider).appLockEnabled;
      if (enabled && ref.read(appLockServiceProvider).hasPin) {
        setState(() => _locked = true);
      }
      // v1.42.0: a tapped per-chat (or done) notification lands here when
      // the app was alive in the background — MainActivity.onNewIntent
      // parked the session id; drain it now so the tap opens THAT chat.
      // (At cold start the same drain runs from initState.)
      _openPendingSession();
      _checkDueJobs();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return widget.child;
    return LockScreen(
      onUnlocked: () {
        if (mounted) setState(() => _locked = false);
      },
    );
  }
}

/// Full-screen unlock surface: biometric prompt (auto-attempted once),
/// PIN entry as the universal fallback.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key, required this.onUnlocked});

  final VoidCallback onUnlocked;

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final TextEditingController _pin = TextEditingController();
  bool _busy = false;
  bool _wrong = false;
  bool _biometricTried = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
  }

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _tryBiometric({bool force = false}) async {
    if (_busy || (!force && _biometricTried)) return;
    _biometricTried = true;
    final AppStrings strings = stringsOf(context);
    final AppLockService lock = ref.read(appLockServiceProvider);
    final bool available = await lock.biometricAvailable();
    if (!available || !mounted) return;
    setState(() => _busy = true);
    final bool ok = await lock.authenticateBiometric(
      strings.appLockBiometricReason,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) widget.onUnlocked();
  }

  Future<void> _unlockWithPin() async {
    if (_busy) return;
    final AppLockService lock = ref.read(appLockServiceProvider);
    setState(() => _busy = true);
    final bool ok = await lock.verifyPin(_pin.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _wrong = !ok;
      if (ok) _pin.clear();
    });
    if (ok) widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Icon(Icons.lock_rounded, size: 56, color: kAccentColor),
                  const SizedBox(height: 12),
                  Text(
                    strings.appLockTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const Key('lock-pin-field'),
                    controller: _pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    autofocus: true,
                    enabled: !_busy,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 22, letterSpacing: 8),
                    decoration: InputDecoration(
                      hintText: strings.appLockPinHint,
                      counterText: '',
                      errorText: _wrong ? strings.appLockWrongPin : null,
                    ),
                    onSubmitted: (_) => _unlockWithPin(),
                    onChanged: (_) {
                      if (_wrong) setState(() => _wrong = false);
                    },
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('lock-unlock'),
                    onPressed: _busy ? null : _unlockWithPin,
                    child: Text(strings.appLockUnlock),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const Key('lock-biometric'),
                    icon: const Icon(Icons.fingerprint_rounded, size: 20),
                    label: Text(strings.appLockUseBiometric),
                    onPressed: _busy ? null : () => _tryBiometric(force: true),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
