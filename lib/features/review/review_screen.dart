// "Para revisar" (Paso 23): las visitas que el servidor rechazó o que
// chocaron con un cambio hecho en el servidor, con lo necesario para decidir.
//
// - Conflicto: tabla "tu versión / en el servidor" campo a campo, y elegir
//   cuál se queda.
// - Rechazo: el motivo y los campos que señaló el servidor. Corregir (abre el
//   formulario), reintentar tal cual, o descartar.
//
// Las dos acciones que pierden datos —quedarse con la versión del servidor y
// descartar— piden confirmación en un diálogo cuyo botón destructivo hay que
// pulsar a propósito (N-05: nada se descarta sin que el agente lo pida).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/forms/form_definition.dart';
import '../../core/providers.dart';
import '../../core/sync/quarantine_service.dart';
import '../../data/local/form_template_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/forms/dynamic_form.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_page_body.dart';
import 'correction_screen.dart';

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key, required this.orgId});

  final String orgId;

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  List<QuarantinedVisit>? _items;

  /// Plantilla de cada visita, para mostrar etiquetas en vez de claves.
  final Map<String, FormDefinition?> _definitions = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dependencies = ref.read(appDependenciesProvider);
    final items = await dependencies.quarantine.list(orgId: widget.orgId);
    for (final item in items) {
      final id = item.visit.templateVersionId;
      if (_definitions.containsKey(id)) continue;
      final lookup = await dependencies.formTemplates.forVisit(orgId: widget.orgId, templateVersionId: id);
      _definitions[id] = lookup is TemplateReady ? lookup.definition : null;
    }
    if (mounted) setState(() => _items = items);
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
    await _load();
  }

  Future<bool> _confirm({required String title, required String body, required String confirm}) async {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: const Key('review_confirm_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.reviewConfirmCancel),
          ),
          FilledButton(
            key: const Key('review_confirm_destructive'),
            style: FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.reviewTitle)),
      body: AppPageBody(
        children: [
          if (items == null)
            const Center(child: CircularProgressIndicator())
          else if (items.isEmpty)
            Text(l10n.reviewEmpty, key: const Key('review_empty'))
          else
            for (final item in items) ...[
              _ReviewCard(
                key: ValueKey('review-${item.visit.id}'),
                item: item,
                definition: _definitions[item.visit.templateVersionId],
                busy: _busy,
                onResendMine: () => _run(() => ref.read(appDependenciesProvider).quarantine.resendMine(item), l10n.reviewQueued),
                onAcceptServer: () async {
                  final ok = await _confirm(
                    title: l10n.reviewAcceptServerTitle,
                    body: l10n.reviewAcceptServerBody,
                    confirm: l10n.reviewAcceptServerConfirm,
                  );
                  if (ok) await _run(() => ref.read(appDependenciesProvider).quarantine.acceptServer(item), l10n.reviewResolved);
                },
                onRetry: () => _run(() => ref.read(appDependenciesProvider).quarantine.retry(item), l10n.reviewQueued),
                onCorrect: () async {
                  final corrected = await Navigator.of(
                    context,
                  ).push<bool>(MaterialPageRoute(builder: (_) => CorrectionScreen(item: item)));
                  if (corrected == true && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.reviewQueued)));
                    await _load();
                  }
                },
                onDiscard: () async {
                  // Una edición rechazada de una visita que el servidor ya
                  // tiene no borra la visita: vuelve a la del servidor.
                  final ok = item.existsOnServer
                      ? await _confirm(
                          title: l10n.reviewDiscardChangesTitle,
                          body: l10n.reviewDiscardChangesBody,
                          confirm: l10n.reviewDiscardChangesConfirm,
                        )
                      : await _confirm(
                          title: l10n.reviewDiscardTitle,
                          body: l10n.reviewDiscardBody,
                          confirm: l10n.reviewDiscardConfirm,
                        );
                  if (ok) await _run(() => ref.read(appDependenciesProvider).quarantine.discard(item), l10n.reviewDiscarded);
                },
              ),
              const AppGap.lg(),
            ],
        ],
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    super.key,
    required this.item,
    required this.definition,
    required this.busy,
    required this.onResendMine,
    required this.onAcceptServer,
    required this.onRetry,
    required this.onCorrect,
    required this.onDiscard,
  });

  final QuarantinedVisit item;
  final FormDefinition? definition;
  final bool busy;
  final VoidCallback onResendMine;
  final VoidCallback onAcceptServer;
  final VoidCallback onRetry;
  final VoidCallback onCorrect;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final localizations = MaterialLocalizations.of(context);
    final captured = item.visit.capturedAt.toLocal();
    final isConflict = item.kind == QuarantineKind.conflict;

    String label(String key) {
      final field = definition?.fields.where((f) => f.key == key).firstOrNull;
      return field?.label.resolve(locale) ?? key;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(item.templateName ?? l10n.homeVisitUntitled, style: theme.textTheme.titleMedium),
            Text(
              '${localizations.formatShortDate(captured)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(captured))}',
              style: theme.textTheme.bodySmall,
            ),
            const AppGap(AppSpacing.xs),
            Text(
              isConflict ? l10n.reviewKindConflict : l10n.reviewKindRejected,
              style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.error),
            ),
            if (isConflict) Text(l10n.reviewConflictExplain) else if (item.message.isNotEmpty) Text(l10n.reviewServerSays(item.message)),
            for (final v in item.violations)
              Text(
                l10n.reviewViolation(
                  v.field.startsWith('answers.') ? label(v.field.substring('answers.'.length)) : v.field,
                  formErrorMessage(l10n, v.reason),
                ),
              ),
            if (isConflict) ...[
              const AppGap.sm(),
              _DiffTable(diffs: item.differences, label: label),
            ],
            const AppGap.sm(),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                if (isConflict) ...[
                  FilledButton(
                    key: const Key('review_resend_mine'),
                    onPressed: busy ? null : onResendMine,
                    child: Text(l10n.reviewResendMine),
                  ),
                  OutlinedButton(
                    key: const Key('review_accept_server'),
                    onPressed: busy ? null : onAcceptServer,
                    child: Text(l10n.reviewAcceptServer),
                  ),
                ] else ...[
                  if (item.canCorrect)
                    FilledButton(
                      key: const Key('review_correct'),
                      onPressed: busy ? null : onCorrect,
                      child: Text(l10n.reviewCorrect),
                    ),
                  OutlinedButton(
                    key: const Key('review_retry'),
                    onPressed: busy ? null : onRetry,
                    child: Text(l10n.reviewRetry),
                  ),
                  TextButton(
                    key: const Key('review_discard'),
                    onPressed: busy ? null : onDiscard,
                    child: Text(item.existsOnServer ? l10n.reviewDiscardChanges : l10n.reviewDiscard),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DiffTable extends StatelessWidget {
  const _DiffTable({required this.diffs, required this.label});

  final List<FieldDiff> diffs;
  final String Function(String key) label;

  String _show(BuildContext context, Object? value) {
    final l10n = context.l10n;
    return switch (value) {
      null => l10n.reviewNoValue,
      true => l10n.reviewYes,
      false => l10n.reviewNo,
      final List<Object?> list => list.join(', '),
      final Map<Object?, Object?> map when map.containsKey('lat') => l10n.captureLocation('${map['lat']}', '${map['lon']}'),
      _ => '$value',
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final header = Theme.of(context).textTheme.labelLarge;
    return Table(
      key: const Key('review_diff_table'),
      columnWidths: const {0: FlexColumnWidth(), 1: FlexColumnWidth(), 2: FlexColumnWidth()},
      children: [
        TableRow(
          children: [
            Text(l10n.reviewDiffField, style: header),
            Text(l10n.reviewDiffMine, style: header),
            Text(l10n.reviewDiffServer, style: header),
          ],
        ),
        for (final diff in diffs)
          TableRow(
            children: [
              Text(label(diff.field)),
              Text(_show(context, diff.mine)),
              Text(_show(context, diff.server)),
            ],
          ),
      ],
    );
  }
}
