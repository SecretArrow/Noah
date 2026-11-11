import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/agent_controller.dart'
    show ChatState, ConfirmationRequest, ModuleSetupRequest;
import '../theme.dart';
import '../widgets/agent_toggle.dart';
import '../widgets/chat_body.dart';
import '../widgets/chat_drawer.dart';
import '../widgets/composer.dart';
import '../widgets/model_picker.dart';
import '../widgets/module_repair_card.dart';
import '../widgets/module_setup_sheet.dart';
import '../widgets/app_message.dart';
import '../../services/update_checker.dart' show UpdateCheckResult;
import 'files_screen.dart';
import 'goals_screen.dart';
import 'memory_screen.dart';
import 'prompt_library_screen.dart';
import 'settings_screen.dart';

/// Main screen: app bar (brand, model chip, agent toggle, language menu),
/// chat body, composer, floating pill bottom navigation.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// The setup request whose sheet was already auto-opened — a request
  /// stays pending (banner) until submitted, so the sheet must pop up
  /// exactly ONCE per request, not on every rebuild after a dismissal.
  ModuleSetupRequest? _autoOpenedSetup;

  /// Guards against two overlapping emissions pushing a second sheet
  /// while the first one is still on screen.
  bool _setupSheetOpen = false;

  @override
  void initState() {
    super.initState();
    // Continue-where-you-left-off: reopen the most recent conversation (if
    // any) so the first message continues it. Starting a NEW chat stays an
    // explicit drawer action ("New chat").
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(chatControllerProvider.notifier).restoreLastChat();
        // v1.44.0: one update probe per boot (skipped when the user turned
        // the check off in Settings) — banner shows only when a newer tag
        // exists on GitHub Releases.
        ref.read(updateCheckProvider.notifier).checkAtStartup();
      }
    });
  }

  Future<void> _openSetupSheet(ModuleSetupRequest request) async {
    if (_setupSheetOpen) return;
    _setupSheetOpen = true;
    // Kept AFTER dismissal on purpose: the guard above compares by
    // identity, so resetting it here made the very next state emission
    // (every ~48 ms during a run) reopen the sheet the user just closed.
    // Re-entry stays available through the persistent banner.
    _autoOpenedSetup = request;
    try {
      await showModuleSetupSheet(context, request);
    } finally {
      _setupSheetOpen = false;
    }
  }

  /// New chat from the bottom navigation pill — the SAME flow as the
  /// drawer's "New chat" button: when "offer random User-Agent" is
  /// enabled the dialog asks first, then the fresh conversation starts
  /// (no drawer to close from here).
  Future<void> _onNewChat() async {
    final AppSettings settings = ref.read(settingsProvider);
    if (settings.askRandomUa) {
      final AppStrings strings = stringsOf(context);
      final bool? randomize = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: Text(strings.randomUaDialogTitle),
          content: Text(strings.randomUaDialogBody),
          actions: <Widget>[
            TextButton(
              key: const Key('random-ua-decline'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(strings.randomUaDecline),
            ),
            FilledButton(
              key: const Key('random-ua-accept'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(strings.randomUaAccept),
            ),
          ],
        ),
      );
      if (randomize == true) {
        await ref
            .read(userAgentManagerProvider)
            .rotateRandom(settings.uaMode);
      }
    }
    if (!mounted) return;
    ref.read(chatControllerProvider.notifier).newChat();
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    // Narrow screens: drop decorative elements (brand mark, quick language
    // menu — still available in Settings) so the app bar can never overflow
    // into the action icons or behind the status bar area.
    final double width = MediaQuery.sizeOf(context).width;
    final bool showBrand = width >= 340;
    final bool showLanguageMenu = width >= 360;
    // Two NARROW listeners instead of one on the whole ChatState: the old
    // listener ran on every streaming emission (~20/s) even though it only
    // ever reads `error` and `setupRequest`.
    ref.listen<String?>(
      chatControllerProvider.select((ChatState s) => s.error),
      (String? prev, String? next) {
        if (next == null || next == prev) return;
        // v1.49.6: centered message dialog instead of a SnackBar — a
        // SnackBar shoved the streaming transcript up on every error,
        // which users found disruptive mid-scroll.
        showAppMessage(context, next);
      },
    );
    // A module waiting for its per-chat setup form: open the sheet once
    // per request object (the gate fires mid-run, so the identity guard
    // alone decides); afterwards the persistent banner drives re-entry.
    ref.listen<ModuleSetupRequest?>(
      chatControllerProvider.select((ChatState s) => s.setupRequest),
      (ModuleSetupRequest? prev, ModuleSetupRequest? next) {
        if (next == null || identical(next, _autoOpenedSetup)) return;
        _openSetupSheet(next);
      },
    );

    return PopScope<bool>(
      // The shell is the root route: Android back must confirm before the
      // app leaves (v1.28.0) so a running agent task is never lost to a
      // stray back press. Open drawers and pushed screens pop normally —
      // they handle back BEFORE this scope is reached.
      canPop: false,
      onPopInvokedWithResult: (bool didPop, bool? result) async {
        if (didPop) return;
        final AppStrings strings = stringsOf(context);
        final bool? exit = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            key: const Key('exit-confirm-dialog'),
            backgroundColor: Theme.of(context).colorScheme.surface,
            title: Text(strings.exitAppTitle),
            content: Text(strings.exitAppBody),
            actions: <Widget>[
              TextButton(
                key: const Key('exit-confirm-no'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(strings.cancel),
              ),
              FilledButton(
                key: const Key('exit-confirm-yes'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(strings.exitAppConfirm),
              ),
            ],
          ),
        );
        if (exit == true) {
          // Best-effort: platform channels are unavailable in some test
          // environments; the intent (leave the app) is what matters.
          try {
            await SystemNavigator.pop();
          } catch (_) {}
        }
      },
      child: Scaffold(
        drawer: const ChatDrawer(),
        bottomNavigationBar: _BottomNavPill(onNewChat: _onNewChat),
        appBar: AppBar(
          leading: Builder(
            // A Builder context BELOW the Scaffold is required for
            // Scaffold.of(); the widget's own context would throw.
            builder: (BuildContext menuContext) => IconButton(
              icon: const Icon(Icons.menu_rounded),
              tooltip: strings.menu,
              onPressed: () => Scaffold.of(menuContext).openDrawer(),
            ),
          ),
          titleSpacing: 0,
          title: Row(
            children: <Widget>[
              if (showBrand) ...<Widget>[
                const BrandMark(size: 28),
                const SizedBox(width: 10),
              ],
              // Flexible so a long model name shrinks (ellipsis) instead of
              // overflowing the app bar into the action icons.
              const Flexible(child: ModelChip()),
            ],
          ),
          actions: <Widget>[
            const AgentModeToggle(),
            if (showLanguageMenu) const _LanguageMenu(),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: strings.settings,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: <Widget>[
              const _UpdateBanner(),
              const Expanded(child: ChatBody()),
              const ModuleRepairCard(),
              const _ConfirmationCard(),
              const _ModuleSetupBanner(),
              const Composer(),
            ],
          ),
        ),
      ),
    );
  }
}

/// v1.38.0: explicit user-approval card for the `request_confirmation`
/// tool — the authorization boundary for money-moving/irreversible
/// actions. The agent loop is BLOCKED while this card is visible; only
/// Approve resumes the exact described action, Deny (or Stop) fails it
/// closed. Rendered as an inline card (not a dialog) so it survives
/// rebuilds exactly like the module repair card and can never be
/// swallowed by route churn.
class _ConfirmationCard extends ConsumerWidget {
  const _ConfirmationCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ConfirmationRequest? request = ref.watch(
      chatControllerProvider.select((ChatState s) => s.pendingConfirmation),
    );
    if (request == null) return const SizedBox.shrink();
    final AppStrings strings = stringsOf(context);
    return Material(
      key: const Key('confirmation-card'),
      color: request.danger ? context.zSurfaceAlt : context.zSurface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  request.danger
                      ? Icons.warning_amber_rounded
                      : Icons.touch_app_rounded,
                  size: 18,
                  color: request.danger
                      ? const Color(0xFFFFB020)
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    request.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 28),
              child: Text(
                strings.confirmDialogPrompt,
                style: TextStyle(
                  fontSize: 11.5,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
            if (request.details.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final String line in request.details)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                line,
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  height: 1.35,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 10, left: 28),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  OutlinedButton(
                    key: const Key('confirmation-deny'),
                    onPressed: () => ref
                        .read(chatControllerProvider.notifier)
                        .resolveConfirmation(request.id, false),
                    child: Text(strings.confirmDeny),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    key: const Key('confirmation-approve'),
                    style: FilledButton.styleFrom(
                      backgroundColor: request.danger
                          ? const Color(0xFFE5484D)
                          : null,
                    ),
                    onPressed: () => ref
                        .read(chatControllerProvider.notifier)
                        .resolveConfirmation(request.id, true),
                    child: Text(strings.confirmApprove),
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

/// Persistent banner for a module waiting on its per-chat setup form.
/// Tapping "Set up" opens the form again; submitting hides the banner and
/// re-runs the module (controller handles both).
class _ModuleSetupBanner extends ConsumerWidget {
  const _ModuleSetupBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ModuleSetupRequest? request = ref.watch(
      chatControllerProvider.select((ChatState s) => s.setupRequest),
    );
    if (request == null) return const SizedBox.shrink();
    // v1.29.0: when a SENT message is queued behind this form, say so —
    // the agent deliberately does not work on it until the input lands.
    final bool waiting = ref.watch(
      chatControllerProvider.select((ChatState s) => s.waitingForSetup),
    );
    final AppStrings strings = stringsOf(context);
    return Material(
      key: const Key('module-setup-banner'),
      color: context.zSurfaceAlt,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: <Widget>[
            const Icon(Icons.extension_rounded, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    strings.moduleSetupNeededTitle(request.title),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  if (waiting)
                    Text(
                      strings.moduleSetupWaitingHint,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const Key('module-setup-banner-button'),
              onPressed: () {
                final _HomeShellState? host = context
                    .findAncestorStateOfType<_HomeShellState>();
                host?._openSetupSheet(request);
              },
              child: Text(strings.moduleSetupBannerCta),
            ),
          ],
        ),
      ),
    );
  }
}

/// Quick language switch in the app bar: English (default) / Bahasa Indonesia.
class _LanguageMenu extends ConsumerWidget {
  const _LanguageMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    final String current = ref.watch(
      settingsProvider.select((s) => s.languageCode),
    );
    return PopupMenuButton<String>(
      key: const Key('language-menu'),
      icon: const Icon(Icons.language_rounded),
      tooltip: strings.languageSection,
      initialValue: current,
      onSelected: (String code) {
        final AppSettings settings = ref.read(settingsProvider);
        ref
            .read(settingsProvider.notifier)
            .update(settings.copyWith(languageCode: code));
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final String code in supportedLanguageCodes)
          PopupMenuItem<String>(
            key: Key('language-menu-$code'),
            value: code,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    languageNames[code] ?? code,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                if (code == current)
                  const Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: kAccentColor,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// v1.44.0 — update banner pinned above the chat body. Rendered only when
/// a completed GitHub check found a newer release tag; otherwise it is a
/// zero-height no-op so the chat layout is untouched. "View release"
/// copies the release URL to the clipboard (the app deliberately ships no
/// url_launcher dependency — sideload users know the releases page);
/// Dismiss hides the banner for this boot.
class _UpdateBanner extends ConsumerWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final UpdateCheckState state = ref.watch(updateCheckProvider);
    final UpdateCheckResult? result = state.result;
    if (result == null || !result.updateAvailable) {
      return const SizedBox.shrink();
    }
    final AppStrings strings = stringsOf(context);
    return Material(
      key: const Key('update-banner'),
      color: context.zSurfaceAlt,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: <Widget>[
            const Icon(
              Icons.system_update_rounded,
              size: 20,
              color: Color(0xFFE5484D),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    strings.updateBannerTitle,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${strings.updateBannerBody} '
                    '${result.latestTag.isNotEmpty ? result.latestTag : ''}',
                    style: TextStyle(fontSize: 12, color: context.zMuted),
                  ),
                ],
              ),
            ),
            TextButton(
              key: const Key('update-banner-open'),
              onPressed: () {
                final String url =
                    result.releaseUrl ?? result.apkDownloadUrl ?? '';
                if (url.isEmpty) return;
                Clipboard.setData(ClipboardData(text: url));
                showAppMessage(context, '${strings.updateOpenRelease}: $url');
              },
              child: Text(strings.updateOpenRelease),
            ),
            TextButton(
              key: const Key('update-banner-dismiss'),
              onPressed: () => ref.read(updateCheckProvider.notifier).dismiss(),
              child: Text(strings.updateDismiss),
            ),
          ],
        ),
      ),
    );
  }
}

/// Floating pill bottom navigation: five shortcuts that reuse the EXACT
/// navigation actions of their drawer counterparts — new chat (with its
/// random User-Agent offer), files, prompt library, goals, memory. The
/// chat shortcut is the always-active tab and renders with the
/// secondaryContainer pill highlight.
class _BottomNavPill extends StatelessWidget {
  const _BottomNavPill({required this.onNewChat});

  /// New-chat flow shared with the drawer's "New chat" button.
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final bool isLight = Theme.of(context).brightness == Brightness.light;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        height: 64,
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(kNavPillRadius),
          border: Border.all(
            color: isLight ? context.zBorder : Colors.transparent,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: isLight ? 0.06 : 0.4),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: <Widget>[
            _NavPillButton(
              tooltip: strings.newChat,
              icon: Icons.add_rounded,
              active: true,
              onTap: onNewChat,
            ),
            _NavPillButton(
              tooltip: strings.filesTitle,
              icon: Icons.folder_open_rounded,
              onTap: () => _push(context, const FilesScreen()),
            ),
            _NavPillButton(
              tooltip: strings.promptLibrary,
              icon: Icons.bookmarks_rounded,
              onTap: () => _push(context, const PromptLibraryScreen()),
            ),
            _NavPillButton(
              tooltip: 'Goals',
              icon: Icons.flag_rounded,
              onTap: () => _push(context, const GoalsScreen()),
            ),
            _NavPillButton(
              tooltip: 'Memory',
              icon: Icons.psychology_rounded,
              onTap: () => _push(context, const MemoryScreen()),
            ),
          ],
        ),
      ),
    );
  }

  /// Same route the matching drawer item pushes.
  void _push(BuildContext context, Widget screen) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
  }
}

/// One icon button inside the bottom navigation pill: the active tab
/// renders with the secondaryContainer pill highlight and the primary
/// icon color.
class _NavPillButton extends StatelessWidget {
  const _NavPillButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        icon: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.secondaryContainer
                : Colors.transparent,
            borderRadius: BorderRadius.circular(kPillRadius),
          ),
          child: Icon(
            icon,
            size: 22,
            color: active
                ? Theme.of(context).colorScheme.primary
                : context.zMuted,
          ),
        ),
      ),
    );
  }
}
