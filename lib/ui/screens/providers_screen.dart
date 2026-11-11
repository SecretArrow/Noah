import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/agentrouter_client.dart';
import '../theme.dart';
import '../widgets/paged_list.dart';
import '../widgets/app_message.dart';
import 'preset_editor_screen.dart';

/// Full-screen provider management: every preset is a card with its key
/// status, model and cache size. Tap a card to edit it in the full-screen
/// [PresetEditorScreen]; the bolt action switches the active connection,
/// and long-pressing a card asks for confirmation before switching.
class ProvidersScreen extends ConsumerWidget {
  const ProvidersScreen({super.key});

  void _activate(BuildContext context, WidgetRef ref, ProviderPreset preset) {
    final AppStrings strings = stringsOf(context);
    final AppSettings settings = ref.read(settingsProvider);
    ref
        .read(settingsProvider.notifier)
        .update(
          settings.copyWith(
            providerName: preset.name,
            baseUrl: preset.baseUrl,
            apiKey: preset.apiKey,
            model: preset.model,
            // v1.49.5 fix: activation must carry the preset's engine, or a
            // preset pinned to Anthropic/Responses silently reverts to the
            // previous provider's engine after switching.
            engine: preset.engine,
          ),
        );
    showAppMessage(context, strings.providerActivatedSnack(preset.name));
  }

  /// Long-press shortcut: ask for confirmation before switching the
  /// active connection to this provider.
  Future<void> _confirmActivate(
    BuildContext context,
    WidgetRef ref,
    ProviderPreset preset,
  ) async {
    final AppStrings strings = stringsOf(context);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        key: const Key('provider-activate-dialog'),
        title: Text(strings.activateProviderTitle),
        content: Text(strings.activateProviderBody(preset.name)),
        actions: <Widget>[
          TextButton(
            key: const Key('cancel-activate-provider'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            key: const Key('confirm-activate-provider'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.activateProviderConfirm),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      _activate(context, ref, preset);
    }
  }

  void _openEditor(BuildContext context, ProviderPreset preset) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PresetEditorScreen(preset: preset),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    final ZPalette palette = context.palette;
    final AppSettings settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.providersTitle),
        actions: <Widget>[
          IconButton(
            key: const Key('add-provider-button'),
            tooltip: strings.addProvider,
            icon: const Icon(Icons.add_rounded),
            onPressed: () =>
                _openEditor(context, ProviderPreset(id: newId(), name: '')),
          ),
        ],
      ),
      body: SafeArea(
        child: PagedList<ProviderPreset>(
          prefix: 'providers',
          searchFieldKey: const Key('providers-search-field'),
          searchHint: strings.searchProvidersHint,
          items: settings.presets,
          resetKey: settings.presets.length,
          filter: (ProviderPreset p, String q) =>
              p.name.toLowerCase().contains(q) ||
              presetHostLabel(p.baseUrl).toLowerCase().contains(q) ||
              p.model.toLowerCase().contains(q),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          header: <Widget>[
            _hintCard(context, strings, palette),
            const SizedBox(height: 4),
          ],
          itemBuilder: (BuildContext context, ProviderPreset preset) =>
              _ProviderCard(
                key: Key('provider-${preset.name}'),
                preset: preset,
                isActive: preset.name == settings.providerName,
                strings: strings,
                palette: palette,
                onOpen: () => _openEditor(context, preset),
                onUse: () => _activate(context, ref, preset),
                // Long-press the card itself: confirm-then-activate.
                onLongPress: preset.name == settings.providerName
                    ? null
                    : () => _confirmActivate(context, ref, preset),
              ),
          footer: <Widget>[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                key: const Key('add-provider-bottom'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: const Icon(Icons.add_rounded),
                label: Text(strings.addProvider),
                onPressed: () =>
                    _openEditor(context, ProviderPreset(id: newId(), name: '')),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _hintCard(
    BuildContext context,
    AppStrings strings,
    ZPalette palette,
  ) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: context.zSurfaceAlt,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: context.zBorder),
    ),
    child: Row(
      children: <Widget>[
        Icon(Icons.info_outline_rounded, size: 18, color: palette.muted),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            strings.providersHint,
            style: TextStyle(fontSize: 12, color: palette.muted, height: 1.4),
          ),
        ),
      ],
    ),
  );
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    super.key,
    required this.preset,
    required this.isActive,
    required this.strings,
    required this.palette,
    required this.onOpen,
    required this.onUse,
    this.onLongPress,
  });

  final ProviderPreset preset;
  final bool isActive;
  final AppStrings strings;
  final ZPalette palette;
  final VoidCallback onOpen;
  final VoidCallback onUse;
  final VoidCallback? onLongPress;

  /// AgentRouter presets (name or agentrouter.org host) show the protocol
  /// hint right on the card.
  bool get _isAgentRouter {
    if (preset.name == 'AgentRouter') return true;
    final String? host = hostOf(preset.baseUrl);
    return host != null && isAgentRouterHost(host);
  }

  @override
  Widget build(BuildContext context) {
    final String host = presetHostLabel(preset.baseUrl);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: context.zSurface,
        borderRadius: BorderRadius.circular(kCardRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(kCardRadius),
          onTap: onOpen,
          onLongPress: onLongPress,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kCardRadius),
              border: Border.all(
                color: isActive ? kAccentColor : context.zBorder,
                width: isActive ? 1.4 : 1,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: <Widget>[
                _avatar(context),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              preset.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (isActive) ...<Widget>[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: kAccentColor.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                strings.activeBadge,
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.6,
                                  color: kAccentColor,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              <String>[
                                if (host.isNotEmpty) host,
                                preset.model.isNotEmpty ? preset.model : '—',
                              ].join('  ·  '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: palette.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: <Widget>[
                          Icon(
                            preset.hasKey
                                ? Icons.key_rounded
                                : Icons.key_off_rounded,
                            size: 13,
                            color: preset.hasKey
                                ? Colors.green.shade400
                                : palette.muted,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            preset.hasKey
                                ? strings.presetHasKey
                                : strings.presetNoKey,
                            style: TextStyle(
                              fontSize: 11,
                              color: preset.hasKey
                                  ? Colors.green.shade400
                                  : palette.muted,
                            ),
                          ),
                          if (preset.hasModelsCache) ...<Widget>[
                            const SizedBox(width: 10),
                            Icon(
                              Icons.list_alt_rounded,
                              size: 13,
                              color: palette.muted,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                strings.modelsCachedCount(
                                  preset.modelsCache.length,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (_isAgentRouter) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(
                          strings.agentRouterHint,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: palette.muted,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: Key('use-provider-${preset.name}'),
                  tooltip: strings.useProviderTooltip,
                  icon: Icon(
                    isActive
                        ? Icons.check_circle_rounded
                        : Icons.electric_bolt_rounded,
                    size: 22,
                    color: isActive ? kAccentColor : palette.muted,
                  ),
                  onPressed: onUse,
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: palette.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _avatar(BuildContext context) {
    final String letter = preset.name.isNotEmpty
        ? preset.name.substring(0, 1).toUpperCase()
        : '?';
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: isActive ? kBrandGradient : null,
        color: isActive ? null : context.zSurfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? Colors.transparent : context.zBorder,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: isActive ? Colors.white : palette.muted,
        ),
      ),
    );
  }
}
