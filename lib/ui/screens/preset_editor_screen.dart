import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../models/models.dart';
import '../../services/agentrouter_client.dart';
import '../../services/model_catalog.dart';
import '../theme.dart';
import '../widgets/paged_list.dart';
import '../widgets/app_message.dart';

/// Full-screen editor for one provider preset (replaces the old modal
/// dialog, which overflowed under the keyboard and made the Save button
/// impossible to reach on phones).
///
/// From here the user can:
/// * edit name / base URL / API key of one provider,
/// * save the API key on its own with a dedicated button,
/// * fetch the models the provider actually exposes
///   (`GET {baseUrl}/models`) and pick one,
/// * save the preset (syncing the active connection when it is the active
///   provider) or delete it.
class PresetEditorScreen extends ConsumerStatefulWidget {
  const PresetEditorScreen({super.key, required this.preset});

  /// The preset to edit. Pass a fresh [ProviderPreset] (empty name) to
  /// create a new provider.
  final ProviderPreset preset;

  @override
  ConsumerState<PresetEditorScreen> createState() => _PresetEditorScreenState();
}

class _PresetEditorScreenState extends ConsumerState<PresetEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;

  /// v1.49.4 — wire protocol (engine) this provider speaks. Auto keeps the
  /// historical per-model routing; the pinned values force one transport.
  late LlmEngine _engine;

  /// Last known persisted snapshot of this preset. Field edits stay local
  /// until an explicit save; [_stored] is what the settings list holds.
  late ProviderPreset _stored;

  bool _obscureKey = true;
  bool _fetching = false;
  String? _fetchError;
  String? _validationError;
  List<RemoteModel> _models = const <RemoteModel>[];

  /// Bumped on every successful fetch so the paged model list resets to
  /// its first page when a fresh catalog arrives.
  int _fetchGeneration = 0;

  bool get _isNew => _stored.name.isEmpty;

  AppStrings get _strings => stringsOf(context);

  /// AgentRouter presets (by preset name or by agentrouter.org host) get
  /// the protocol hint: Anthropic Messages with automatic OpenAI-compatible
  /// fallback.
  bool get _isAgentRouter {
    if (_name.text.trim() == 'AgentRouter') return true;
    final String? host = hostOf(_baseUrl.text.trim());
    return host != null && isAgentRouterHost(host);
  }

  @override
  void initState() {
    super.initState();
    _stored = widget.preset;
    _name = TextEditingController(text: widget.preset.name);
    _baseUrl = TextEditingController(text: widget.preset.baseUrl);
    _apiKey = TextEditingController(text: widget.preset.apiKey);
    _model = TextEditingController(text: widget.preset.model);
    _engine = widget.preset.engine;
    _models = <RemoteModel>[
      for (final String id in widget.preset.modelsCache)
        RemoteModel(id: id, name: id),
    ];
  }

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    super.dispose();
  }

  /// v1.49.6: centered message dialog instead of a SnackBar — the editor
  /// form no longer shifts when feedback arrives.
  void _snack(String message) {
    if (!mounted) return;
    showAppMessage(context, message);
  }

  /// Shared validation. Returns the first problem, or null when OK.
  String? _validate({required bool requireUrl}) {
    if (_name.text.trim().isEmpty) return _strings.nameRequiredError;
    if (requireUrl && _baseUrl.text.trim().isEmpty) {
      return _strings.urlRequiredError;
    }
    final AppSettings settings = ref.read(settingsProvider);
    final String name = _name.text.trim();
    final bool duplicate = settings.presets.any(
      (ProviderPreset p) => p.id != widget.preset.id && p.name == name,
    );
    if (duplicate) return _strings.duplicateNameError;
    return null;
  }

  /// Upserts [updated] into the preset list. When this preset is the
  /// active provider the live connection is synced as well, so chats
  /// immediately use the saved values. [syncModel] controls whether the
  /// active model follows the preset (key-only saves must not clobber a
  /// model picked from the picker).
  AppSettings _upsert(ProviderPreset updated, {required bool syncModel}) {
    final AppSettings settings = ref.read(settingsProvider);
    final bool exists = settings.presets.any(
      (ProviderPreset p) => p.id == updated.id,
    );
    final List<ProviderPreset> presets = exists
        ? <ProviderPreset>[
            for (final ProviderPreset p in settings.presets)
              if (p.id == updated.id) updated else p,
          ]
        : <ProviderPreset>[...settings.presets, updated];
    if (settings.providerName == _stored.name) {
      return settings.copyWith(
        providerName: updated.name,
        baseUrl: updated.baseUrl,
        apiKey: updated.apiKey,
        model: syncModel ? updated.model : null,
        engine: updated.engine,
        presets: presets,
      );
    }
    return settings.copyWith(presets: presets);
  }

  /// Persists the whole form and closes the screen.
  Future<void> _saveAll() async {
    final String? error = _validate(requireUrl: true);
    if (error != null) {
      setState(() => _validationError = error);
      return;
    }
    _stored = ProviderPreset(
      id: widget.preset.id,
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text,
      model: _model.text.trim(),
      modelsCache: <String>[for (final RemoteModel m in _models) m.id],
      engine: _engine,
    );
    await ref
        .read(settingsProvider.notifier)
        .update(_upsert(_stored, syncModel: true));
    if (!mounted) return;
    // v1.49.6: close the editor FIRST, then surface the confirmation — the
    // feedback dialog lives on the ROOT navigator, so a pop() after showing
    // it would dismiss the DIALOG instead of this screen.
    final NavigatorState nav = Navigator.of(context);
    nav.pop();
    showAppMessage(nav.context, _strings.providerSavedSnack);
  }

  /// Persists just the API key (plus name/URL so the key has a home)
  /// without leaving the screen. This is the explicit per-provider key
  /// save the settings screen never had.
  Future<void> _saveApiKey() async {
    final String? error = _validate(requireUrl: false);
    if (error != null) {
      setState(() => _validationError = error);
      return;
    }
    _stored = _stored.copyWith(
      name: _name.text.trim(),
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text,
    );
    await ref
        .read(settingsProvider.notifier)
        .update(_upsert(_stored, syncModel: false));
    _snack(_strings.apiKeySavedSnack);
    if (mounted) setState(() => _validationError = null);
  }

  /// Fetches the models this provider exposes, caches them into the
  /// stored preset and shows them for selection.
  Future<void> _fetchModels() async {
    if (_fetching) return;
    if (_baseUrl.text.trim().isEmpty) {
      setState(() => _fetchError = _strings.urlRequiredError);
      return;
    }
    setState(() {
      _fetching = true;
      _fetchError = null;
    });
    final List<RemoteModel> models;
    try {
      models = await ref
          .read(modelCatalogProvider)
          .fetchModels(
            baseUrl: _baseUrl.text.trim(),
            apiKey: _apiKey.text.trim(),
          );
    } catch (e) {
      if (mounted) {
        setState(() {
          _fetching = false;
          _fetchError = e.toString();
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _fetching = false;
      _models = models;
      _fetchGeneration++;
    });
    // Cache the ids into the stored preset so the model picker (and the
    // next editor visit) can show them without refetching. New presets
    // are not written yet — the cache persists with the first save.
    final AppSettings settings = ref.read(settingsProvider);
    if (settings.presets.any((ProviderPreset p) => p.id == _stored.id)) {
      final ProviderPreset withCache = _stored.copyWith(
        modelsCache: <String>[for (final RemoteModel m in models) m.id],
      );
      _stored = withCache;
      await ref
          .read(settingsProvider.notifier)
          .update(_upsert(withCache, syncModel: false));
    }
    _snack(_strings.modelsFetchedSnack(models.length));
  }

  Future<void> _delete() async {
    final AppStrings strings = _strings;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: context.zSurface,
        title: Text(strings.deletePresetTitle),
        content: Text(strings.deletePresetBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              strings.delete,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final AppSettings settings = ref.read(settingsProvider);
    final List<ProviderPreset> remaining = settings.presets
        .where((ProviderPreset p) => p.id != widget.preset.id)
        .toList();
    AppSettings next;
    if (settings.providerName == _stored.name) {
      // Deleting the active provider falls back to the first remaining
      // preset (or a fresh OpenRouter default) so the app always has a
      // usable connection shape.
      final ProviderPreset fallback = remaining.isNotEmpty
          ? remaining.first
          : ProviderPreset(
              id: newId(),
              name: 'OpenRouter',
              baseUrl: providerPresets['OpenRouter'] ?? '',
            );
      next = settings.copyWith(
        providerName: fallback.name,
        baseUrl: fallback.baseUrl,
        apiKey: fallback.apiKey,
        model: fallback.model,
        presets: remaining.isEmpty ? <ProviderPreset>[fallback] : remaining,
      );
    } else {
      next = settings.copyWith(presets: remaining);
    }
    await ref.read(settingsProvider.notifier).update(next);
    if (!mounted) return;
    // v1.49.6: pop this screen before the feedback dialog (same reason as
    // _save — the dialog route would swallow a later pop()).
    final NavigatorState nav = Navigator.of(context);
    nav.pop();
    showAppMessage(nav.context, _strings.providerDeletedSnack);
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = _strings;
    final ZPalette palette = context.palette;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? strings.newProviderTitle : strings.editPreset),
        actions: <Widget>[
          IconButton(
            key: const Key('editor-save-appbar'),
            tooltip: strings.save,
            icon: const Icon(Icons.check_rounded),
            onPressed: _saveAll,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextField(
                    key: const Key('editor-name-field'),
                    controller: _name,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: strings.presetNameLabel,
                      hintText: 'My provider',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('editor-base-url-field'),
                    controller: _baseUrl,
                    keyboardType: TextInputType.url,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: strings.baseUrlLabel,
                      hintText: 'https://openrouter.ai/api/v1',
                    ),
                  ),
                  // AgentRouter speaks the Anthropic Messages protocol with
                  // an automatic OpenAI-compatible fallback — surface that
                  // whenever this preset targets it (name or host).
                  if (_isAgentRouter) ...<Widget>[
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.info_outline_rounded,
                          size: 14,
                          color: palette.muted,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            strings.agentRouterHint,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: palette.muted,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('editor-api-key-field'),
                    controller: _apiKey,
                    obscureText: _obscureKey,
                    decoration: InputDecoration(
                      labelText: strings.apiKeyLabel,
                      helperText: strings.apiKeyStoredLocally,
                      helperMaxLines: 3,
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureKey
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                        onPressed: () =>
                            setState(() => _obscureKey = !_obscureKey),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Explicit per-provider API key save: persists instantly
                  // without leaving the editor.
                  OutlinedButton.icon(
                    key: const Key('editor-save-api-key-button'),
                    icon: const Icon(Icons.key_rounded, size: 18),
                    label: Text(strings.saveApiKey),
                    onPressed: _saveApiKey,
                  ),
                  const SizedBox(height: 12),
                  // v1.49.4 — per-provider wire protocol: Anthropic
                  // Messages / OpenAI Chat Completions / OpenAI Responses
                  // / Auto (per-model routing + one-shot fallbacks).
                  // Placed BELOW the key-save button so the existing
                  // editor layout (and every test that taps it) keeps its
                  // exact geometry.
                  DropdownButtonFormField<LlmEngine>(
                    key: const Key('editor-engine-dropdown'),
                    initialValue: _engine,
                    decoration: InputDecoration(
                      labelText: strings.settingsEngineLabel,
                      helperText: strings.engineHint,
                      helperMaxLines: 5,
                    ),
                    items: <DropdownMenuItem<LlmEngine>>[
                      for (final LlmEngine e in LlmEngine.values)
                        DropdownMenuItem<LlmEngine>(
                          value: e,
                          child: Text(
                            _engineLabel(e, strings),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (LlmEngine? value) =>
                        setState(() => _engine = value ?? LlmEngine.auto),
                  ),
                  if (_validationError != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.error_outline_rounded,
                          size: 16,
                          color: Colors.redAccent,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _validationError!,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: Colors.redAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            _sectionTitle(strings.modelLabel),
            _card(child: _modelsSection(strings, palette)),
            if (!_isNew) ...<Widget>[
              const SizedBox(height: 16),
              _sectionTitle(strings.keyStatusSection),
              _card(
                child: Row(
                  children: <Widget>[
                    Icon(
                      _stored.hasKey
                          ? Icons.verified_rounded
                          : Icons.key_off_rounded,
                      size: 18,
                      color: _stored.hasKey
                          ? Colors.green.shade400
                          : palette.muted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _stored.hasKey
                          ? strings.presetHasKey
                          : strings.presetNoKey,
                      style: TextStyle(fontSize: 13, color: palette.muted),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      key: const Key('editor-delete-button'),
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: Colors.redAccent,
                      ),
                      label: Text(
                        strings.delete,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                      onPressed: _delete,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('editor-save-button'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              icon: const Icon(Icons.save_rounded),
              label: Text(strings.save),
              onPressed: _saveAll,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  String _engineLabel(LlmEngine engine, AppStrings strings) {
    switch (engine) {
      case LlmEngine.auto:
        return strings.engineAuto;
      case LlmEngine.anthropic:
        return strings.engineAnthropic;
      case LlmEngine.openai:
        return strings.engineOpenai;
      case LlmEngine.openaiResponses:
        return strings.engineOpenaiResponses;
    }
  }

  Widget _modelsSection(AppStrings strings, ZPalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TextField(
          key: const Key('editor-model-field'),
          controller: _model,
          decoration: InputDecoration(
            labelText: strings.modelLabel,
            hintText: strings.modelHint,
            suffixIcon: _model.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() => _model.clear()),
                  ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            FilledButton.tonalIcon(
              key: const Key('editor-fetch-models-button'),
              icon: _fetching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cloud_download_rounded, size: 18),
              label: Text(
                _fetching ? strings.fetchingModels : strings.fetchModels,
              ),
              onPressed: _fetching ? null : _fetchModels,
            ),
            const Spacer(),
            if (_models.isNotEmpty)
              Text(
                strings.modelsCachedCount(_models.length),
                style: TextStyle(fontSize: 11.5, color: palette.muted),
              ),
          ],
        ),
        if (_fetchError != null) ...<Widget>[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.zSurfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.zBorder),
            ),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.cloud_off_rounded,
                  size: 16,
                  color: Colors.redAccent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _fetchError!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Colors.redAccent,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_models.isEmpty && !_fetching && _fetchError == null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              strings.noModelsYet,
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
        if (_models.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          SizedBox(
            key: const Key('editor-model-list'),
            height: 320,
            child: PagedList<RemoteModel>(
              prefix: 'editor-model',
              items: _models,
              resetKey: _fetchGeneration,
              searchHint: strings.searchModelsHint,
              searchFieldKey: const Key('editor-model-search-field'),
              padding: EdgeInsets.zero,
              filter: (RemoteModel m, String q) =>
                  m.id.toLowerCase().contains(q) ||
                  m.name.toLowerCase().contains(q),
              emptyBuilder: (BuildContext emptyContext) => Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  strings.modelsEmpty,
                  style: TextStyle(fontSize: 12, color: emptyContext.zMuted),
                ),
              ),
              itemBuilder: (BuildContext context, RemoteModel m) {
                final bool selected = m.id == _model.text;
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 16,
                    color: selected ? kAccentColor : context.zMuted,
                  ),
                  title: Text(
                    m.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                  onTap: () => setState(() => _model.text = m.id),
                );
              },
            ),
          ),
        ],
      ],
    );
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
    width: double.infinity,
    decoration: BoxDecoration(
      color: context.zSurface,
      borderRadius: BorderRadius.circular(kCardRadius),
      border: Border.all(color: context.zBorder),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );
}
