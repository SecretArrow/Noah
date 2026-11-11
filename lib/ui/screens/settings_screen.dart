import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../services/app_lock_service.dart';
import '../../services/background_service.dart';
import '../../services/backup_service.dart';
import '../../services/update_checker.dart' show UpdateCheckResult;
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../models/user_agent.dart';
import '../theme.dart';
import '../widgets/app_message.dart';
import 'about_screen.dart';
import 'context_screen.dart';
import 'briefing_screen.dart';
import 'cron_jobs_screen.dart';
import 'ollama_manage_screen.dart';
import 'goals_screen.dart';
import 'reminders_screen.dart';
import 'memory_screen.dart';
import 'files_screen.dart';
import 'help_screen.dart';
import 'node_screen.dart';
import 'modules_screen.dart';
import 'providers_screen.dart';
import 'skills_screen.dart';

/// App configuration: appearance (theme), providers (full-screen manager),
/// agent behaviour (max steps 1-100 via slider + custom input), context
/// manager, Node.js runtime, files, import/export and language. Every
/// change is persisted immediately via [SettingsController].
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final TextEditingController _maxSteps;

  /// Android battery-optimization state (v1.28.0): null until the first
  /// platform query resolves; drives the Background reliability tile.
  bool? _batteryExempted;

  @override
  void initState() {
    super.initState();
    final AppSettings settings = ref.read(settingsProvider);
    _maxSteps = TextEditingController(text: '${settings.maxSteps}');
    _refreshBatteryState();
  }

  Future<void> _refreshBatteryState() async {
    try {
      final bool exempted = await ref
          .read(backgroundRunServiceProvider)
          .isIgnoringBatteryOptimization();
      if (mounted) setState(() => _batteryExempted = exempted);
    } catch (_) {
      // Platform without the query (tests/OEM): tile stays neutral.
    }
  }

  Future<void> _requestBatteryExemption() async {
    try {
      await ref
          .read(backgroundRunServiceProvider)
          .requestIgnoreBatteryOptimization();
    } catch (_) {
      // Never surface as an app error.
    }
    // The system dialog may take a moment; re-query after returning.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) await _refreshBatteryState();
  }

  @override
  void dispose() {
    _maxSteps.dispose();
    super.dispose();
  }

  void _commit({
    bool? agentMode,
    bool? automationEnabled,
    bool? runUntilDone,
    bool? planFirst,
    bool? runInBackground,
    bool? askRandomUa,
    bool? autoTitle,
    bool? appLockEnabled,
    bool? notifyOnDone,
    bool? checkUpdatesOnStart,
    bool? ipSwitchWarnEnabled,
    bool? autoRetryEnabled,
    Object? autoRetryAttempts,
    Object? autoRetryDelay,
    bool? deviceCommandsEnabled,
    Object? maxSteps,
    String? languageCode,
    ThemeModeSetting? themeMode,
    UaMode? uaMode,
  }) {
    final AppSettings current = ref.read(settingsProvider);
    ref
        .read(settingsProvider.notifier)
        .update(
          current.copyWith(
            agentMode: agentMode,
            automationEnabled: automationEnabled,
            runUntilDone: runUntilDone,
            planFirst: planFirst,
            runInBackground: runInBackground,
            askRandomUa: askRandomUa,
            autoTitle: autoTitle,
            appLockEnabled: appLockEnabled,
            notifyOnDone: notifyOnDone,
            checkUpdatesOnStart: checkUpdatesOnStart,
            ipSwitchWarnEnabled: ipSwitchWarnEnabled,
            autoRetryEnabled: autoRetryEnabled,
            autoRetryAttempts: autoRetryAttempts ?? current.autoRetryAttempts,
            autoRetryDelay: autoRetryDelay ?? current.autoRetryDelay,
            deviceCommandsEnabled:
                deviceCommandsEnabled ?? current.deviceCommandsEnabled,
            maxSteps: maxSteps ?? current.maxSteps,
            languageCode: languageCode,
            themeMode: themeMode,
            uaMode: uaMode,
          ),
        );
    if (mounted) {
      setState(() {
        if (_maxSteps.text != '${current.maxSteps}') {
          _maxSteps.text = '${current.maxSteps}';
        }
      });
    }
  }

  /// Passphrase entry dialog shared by create/restore. Returns null when
  /// the user cancelled.
  Future<String?> _askPassphrase(
    BuildContext context,
    AppStrings strings,
    String title,
  ) async {
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          key: const Key('backup-passphrase-field'),
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(labelText: strings.backupPassphraseLabel),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: Text(strings.backupCreate),
          ),
        ],
      ),
    );
  }

  /// v1.49.6: centered message dialog instead of a SnackBar — settings rows
  /// no longer shift when feedback arrives.
  void _snackHere(BuildContext context, String message) {
    showAppMessage(context, message);
  }

  Future<void> _createBackup(BuildContext context) async {
    final AppStrings strings = stringsOf(context);
    final String? passphrase = await _askPassphrase(
      context,
      strings,
      strings.backupCreate,
    );
    if (passphrase == null) return;
    if (passphrase.length < 8) {
      if (context.mounted) _snackHere(context, strings.backupPassphraseShort);
      return;
    }
    try {
      final File file = await ref
          .read(backupServiceProvider)
          .createBackup(passphrase: passphrase);
      if (context.mounted) _snackHere(context, strings.exportDone(file.path));
    } catch (_) {
      if (context.mounted) _snackHere(context, strings.backupFailed);
    }
  }

  Future<void> _restoreBackup(BuildContext context) async {
    final AppStrings strings = stringsOf(context);
    try {
      final XFile? picked = await openFile();
      if (picked == null) return;
      if (!context.mounted) return;
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: Text(strings.backupConfirmTitle),
          content: Text(strings.backupConfirmBody),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const Key('backup-confirm-restore'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.backupRestore),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      if (!context.mounted) return;
      final String? passphrase = await _askPassphrase(
        context,
        strings,
        strings.backupRestore,
      );
      if (passphrase == null) return;
      if (passphrase.length < 8) {
        if (context.mounted) {
          _snackHere(context, strings.backupPassphraseShort);
        }
        return;
      }
      final BackupRestoreResult result = await ref
          .read(backupServiceProvider)
          .restore(picked.path, passphrase: passphrase);
      // Refresh every surface that mirrors the replaced state.
      await ref
          .read(settingsProvider.notifier)
          .update(ref.read(settingsRepositoryProvider).load());
      ref.invalidate(chatListProvider);
      ref.invalidate(contextListProvider);
      if (context.mounted) {
        _snackHere(
          context,
          strings.backupRestoreDone(
            result.sessions,
            result.settingsApplied,
            result.contextEntries,
          ),
        );
      }
    } on BackupAuthException {
      if (context.mounted) _snackHere(context, strings.backupWrongPassphrase);
    } catch (_) {
      if (context.mounted) _snackHere(context, strings.backupFailed);
    }
  }

  /// App lock toggle (v1.18.0): enabling walks through a set-PIN dialog
  /// (4-8 digits, entered twice); disabling confirms and wipes the PIN.
  Future<void> _toggleAppLock(BuildContext context, bool enable) async {
    final AppStrings strings = stringsOf(context);
    final AppLockService lock = ref.read(appLockServiceProvider);
    if (!enable) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: Text(strings.appLockEnableTitle),
          content: Text(strings.appLockDisableConfirm),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.menu),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      await lock.clearPin();
      _commit(appLockEnabled: false);
      return;
    }
    final String? pin = await _askPin(context, strings);
    if (pin == null) return;
    final bool stored = await lock.setPin(pin);
    if (!stored) {
      if (context.mounted) _snackHere(context, strings.appLockPinTooShort);
      return;
    }
    _commit(appLockEnabled: true);
  }

  /// PIN entry + confirmation dialog for enabling the lock. Returns the
  /// accepted PIN, or null when cancelled/mismatched. Validation problems
  /// render INLINE inside the dialog (v1.49.6) instead of stacking a
  /// second dialog on top of it.
  Future<String?> _askPin(BuildContext context, AppStrings strings) =>
      showDialog<String>(
        context: context,
        builder: (BuildContext dialogContext) => _PinSetupDialog(strings),
      );

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final AppSettings settings = ref.watch(settingsProvider);
    final ZPalette palette = context.palette;
    final int contextActive =
        (ref.watch(contextListProvider).value ??
                ref.read(contextRepositoryProvider).load())
            .where((ContextEntry e) => e.enabled)
            .length;
    return Scaffold(
      appBar: AppBar(title: Text(strings.settings)),
      body: SafeArea(
        // top:false: the AppBar already reserves the status bar height;
        // bottom keeps the last cards above the system navigation bar
        // (edge-to-edge is enforced on Android 15+).
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            // -- Appearance ------------------------------------------------
            _sectionTitle(strings.appearanceSection),
            _card(
              child: SegmentedButton<ThemeModeSetting>(
                key: const Key('theme-mode-segmented'),
                segments: <ButtonSegment<ThemeModeSetting>>[
                  ButtonSegment<ThemeModeSetting>(
                    value: ThemeModeSetting.light,
                    icon: const Icon(Icons.light_mode_outlined, size: 18),
                    label: Text(strings.themeLight),
                  ),
                  ButtonSegment<ThemeModeSetting>(
                    value: ThemeModeSetting.dark,
                    icon: const Icon(Icons.dark_mode_outlined, size: 18),
                    label: Text(strings.themeDark),
                  ),
                  ButtonSegment<ThemeModeSetting>(
                    value: ThemeModeSetting.system,
                    icon: const Icon(Icons.settings_suggest_outlined, size: 18),
                    label: Text(strings.themeSystem),
                  ),
                ],
                selected: <ThemeModeSetting>{settings.themeMode},
                onSelectionChanged: (Set<ThemeModeSetting> selection) =>
                    _commit(themeMode: selection.first),
              ),
            ),
            const SizedBox(height: 16),

            // -- CronJobs (v1.51.0, directly below Appearance per the
            // user's placement request) -----------------------------------
            _sectionTitle('CronJobs'),
            _card(
              child: ListTile(
                key: const Key('cronjobs-tile'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule_rounded),
                title: const Text('CronJobs'),
                subtitle: Text(
                  'Scheduled jobs for this chat + Telegram channel',
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CronJobsScreen(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // -- Local AI / Ollama (port Fase 2, directly below CronJobs) --
            _sectionTitle(strings.ollamaSectionTitle),
            _card(
              child: ListTile(
                key: const Key('ollama-manage-tile'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.memory_rounded),
                title: Text(strings.ollamaTileTitle),
                subtitle: Text(
                  strings.ollamaTileSubtitle,
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const OllamaManageScreen(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // -- Provider --------------------------------------------------
            _sectionTitle(strings.providerSection),
            _card(
              child: _ProviderSummaryTile(
                settings: settings,
                strings: strings,
                palette: palette,
              ),
            ),
            const SizedBox(height: 16),

            // -- Agent -----------------------------------------------------
            _sectionTitle(strings.agentSection),
            _card(
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('agent-mode-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.agentModeTitle),
                    subtitle: Text(
                      strings.agentModeSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.agentMode,
                    onChanged: (bool value) => _commit(agentMode: value),
                  ),
                  SwitchListTile(
                    key: const Key('automation-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.automationTitle),
                    subtitle: Text(
                      strings.automationSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.automationEnabled,
                    onChanged: (bool value) =>
                        _commit(automationEnabled: value),
                  ),
                  SwitchListTile(
                    key: const Key('background-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.runInBackgroundTitle),
                    subtitle: Text(
                      strings.runInBackgroundSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.runInBackground,
                    onChanged: (bool value) => _commit(runInBackground: value),
                  ),
                  SwitchListTile(
                    key: const Key('notify-on-done-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.notifyOnDoneTitle),
                    subtitle: Text(
                      strings.notifyOnDoneSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.notifyOnDone,
                    onChanged: (bool value) => _commit(notifyOnDone: value),
                  ),
                  ListTile(
                    key: const Key('battery-reliability-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _batteryExempted == true
                          ? Icons.battery_saver_rounded
                          : Icons.battery_alert_rounded,
                      size: 22,
                      color: _batteryExempted == true
                          ? const Color(0xFF2E9E5B)
                          : null,
                    ),
                    title: Text(strings.batteryTitle),
                    subtitle: Text(
                      _batteryExempted == true
                          ? strings.batteryExempted
                          : strings.batteryRestricted,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    onTap: _requestBatteryExemption,
                  ),
                  SwitchListTile(
                    key: const Key('run-until-done-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.runUntilDoneTitle),
                    subtitle: Text(
                      strings.runUntilDoneSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.runUntilDone,
                    onChanged: (bool value) => _commit(runUntilDone: value),
                  ),
                  SwitchListTile(
                    key: const Key('plan-first-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.planFirstTitle),
                    subtitle: Text(
                      strings.planFirstSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.planFirst,
                    onChanged: (bool value) => _commit(planFirst: value),
                  ),
                  SwitchListTile(
                    key: const Key('auto-title-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.autoTitleTitle),
                    subtitle: Text(
                      strings.autoTitleSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.autoTitle,
                    onChanged: (bool value) => _commit(autoTitle: value),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    strings.maxStepsTitle,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Slider(
                          key: const Key('max-steps-slider'),
                          min: minMaxSteps.toDouble(),
                          max: maxMaxSteps.toDouble(),
                          divisions: maxMaxSteps - minMaxSteps,
                          label: '${settings.maxSteps}',
                          value: settings.maxSteps.toDouble(),
                          // The cap is bypassed while "Run until done" is
                          // active — dim + disable the control.
                          onChanged: settings.runUntilDone
                              ? null
                              : (double value) {
                                  _maxSteps.text = '${value.round()}';
                                  _commit(maxSteps: value.round());
                                },
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: TextField(
                          key: const Key('max-steps-field'),
                          controller: _maxSteps,
                          enabled: !settings.runUntilDone,
                          keyboardType: TextInputType.number,
                          textAlign: TextAlign.center,
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 10,
                            ),
                          ),
                          onSubmitted: (String value) {
                            final int? parsed = int.tryParse(value);
                            final int clamped = clampMaxSteps(
                              parsed ?? settings.maxSteps,
                            );
                            _maxSteps.text = '$clamped';
                            _commit(maxSteps: clamped);
                          },
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      settings.runUntilDone
                          ? strings.runUntilDoneHint
                          : strings.maxStepsHint,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- Auto retry (v1.30.0) -------------------------------------
            _sectionTitle(strings.autoRetrySection),
            _card(
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('auto-retry-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.autoRetryTitle),
                    subtitle: Text(
                      strings.autoRetrySubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.autoRetryEnabled,
                    onChanged: (bool value) => _commit(autoRetryEnabled: value),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    strings.autoRetryAttemptsTitle,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: settings.autoRetryEnabled ? null : palette.muted,
                    ),
                  ),
                  Slider(
                    key: const Key('auto-retry-attempts-slider'),
                    min: minAutoRetryAttempts.toDouble(),
                    max: maxAutoRetryAttempts.toDouble(),
                    divisions: maxAutoRetryAttempts - minAutoRetryAttempts,
                    label: '${settings.autoRetryAttempts}',
                    value: settings.autoRetryAttempts.toDouble(),
                    onChanged: settings.autoRetryEnabled
                        ? (double value) =>
                              _commit(autoRetryAttempts: value.round())
                        : null,
                  ),
                  Text(
                    strings.autoRetryDelayTitle,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: settings.autoRetryEnabled ? null : palette.muted,
                    ),
                  ),
                  Slider(
                    key: const Key('auto-retry-delay-slider'),
                    min: minAutoRetryDelay.toDouble(),
                    max: maxAutoRetryDelay.toDouble(),
                    divisions: maxAutoRetryDelay - minAutoRetryDelay,
                    label: '${settings.autoRetryDelay}',
                    value: settings.autoRetryDelay.toDouble(),
                    onChanged: settings.autoRetryEnabled
                        ? (double value) =>
                              _commit(autoRetryDelay: value.round())
                        : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      strings.autoRetryHint,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- User Agent --------------------------------------------------
            _sectionTitle(strings.uaSection),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  DropdownButtonFormField<UaMode>(
                    key: const Key('ua-mode-dropdown'),
                    initialValue: settings.uaMode,
                    decoration: InputDecoration(
                      labelText: strings.uaModeTitle,
                      helperMaxLines: 3,
                    ),
                    items: <DropdownMenuItem<UaMode>>[
                      DropdownMenuItem<UaMode>(
                        value: UaMode.auto,
                        child: Text(strings.uaModeAuto),
                      ),
                      DropdownMenuItem<UaMode>(
                        value: UaMode.desktop,
                        child: Text(strings.uaModeDesktop),
                      ),
                      DropdownMenuItem<UaMode>(
                        value: UaMode.android,
                        child: Text(strings.uaModeAndroid),
                      ),
                    ],
                    onChanged: (UaMode? mode) {
                      if (mode != null) _commit(uaMode: mode);
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    strings.uaModeHint,
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.muted,
                      height: 1.4,
                    ),
                  ),
                  const Divider(height: 20),
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.devices_rounded,
                        size: 20,
                        color: palette.muted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              strings.uaCurrentLabel,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              ref
                                  .read(userAgentManagerProvider)
                                  .resolve(settings.uaMode)
                                  .label,
                              key: const Key('ua-current-preview'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const Key('ua-rotate-button'),
                        tooltip: strings.uaRotateTooltip,
                        icon: const Icon(Icons.autorenew_rounded),
                        onPressed: () async {
                          await ref
                              .read(userAgentManagerProvider)
                              .rotate(settings.uaMode);
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 20),
                  SwitchListTile(
                    key: const Key('ask-random-ua-switch'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(strings.uaAskRandomTitle),
                    subtitle: Text(
                      strings.uaAskRandomSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.askRandomUa,
                    onChanged: (bool value) => _commit(askRandomUa: value),
                  ),
                  const Divider(height: 20),
                  // v1.48.0 — chat-switch IP guard. Kept in the User Agent
                  // (network identity) card on purpose: together with the
                  // UA pick it governs the fingerprint the device shows the
                  // outside world while chatting.
                  SwitchListTile(
                    key: const Key('ip-switch-warn-switch'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(strings.ipSwitchWarnTitle),
                    subtitle: Text(
                      strings.ipSwitchWarnSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.ipSwitchWarnEnabled,
                    onChanged: (bool value) =>
                        _commit(ipSwitchWarnEnabled: value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- Context ---------------------------------------------------
            _sectionTitle(strings.contextSection),
            _card(
              child: ListTile(
                key: const Key('context-manager-tile'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.format_quote_rounded),
                title: Text(strings.contextManagerTitle),
                subtitle: Text(
                  strings.contextActiveCount(contextActive),
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ContextScreen(),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // -- Memory & Goals (v1.50.0) ----------------------------------
            _sectionTitle('Memory & Goals'),
            _card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    key: const Key('memory-manager-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.psychology_rounded),
                    title: const Text('Memory'),
                    subtitle: Text(
                      'Long-term facts the agent recalls across chats',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const MemoryScreen(),
                      ),
                    ),
                  ),
                  ListTile(
                    key: const Key('goals-manager-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.flag_rounded),
                    title: const Text('Goals'),
                    subtitle: Text(
                      'Your goals and their progress',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const GoalsScreen(),
                      ),
                    ),
                  ),
                  ListTile(
                    key: const Key('reminders-manager-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.alarm_rounded),
                    title: const Text('Reminders'),
                    subtitle: Text(
                      'Scheduled reminders for this chat',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const RemindersScreen(),
                      ),
                    ),
                  ),
                  ListTile(
                    key: const Key('briefing-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.dashboard_rounded),
                    title: const Text('Briefing'),
                    subtitle: Text(
                      'Goals, reminders, jobs and pinned memories of '
                      'this chat at a glance',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const BriefingScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- Node.js ---------------------------------------------------
            _sectionTitle(strings.nodeSection),
            _card(
              child: ListTile(
                key: const Key('node-manager-tile'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.javascript_rounded),
                title: Text(strings.nodeManagerTitle),
                subtitle: Text(
                  strings.nodeManagerHint,
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const NodeScreen()),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // -- Skills (v1.49.0) --------------------------------------------
            // Manager for installed skills: install from URL / ZIP, bundled
            // one-tap installs, per-skill enable + config (secrets encrypted
            // and masked), inspector, update, remove. Mirrors the Modules
            // manager card right below.
            _sectionTitle(strings.skillsTitle),
            _card(
              child: ListTile(
                key: const Key('skills-manager-tile'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.auto_awesome_rounded),
                title: Text(strings.skillsTitle),
                subtitle: Text(
                  strings.skillsSubtitle,
                  style: TextStyle(fontSize: 12, color: palette.muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SkillsScreen()),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // -- Modules (plugins) ------------------------------------------
            _sectionTitle(strings.modulesTitle),
            _card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    key: const Key('modules-manager-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.extension_rounded),
                    title: Text(strings.modulesTitle),
                    subtitle: Text(
                      strings.modulesEmptyHint,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const ModulesScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  // v1.31.0 — master switch for the module `device`
                  // capability (zagents.device.shell). Off by default:
                  // rooted phones only, activation consent still applies.
                  SwitchListTile(
                    key: const Key('device-commands-switch'),
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.developer_mode_rounded),
                    title: Text(strings.deviceCommandsTitle),
                    subtitle: Text(
                      strings.deviceCommandsSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.deviceCommandsEnabled,
                    onChanged: (bool value) =>
                        _commit(deviceCommandsEnabled: value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- Data ------------------------------------------------------
            _sectionTitle(strings.dataSection),
            _card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    key: const Key('files-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_open_rounded),
                    title: Text(strings.filesTitle),
                    subtitle: Text(
                      strings.filesHint,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const FilesScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- Backup & restore (v1.17.0) --------------------------------
            _sectionTitle(strings.backupSectionTitle),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    strings.backupCreateHint,
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                  ListTile(
                    key: const Key('backup-create-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.backup_outlined),
                    title: Text(strings.backupCreate),
                    onTap: () => _createBackup(context),
                  ),
                  const Divider(height: 1),
                  Text(
                    strings.backupRestoreHint,
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                  ListTile(
                    key: const Key('backup-restore-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.restore_rounded),
                    title: Text(strings.backupRestore),
                    onTap: () => _restoreBackup(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- App lock (v1.18.0) ----------------------------------------
            _sectionTitle(strings.appLockSection),
            _card(
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('app-lock-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.appLockEnableTitle),
                    subtitle: Text(
                      strings.appLockEnableSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    value: settings.appLockEnabled,
                    onChanged: (bool value) => _toggleAppLock(context, value),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // -- Language --------------------------------------------------
            _sectionTitle(strings.languageSection),
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    strings.languageSubtitle,
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                  RadioGroup<String>(
                    groupValue: settings.languageCode,
                    onChanged: (String? code) =>
                        _commit(languageCode: code ?? 'en'),
                    child: Column(
                      children: <Widget>[
                        RadioListTile<String>(
                          key: const Key('lang-en'),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(strings.englishOption),
                          value: 'en',
                        ),
                        RadioListTile<String>(
                          key: const Key('lang-id'),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: Text(strings.indonesianOption),
                          value: 'id',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _sectionTitle(strings.helpAboutSection),
            _card(
              child: Column(
                children: <Widget>[
                  // v1.41.5 — the complete user guide lives on its own
                  // screen; the tile sits ABOVE About, as requested.
                  ListTile(
                    key: const Key('help-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.help_outline_rounded),
                    title: Text(strings.helpTileTitle),
                    subtitle: Text(
                      strings.helpTileSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const HelpScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    key: const Key('about-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.info_outline_rounded),
                    title: Text(strings.aboutTileTitle),
                    subtitle: Text(
                      strings.aboutTileSubtitle,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AboutScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  // v1.44.0 — update check controls. Sideloaded APKs have
                  // no store to nudge; the banner + this tile are the
                  // only update signals.
                  SwitchListTile(
                    key: const Key('check-updates-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(strings.checkUpdatesOnStart),
                    value: settings.checkUpdatesOnStart,
                    onChanged: (bool value) =>
                        _commit(checkUpdatesOnStart: value),
                  ),
                  ListTile(
                    key: const Key('check-updates-now-tile'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.system_update_rounded),
                    title: Text(strings.checkUpdatesNow),
                    subtitle: Text(
                      _updateSubtitle(strings),
                      style: TextStyle(fontSize: 12, color: palette.muted),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing:
                        ref.watch(
                          updateCheckProvider.select(
                            (UpdateCheckState s) => s.checking,
                          ),
                        )
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: () =>
                        ref.read(updateCheckProvider.notifier).checkNow(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// Subtitle of the "Check for updates now" tile — reflects the last
  /// check (or the running version when none has completed yet).
  String _updateSubtitle(AppStrings strings) {
    final UpdateCheckState state = ref.watch(updateCheckProvider);
    if (state.checking) return strings.updateChecking;
    final UpdateCheckResult? result = state.result;
    if (result == null) return kAppVersion;
    if (!result.ok) return strings.updateCheckFailed;
    if (result.updateAvailable) {
      return '${strings.updateBannerTitle} — ${result.latestTag}';
    }
    return '${strings.updateUpToDate} ($kAppVersion)';
  }

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w700,
        color: kMutedTextColor,
      ),
    ),
  );

  Widget _card({required Widget child}) => Container(
    decoration: BoxDecoration(
      color: context.zSurface,
      borderRadius: BorderRadius.circular(kCardRadius),
      border: Border.all(color: context.zBorder),
    ),
    // Material so ListTiles can paint their ink on a proper ancestor.
    child: Material(
      type: MaterialType.transparency,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );
}

/// Compact summary of the active provider connection. Opens the full-screen
/// [ProvidersScreen] where CRUD happens (the old inline fields + modal
/// dialog were cramped, overflowed under the keyboard and lost edits).
class _ProviderSummaryTile extends StatelessWidget {
  const _ProviderSummaryTile({
    required this.settings,
    required this.strings,
    required this.palette,
  });

  final AppSettings settings;
  final AppStrings strings;
  final ZPalette palette;

  @override
  Widget build(BuildContext context) {
    final ProviderPreset? active = settings.activePreset;
    final bool hasKey = active?.hasKey ?? settings.apiKey.trim().isNotEmpty;
    final String host = presetHostLabel(settings.baseUrl);
    return ListTile(
      key: const Key('providers-tile'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        Icons.dns_rounded,
        size: 24,
        color: hasKey ? kAccentColor : palette.muted,
      ),
      title: Text(
        settings.providerName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
      subtitle: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              <String>[
                if (host.isNotEmpty) host,
                settings.model.isNotEmpty ? settings.model : '—',
              ].join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: palette.muted),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            hasKey ? '· ${strings.presetHasKey}' : '· ${strings.presetNoKey}',
            style: TextStyle(
              fontSize: 11,
              color: hasKey ? Colors.green.shade400 : palette.muted,
            ),
          ),
        ],
      ),
      trailing: Icon(Icons.chevron_right_rounded, color: palette.muted),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const ProvidersScreen())),
    );
  }
}

/// PIN setup dialog with INLINE validation (v1.49.6): too-short pins and
/// mismatched confirmations show an error line inside this dialog instead
/// of stacking feedback dialogs on top of it.
class _PinSetupDialog extends StatefulWidget {
  const _PinSetupDialog(this.strings);

  final AppStrings strings;

  @override
  State<_PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends State<_PinSetupDialog> {
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _pin.text.trim();
    if (value.length < 4 || value.length > 8) {
      setState(() => _error = widget.strings.appLockPinTooShort);
      return;
    }
    if (value != _confirm.text.trim()) {
      setState(() => _error = widget.strings.appLockPinMismatch);
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = widget.strings;
    return AlertDialog(
      title: Text(strings.appLockSetPinTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            key: const Key('lock-set-pin-field'),
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            onChanged: (String _) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: strings.appLockPinField,
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('lock-confirm-pin-field'),
            controller: _confirm,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            onChanged: (String _) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: strings.appLockConfirmPin,
              counterText: '',
            ),
          ),
          // Inline error slot — reserves nothing when there is no error so
          // the dialog geometry stays stable.
          if (_error != null)
            Padding(
              key: const Key('lock-pin-error'),
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.error_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('lock-save-pin'),
          onPressed: _submit,
          child: Text(strings.appLockSetPinTitle),
        ),
      ],
    );
  }
}
