import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/model_catalog.dart';
import '../theme.dart';
import 'paged_list.dart';

/// Top-bar chip showing the active model; opens the picker sheet.
class ModelChip extends ConsumerWidget {
  const ModelChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppStrings strings = stringsOf(context);
    final String model = ref.watch(settingsProvider.select((s) => s.model));
    return InkWell(
      key: const Key('model-chip'),
      borderRadius: BorderRadius.circular(999),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        backgroundColor: context.zSurface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        isScrollControlled: true,
        builder: (_) => const ModelPickerSheet(),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: context.zSurfaceAlt,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: context.zBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // Shrinks with ellipsis when the app bar runs out of width.
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(
                  model.isEmpty ? strings.pickModel : model,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 18,
              color: context.zMuted,
            ),
          ],
        ),
      ),
    );
  }
}

enum _ModelFilter { all, tools, free }

/// Bottom sheet with the live model catalog of the active provider:
/// search box, filter chips (all / tool-calling / free) and paging.
/// Falls back to [suggestedModels] when no API key is set or the fetch
/// fails, and always allows typing a custom model id.
class ModelPickerSheet extends ConsumerStatefulWidget {
  const ModelPickerSheet({super.key});

  @override
  ConsumerState<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends ConsumerState<ModelPickerSheet> {
  late final TextEditingController _customController;
  final TextEditingController _searchController = TextEditingController();

  Future<List<RemoteModel>>? _catalogFuture;
  String? _errorMessage;
  String _query = '';
  _ModelFilter _filter = _ModelFilter.all;

  @override
  void initState() {
    super.initState();
    _customController = TextEditingController(
      text: ref.read(settingsProvider).model,
    );
    _reload();
  }

  @override
  void dispose() {
    _customController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool get _hasApiKey => ref.read(settingsProvider).apiKey.trim().isNotEmpty;

  /// Model ids cached on the active preset from the last successful
  /// fetch — the offline mirror of this provider's catalog.
  List<RemoteModel> get _cachedModels {
    final ProviderPreset? active = ref.read(settingsProvider).activePreset;
    return <RemoteModel>[
      for (final String id in active?.modelsCache ?? const <String>[])
        RemoteModel(id: id, name: id),
    ];
  }

  static List<RemoteModel> _asRemote(List<String> ids) => <RemoteModel>[
    for (final String id in ids) RemoteModel(id: id, name: id),
  ];

  /// Remembers the fetched catalog on the active preset so the picker can
  /// open instantly (and offline) with this provider's real models next
  /// time. Writes only when the list actually changed.
  void _persistCache(List<RemoteModel> models) {
    final AppSettings settings = ref.read(settingsProvider);
    final ProviderPreset? active = settings.activePreset;
    if (active == null || models.isEmpty) return;
    final List<String> ids = <String>[for (final RemoteModel m in models) m.id];
    if (listEquals(active.modelsCache, ids)) return;
    final List<ProviderPreset> presets = <ProviderPreset>[
      for (final ProviderPreset p in settings.presets)
        if (p.id == active.id) p.copyWith(modelsCache: ids) else p,
    ];
    ref
        .read(settingsProvider.notifier)
        .update(settings.copyWith(presets: presets));
  }

  /// Re-fetches the catalog. The future never fails: fetch errors are
  /// captured into [_errorMessage] and surfaced as an empty result, so the
  /// UI switches to the error card without async-error plumbing.
  void _reload() {
    setState(() {
      _errorMessage = null;
      if (_hasApiKey) {
        final AppSettings settings = ref.read(settingsProvider);
        _catalogFuture = ref
            .read(modelCatalogProvider)
            .fetchModels(baseUrl: settings.baseUrl, apiKey: settings.apiKey)
            .then<List<RemoteModel>>(
              (List<RemoteModel> models) {
                _persistCache(models);
                return models;
              },
              onError: (Object e) {
                if (mounted) {
                  setState(() => _errorMessage = e.toString());
                }
                return const <RemoteModel>[];
              },
            );
      } else {
        _catalogFuture = null;
      }
    });
  }

  void _select(String model) {
    final String trimmed = model.trim();
    if (trimmed.isEmpty) return;
    final AppSettings current = ref.read(settingsProvider);
    ref
        .read(settingsProvider.notifier)
        .update(current.copyWith(model: trimmed));
    Navigator.of(context).pop();
  }

  void _setFilter(_ModelFilter filter) {
    setState(() => _filter = filter);
  }

  void _setQuery(String value) {
    setState(() => _query = value);
  }

  List<RemoteModel> _applyFilters(List<RemoteModel> models) {
    final String q = _query.trim().toLowerCase();
    Iterable<RemoteModel> out = models;
    if (q.isNotEmpty) {
      out = out.where(
        (RemoteModel m) =>
            m.id.toLowerCase().contains(q) || m.name.toLowerCase().contains(q),
      );
    }
    switch (_filter) {
      case _ModelFilter.all:
        break;
      case _ModelFilter.tools:
        out = out.where((RemoteModel m) => m.supportsTools);
      case _ModelFilter.free:
        out = out.where((RemoteModel m) => m.isFree);
    }
    final List<RemoteModel> list = out.toList()
      ..sort((RemoteModel a, RemoteModel b) => a.id.compareTo(b.id));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    // The keyboard inset must come out of the sheet height, otherwise the
    // sheet grows taller than the screen and its header collides with the
    // status bar while the search field is focused.
    final double keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final double sheetHeight = math.max(
      320.0,
      MediaQuery.of(context).size.height * 0.85 - keyboardInset,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SizedBox(
        height: sheetHeight,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _header(strings),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  key: const Key('model-search-field'),
                  controller: _searchController,
                  onChanged: _setQuery,
                  decoration: InputDecoration(
                    hintText: strings.searchModelsHint,
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    isDense: true,
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: strings.cancel,
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _setQuery('');
                            },
                          ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Wrap(
                  spacing: 8,
                  children: <Widget>[
                    _filterChip(
                      key: 'model-filter-all',
                      label: strings.filterAll,
                      filter: _ModelFilter.all,
                    ),
                    _filterChip(
                      key: 'model-filter-tools',
                      label: strings.filterTools,
                      filter: _ModelFilter.tools,
                    ),
                    _filterChip(
                      key: 'model-filter-free',
                      label: strings.filterFree,
                      filter: _ModelFilter.free,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: context.zBorder),
              Expanded(child: _body(strings)),
              Divider(height: 1, color: context.zBorder),
              Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _customController,
                  decoration: InputDecoration(
                    hintText: strings.customModelHint,
                    suffixIcon: IconButton(
                      tooltip: strings.confirm,
                      icon: const Icon(Icons.check_rounded),
                      onPressed: () => _select(_customController.text),
                    ),
                  ),
                  onSubmitted: _select,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(AppStrings strings) {
    // Scoped to the provider configured in Settings: the chip always
    // reflects the connection actually used for chats.
    final AppSettings settings = ref.watch(settingsProvider);
    final String host = presetHostLabel(settings.baseUrl);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  strings.pickModel,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_hasApiKey)
                IconButton(
                  key: const Key('model-refresh-button'),
                  tooltip: strings.refreshCatalog,
                  icon: const Icon(Icons.refresh_rounded, size: 22),
                  onPressed: _reload,
                ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              Icon(Icons.dns_rounded, size: 13, color: context.zMuted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  host.isEmpty
                      ? settings.providerName
                      : '${settings.providerName}  ·  $host',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: context.zMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterChip({
    required String key,
    required String label,
    required _ModelFilter filter,
  }) => ChoiceChip(
    key: Key(key),
    label: Text(label, style: const TextStyle(fontSize: 12)),
    selected: _filter == filter,
    showCheckmark: false,
    labelPadding: const EdgeInsets.symmetric(horizontal: 10),
    visualDensity: VisualDensity.compact,
    onSelected: (bool selected) {
      if (selected) _setFilter(filter);
    },
  );

  Widget _body(AppStrings strings) {
    if (_catalogFuture == null) {
      // No API key yet: offline suggestions (searchable) + hint.
      final List<RemoteModel> suggestions = _applyFilters(
        _asRemote(suggestedModels),
      );
      return PagedList<RemoteModel>(
        prefix: 'model-suggest',
        showSearch: false,
        items: suggestions,
        resetKey: '$_query|${_filter.name}',
        header: <Widget>[
          _infoCard(icon: Icons.key_rounded, text: strings.modelsApiKeyHint),
        ],
        emptyBuilder: (_) => _emptyCard(strings),
        itemBuilder: (BuildContext context, RemoteModel model) =>
            _suggestionTile(model, strings),
      );
    }
    return FutureBuilder<List<RemoteModel>>(
      future: _catalogFuture,
      builder:
          (BuildContext context, AsyncSnapshot<List<RemoteModel>> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    semanticsLabel: strings.fetchingModels,
                  ),
                ),
              );
            }
            if (_errorMessage != null) {
              // Fetch failed: fall back to this provider's cached model
              // list when we have one — the search still applies to it.
              final List<RemoteModel> cached = _applyFilters(_cachedModels);
              if (cached.isNotEmpty) {
                return PagedList<RemoteModel>(
                  prefix: 'model',
                  showSearch: false,
                  items: cached,
                  resetKey: '$_query|${_filter.name}',
                  header: <Widget>[_offlineNote(strings)],
                  itemBuilder: (BuildContext context, RemoteModel model) =>
                      _modelTile(model, strings),
                );
              }
              final List<RemoteModel> suggestions = _applyFilters(
                _asRemote(suggestedModels),
              );
              return PagedList<RemoteModel>(
                prefix: 'model-suggest',
                showSearch: false,
                items: suggestions,
                resetKey: '$_query|${_filter.name}',
                header: <Widget>[_errorCard(strings)],
                emptyBuilder: (_) => _emptyCard(strings),
                itemBuilder: (BuildContext context, RemoteModel model) =>
                    _suggestionTile(model, strings),
              );
            }
            final List<RemoteModel> filtered = _applyFilters(
              snapshot.data ?? const <RemoteModel>[],
            );
            return PagedList<RemoteModel>(
              prefix: 'model',
              showSearch: false,
              items: filtered,
              resetKey: '$_query|${_filter.name}',
              emptyBuilder: (_) => _emptyCard(strings),
              itemBuilder: (BuildContext context, RemoteModel model) =>
                  _modelTile(model, strings),
            );
          },
    );
  }

  Widget _modelTile(RemoteModel model, AppStrings strings) {
    final String active = ref.watch(settingsProvider.select((s) => s.model));
    final bool selected = model.id == active;
    final List<String> meta = <String>[
      if (model.contextLength != null)
        '${(model.contextLength! / 1000).round()}k',
      if (model.supportsTools) strings.toolsBadge,
    ];
    return ListTile(
      dense: true,
      leading: Icon(
        selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        size: 18,
        color: selected ? kAccentColor : context.zMuted,
        // The checkmark tells TalkBack which model is active.
        semanticLabel: selected ? strings.activeBadge : null,
      ),
      title: Text(
        model.id,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
      ),
      subtitle: MergeSemantics(
        // One TalkBack stop: name, meta and the FREE badge together.
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                <String>[
                  if (model.name != model.id) model.name,
                  ...meta,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: context.zMuted),
              ),
            ),
            if (model.isFree)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: kAccentColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  strings.freeBadge,
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: kAccentColor,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
          ],
        ),
      ),
      onTap: () => _select(model.id),
    );
  }

  Widget _suggestionTile(RemoteModel model, AppStrings strings) {
    final String active = ref.watch(settingsProvider.select((s) => s.model));
    return ListTile(
      dense: true,
      leading: Icon(
        model.id == active ? Icons.check_circle_rounded : Icons.circle_outlined,
        size: 18,
        color: model.id == active ? kAccentColor : context.zMuted,
        // The checkmark tells TalkBack which model is active.
        semanticLabel: model.id == active ? strings.activeBadge : null,
      ),
      title: Text(
        model.id,
        style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
      ),
      onTap: () => _select(model.id),
    );
  }

  Widget _infoCard({required IconData icon, required String text}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.zSurfaceAlt,
        borderRadius: BorderRadius.circular(kCardRadius),
        border: Border.all(color: context.zBorder),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: context.zMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12, color: context.zMuted),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _offlineNote(AppStrings strings) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.zSurfaceAlt,
        borderRadius: BorderRadius.circular(kCardRadius),
        border: Border.all(color: context.zBorder),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.offline_bolt_rounded, size: 18, color: context.zMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              strings.modelsCachedNote,
              style: TextStyle(fontSize: 12, color: context.zMuted),
            ),
          ),
          TextButton(
            key: const Key('model-retry-button'),
            onPressed: _reload,
            child: Text(strings.modelsRetry),
          ),
        ],
      ),
    ),
  );

  Widget _errorCard(AppStrings strings) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.zSurfaceAlt,
        borderRadius: BorderRadius.circular(kCardRadius),
        border: Border.all(color: context.zBorder),
      ),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.cloud_off_rounded, size: 18, color: context.zMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.modelsLoadError,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                key: const Key('model-retry-button'),
                onPressed: _reload,
                child: Text(strings.modelsRetry),
              ),
            ],
          ),
          if (_errorMessage != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _errorMessage!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: context.zMuted,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              strings.suggestedFallbackBody,
              style: TextStyle(fontSize: 11, color: context.zMuted),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _emptyCard(AppStrings strings) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
    child: Column(
      children: <Widget>[
        Icon(Icons.search_off_rounded, size: 32, color: context.zMuted),
        const SizedBox(height: 8),
        Text(
          strings.modelsEmpty,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          strings.modelsEmptyHint,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11.5, color: context.zMuted),
        ),
      ],
    ),
  );
}
