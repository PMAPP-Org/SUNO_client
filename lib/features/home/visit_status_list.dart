// Lista de visitas recientes con su estado de sincronización (Paso 22,
// tarea 6): pendiente, sincronizada o rechazada, y cuántos adjuntos faltan
// por subir. La visita aparece aquí en cuanto se guarda, sin red (UI
// optimista); el estado cambia tras sincronizar.
import 'package:flutter/material.dart';

import '../../data/local/visit_status_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_theme.dart';

class VisitStatusList extends StatelessWidget {
  const VisitStatusList({super.key, required this.visits, this.onOpen, this.emptyText});

  final List<VisitSummary> visits;

  /// Abre el detalle de la visita (Fase A).
  final void Function(VisitSummary visit)? onOpen;

  /// Texto sin visitas; por defecto, "todavía no hay visitas".
  final String? emptyText;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (visits.isEmpty) return Text(emptyText ?? l10n.homeNoVisits, key: const Key('home_no_visits'));
    final localizations = MaterialLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final visit in visits)
          ListTile(
            key: ValueKey('visit-${visit.id}'),
            contentPadding: EdgeInsets.zero,
            title: Text(visit.templateName ?? l10n.homeVisitUntitled),
            subtitle: Text(
              [
                _when(localizations, visit.capturedAt.toLocal()),
                if (visit.attachments > 0) l10n.homeVisitAttachments(visit.attachments),
                if (visit.pendingUploads > 0) l10n.homeVisitPendingUploads(visit.pendingUploads),
                if (visit.failedUploads > 0) l10n.homeVisitFailedUploads(visit.failedUploads),
              ].join(' · '),
            ),
            trailing: VisitStatusChip(status: visit.status),
            onTap: onOpen == null ? null : () => onOpen!(visit),
          ),
      ],
    );
  }
}

String _when(MaterialLocalizations localizations, DateTime local) =>
    '${localizations.formatShortDate(local)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';

class VisitStatusChip extends StatelessWidget {
  const VisitStatusChip({super.key, required this.status});

  final VisitSyncStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.statusColors;
    final scheme = Theme.of(context).colorScheme;
    final (label, background, foreground) = switch (status) {
      VisitSyncStatus.pending => (l10n.visitStatusPending, colors.warning, colors.onWarning),
      VisitSyncStatus.synced => (l10n.visitStatusSynced, colors.success, colors.onSuccess),
      VisitSyncStatus.rejected => (l10n.visitStatusRejected, scheme.error, scheme.onError),
    };
    return Chip(
      label: Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: foreground)),
      backgroundColor: background,
      side: BorderSide.none,
    );
  }
}
