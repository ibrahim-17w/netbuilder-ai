import 'package:flutter/material.dart';

import '../services/gemini_model_catalog.dart';
import '../theme/app_theme.dart';

/// Why the list looks the way it does - shown as a line above the results so
/// an empty or odd list is explained rather than mysterious.
class GeminiModelsResult {
  final List<GeminiModelInfo> models;
  final GeminiModelInfo? recommended;
  final bool usedFallback;
  final String note;

  const GeminiModelsResult({
    required this.models,
    required this.recommended,
    this.usedFallback = false,
    this.note = '',
  });
}

/// Detect and choose: the models this key can actually use, with the latest
/// stable one marked as recommended.
///
/// The dialog fetches live from the key when it can and falls back to the
/// current stable suggestions when it cannot (no key yet, or no network), so
/// the picker is never a dead end.
Future<String?> showGeminiModelPicker(
  BuildContext context, {
  required String apiKey,
  String currentModel = '',
  GeminiModelCatalog? catalog,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => GeminiModelPickerDialog(
      apiKey: apiKey,
      currentModel: currentModel,
      catalog: catalog,
    ),
  );
}

class GeminiModelPickerDialog extends StatefulWidget {
  final String apiKey;
  final String currentModel;
  final GeminiModelCatalog? catalog;

  const GeminiModelPickerDialog({
    super.key,
    required this.apiKey,
    this.currentModel = '',
    this.catalog,
  });

  @override
  State<GeminiModelPickerDialog> createState() =>
      _GeminiModelPickerDialogState();
}

class _GeminiModelPickerDialogState extends State<GeminiModelPickerDialog> {
  final _search = TextEditingController();
  late Future<GeminiModelsResult> _future;
  String? _custom;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<GeminiModelsResult> _load() async {
    final cat = widget.catalog ?? GeminiModelCatalog();
    try {
      final models = await cat.fetchFor(widget.apiKey);
      final recommended = GeminiModelCatalog.recommend(models);
      return GeminiModelsResult(
        models: models,
        recommended: recommended,
        note: models.isEmpty
            ? 'This key listed no chat models. Enable the Gemini API for its '
                'AI Studio project, or type a model id below.'
            : '',
      );
    } catch (e) {
      // No key, no network, rejected key: the picker still works, from the
      // current stable suggestions - and says plainly why.
      final models = [
        for (final name in GeminiModelCatalog.fallbackSuggestions)
          GeminiModelInfo(
            name: name,
            displayName: name,
            methods: const ['generateContent', 'streamGenerateContent'],
          ),
      ];
      return GeminiModelsResult(
        models: models,
        recommended: models.first,
        usedFallback: true,
        note: '${e.toString().replaceFirst('Exception: ', '')} '
            'Showing the known stable models instead.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.auto_awesome_outlined),
      title: const Text('Choose a Gemini model'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: FutureBuilder<GeminiModelsResult>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: AppTheme.s12),
                    Text('Detecting the models this key can use...'),
                  ],
                ),
              );
            }
            final result =
                snap.data ?? const GeminiModelsResult(models: [], recommended: null);
            return _list(context, result);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _list(BuildContext context, GeminiModelsResult result) {
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    final models = result.models;
    final filtered = query.isEmpty
        ? models
        : models
            .where((m) =>
                m.name.toLowerCase().contains(query) ||
                m.label.toLowerCase().contains(query))
            .toList();
    final chosen = _custom ?? widget.currentModel;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result.note.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppTheme.s8),
            child: Text(
              result.note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: result.usedFallback
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (result.recommended != null && !result.usedFallback) ...[
          Container(
            padding: const EdgeInsets.all(AppTheme.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppTheme.rMd),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.verified_outlined,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: AppTheme.s10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Recommended: ${result.recommended!.name}',
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(
                        'The latest stable version this key can use.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(result.recommended!.name),
                  child: const Text('Use'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppTheme.s10),
        ],
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Search',
            prefixIcon: const Icon(Icons.search, size: 18),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppTheme.s8),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    'No model matches "${_search.text.trim()}".',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final m = filtered[index];
                    final selected = chosen == m.name;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      leading: Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 18,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(m.name),
                      subtitle: Text(
                        [
                          if (m.label != m.name) m.label,
                          if (m.facts.isNotEmpty) m.facts,
                          if (m.preview || m.experimental) 'preview/experimental',
                        ].join('  ·  '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: result.recommended?.name == m.name
                          ? Tooltip(
                              message: 'Latest stable version for this key',
                              child: Chip(
                                avatar: Icon(
                                  Icons.verified_outlined,
                                  size: 14,
                                  color: theme.colorScheme.primary,
                                ),
                                label: const Text('Recommended'),
                                visualDensity: VisualDensity.compact,
                              ),
                            )
                          : null,
                      onTap: () => Navigator.of(context).pop(m.name),
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        const SizedBox(height: AppTheme.s8),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Or type any model id',
            hintText: 'gemini-2.5-flash',
            helperText: 'A model released after this build still works - the '
                'field accepts anything.',
            isDense: true,
          ),
          onChanged: (v) => setState(() => _custom = v.trim()),
        ),
        const SizedBox(height: AppTheme.s8),
        if (_custom != null && _custom!.trim().isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_custom!.trim()),
              child: Text('Use "${_custom!.trim()}"'),
            ),
          ),
      ],
    );
  }
}
