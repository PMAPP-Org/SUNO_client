// Lista de registros recientes con su estado de sincronización (Paso 22,
// tarea 6): pendiente, sincronizada o rechazada, y cuántos adjuntos faltan
// por subir. El registro aparece aquí en cuanto se guarda, sin red (UI
// optimista); el estado cambia tras sincronizar.
import 'package:flutter/material.dart';

import '../../data/local/record_status_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/theme/app_icons.dart';
import '../../ui/theme/app_tokens.dart';

class RecordStatusList extends StatelessWidget {
  const RecordStatusList({
    super.key,
    required this.records,
    this.onOpen,
    this.emptyText,
  });

  final List<RecordSummary> records;

  /// Abre el detalle del registro (Fase A).
  final void Function(RecordSummary record)? onOpen;

  /// Texto sin registros; por defecto, "todavía no hay registros".
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (records.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        child: Row(
          children: [
            Icon(
              AppIcons.records,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                emptyText ?? l10n.homeNoRecords,
                key: const Key('home_no_records'),
              ),
            ),
          ],
        ),
      );
    }
    final localizations = MaterialLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final record in records)
          ListTile(
            key: ValueKey('record-${record.id}'),
            contentPadding: EdgeInsets.zero,
            title: Text(record.templateName ?? l10n.homeRecordUntitled),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    _when(localizations, record.capturedAt.toLocal()),
                    if (record.attachments > 0)
                      l10n.homeRecordAttachments(record.attachments),
                    if (record.pendingUploads > 0)
                      l10n.homeRecordPendingUploads(record.pendingUploads),
                    if (record.failedUploads > 0)
                      l10n.homeRecordFailedUploads(record.failedUploads),
                  ].join(' · '),
                ),
                RecordStatusChip(status: record.status),
              ],
            ),
            leading: const Icon(AppIcons.records),
            onTap: onOpen == null ? null : () => onOpen!(record),
          ),
      ],
    );
  }
}

String _when(MaterialLocalizations localizations, DateTime local) =>
    '${localizations.formatShortDate(local)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';

class RecordStatusChip extends StatelessWidget {
  const RecordStatusChip({super.key, required this.status});

  final RecordSyncStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.statusColors;
    final scheme = Theme.of(context).colorScheme;
    final (label, background, foreground) = switch (status) {
      RecordSyncStatus.pending => (
        l10n.recordStatusPending,
        colors.warning,
        colors.onWarning,
      ),
      RecordSyncStatus.synced => (
        l10n.recordStatusSynced,
        colors.success,
        colors.onSuccess,
      ),
      RecordSyncStatus.rejected => (
        l10n.recordStatusRejected,
        scheme.error,
        scheme.onError,
      ),
    };
    return Chip(
      label: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelLarge?.copyWith(color: foreground),
      ),
      backgroundColor: background,
      side: BorderSide.none,
    );
  }
}
