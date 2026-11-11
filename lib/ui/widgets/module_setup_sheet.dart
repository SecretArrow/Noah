import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../di.dart';
import '../../l10n/app_strings.dart';
import '../../services/agent_controller.dart' show ModuleSetupRequest;
import '../../services/module_registry.dart';
import '../theme.dart';

/// Opens the per-chat module setup form as a modal bottom sheet. Returns
/// the submitted values map, or null when the sheet was dismissed.
Future<Map<String, dynamic>?> showModuleSetupSheet(
  BuildContext context,
  ModuleSetupRequest request,
) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => ModuleSetupSheet(request: request),
  );
}

/// Per-chat setup form for a chat module (declared in module.json
/// `setup.fields`). The save button stays disabled until every REQUIRED
/// field is filled — "fill the form, then allow and run". Values are
/// validated by the controller again before they are persisted.
class ModuleSetupSheet extends ConsumerStatefulWidget {
  const ModuleSetupSheet({super.key, required this.request});

  final ModuleSetupRequest request;

  @override
  ConsumerState<ModuleSetupSheet> createState() => _ModuleSetupSheetState();
}

class _ModuleSetupSheetState extends ConsumerState<ModuleSetupSheet> {
  final Map<String, TextEditingController> _texts =
      <String, TextEditingController>{};
  final Map<String, bool> _booleans = <String, bool>{};
  final Map<String, bool> _visible = <String, bool>{};
  bool _submitting = false;

  ModuleSetupRequest get _request => widget.request;

  @override
  void initState() {
    super.initState();
    for (final ModuleSetupField field in _request.setup.fields) {
      switch (field.type) {
        case ModuleSetupFieldType.text:
        case ModuleSetupFieldType.password:
        case ModuleSetupFieldType.number:
          final Object? initial = _request.values[field.key];
          _texts[field.key] = TextEditingController(
            text: field.type == ModuleSetupFieldType.number && initial is num
                ? initial.toString()
                : initial is String
                ? initial
                : '',
          );
        case ModuleSetupFieldType.boolean:
          _booleans[field.key] = _request.values[field.key] is bool
              ? _request.values[field.key] as bool
              : false;
      }
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Current values typed into the form; number fields that do not parse
  /// into a finite number yield null (which fails the required check).
  Map<String, dynamic> _collect() => <String, dynamic>{
    for (final ModuleSetupField field in _request.setup.fields)
      field.key: switch (field.type) {
        ModuleSetupFieldType.text ||
        ModuleSetupFieldType.password => _texts[field.key]?.text ?? '',
        ModuleSetupFieldType.number => () {
          final String raw = _texts[field.key]?.text.trim() ?? '';
          if (raw.isEmpty) return null;
          final int? asInt = int.tryParse(raw);
          if (asInt != null) return asInt;
          final double? asDouble = double.tryParse(raw);
          return (asDouble != null && asDouble.isFinite) ? asDouble : null;
        }(),
        ModuleSetupFieldType.boolean => _booleans[field.key] ?? false,
      },
  };

  bool get _canSubmit => !_submitting && _request.setup.satisfiedBy(_collect());

  Future<void> _submit() async {
    if (_submitting) return;
    final Map<String, dynamic> values = _collect();
    if (!_request.setup.satisfiedBy(values)) return;
    setState(() => _submitting = true);
    bool submitted = false;
    try {
      // awaitRun:false (v1.34.0) — the future completes once the values
      // are persisted; the module run + agent resume continue in the
      // background so the sheet never freezes during the WebView boot.
      submitted = await ref
          .read(chatControllerProvider.notifier)
          .submitModuleSetup(_request.moduleName, values, awaitRun: false);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    // Only close on success — a persistence failure keeps the form open
    // so the user can retry (the banner stays either way).
    if (submitted && mounted) {
      Navigator.of(context).pop(values);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings strings = stringsOf(context);
    final ModuleSetup setup = _request.setup;
    return Padding(
      key: const Key('module-setup-sheet'),
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.extension_rounded, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _request.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (setup.description != null && setup.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  setup.description!,
                  style: TextStyle(fontSize: 13, color: context.zMuted),
                ),
              ),
            const SizedBox(height: 12),
            for (final ModuleSetupField field in setup.fields)
              _buildField(context, strings, field),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Icon(
                  Icons.lock_outline_rounded,
                  size: 13,
                  color: context.zMuted,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    strings.moduleSetupPerChatHint,
                    style: TextStyle(fontSize: 12, color: context.zMuted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    key: const Key('module-setup-cancel'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: Text(strings.cancel),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    key: const Key('module-setup-save'),
                    onPressed: _canSubmit ? _submit : null,
                    icon: _submitting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(strings.moduleSetupSaveRun),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField(
    BuildContext context,
    AppStrings strings,
    ModuleSetupField field,
  ) {
    final String suffix = field.required ? ' *' : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (field.type == ModuleSetupFieldType.boolean)
            SwitchListTile(
              key: Key('module-setup-field-${field.key}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${field.label}$suffix'),
              subtitle:
                  (field.description != null && field.description!.isNotEmpty)
                  ? Text(field.description!)
                  : null,
              value: _booleans[field.key] ?? false,
              onChanged: (bool v) => setState(() => _booleans[field.key] = v),
            )
          else
            TextField(
              key: Key('module-setup-field-${field.key}'),
              controller: _texts[field.key],
              onChanged: (_) => setState(() {}),
              obscureText:
                  field.type == ModuleSetupFieldType.password &&
                  !(_visible[field.key] ?? false),
              keyboardType: field.type == ModuleSetupFieldType.number
                  ? const TextInputType.numberWithOptions()
                  : TextInputType.text,
              decoration: InputDecoration(
                isDense: true,
                labelText: '${field.label}$suffix',
                hintText: field.placeholder,
                helperText:
                    (field.description != null && field.description!.isNotEmpty)
                    ? field.description
                    : null,
                suffixIcon: field.type == ModuleSetupFieldType.password
                    ? IconButton(
                        key: Key('module-setup-eye-${field.key}'),
                        icon: Icon(
                          (_visible[field.key] ?? false)
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          size: 18,
                        ),
                        onPressed: () => setState(
                          () => _visible[field.key] =
                              !(_visible[field.key] ?? false),
                        ),
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}
