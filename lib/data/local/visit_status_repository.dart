// Estado de sincronización de cada visita, para el agente (Paso 22, tarea 6).
//
// Se deriva de lo que ya hay en la BD local, sin estado propio:
// - **pendiente**: alguna operación de la visita o de sus adjuntos sigue en el
//   outbox (`pending`/`inflight`);
// - **rechazada**: alguna está en `quarantine` (se revisa en la pantalla de
//   conflictos, Paso 23);
// - **sincronizada**: ninguna queda en el outbox.
// Aparte, el estado de sus adjuntos en `AttachmentQueue` (Paso 18): cuántos
// están por subir (`pending`/`uploading`, se suben solos) y cuántos fallaron
// de forma permanente (`failed`, necesitan que el agente actúe). Una visita
// puede estar sincronizada con fotos todavía por subir.
import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import 'database.dart';

enum VisitSyncStatus { pending, synced, rejected }

@immutable
class VisitSummary {
  const VisitSummary({
    required this.id,
    required this.templateName,
    required this.capturedAt,
    required this.status,
    required this.attachments,
    required this.pendingUploads,
    this.failedUploads = 0,
  });

  final String id;

  /// Nombre de la plantilla, si está en la caché local.
  final String? templateName;
  final DateTime capturedAt;
  final VisitSyncStatus status;
  final int attachments;

  /// Por subir: se reintentan solos.
  final int pendingUploads;

  /// Fallidos de forma permanente: hay que reintentarlos a mano.
  final int failedUploads;
}

class VisitStatusRepository {
  const VisitStatusRepository(this.db);

  final AppDatabase db;

  /// Las visitas más recientes de [orgId], con su estado. Cinco consultas en
  /// total, sean 1 o [limit] visitas.
  Future<List<VisitSummary>> recentVisits({required String orgId, int limit = 50}) async {
    final visits =
        await (db.select(db.visits)
              ..where((t) => t.orgId.equals(orgId) & t.deletedAt.isNull())
              ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)])
              ..limit(limit))
            .get();
    if (visits.isEmpty) return const [];
    final visitIds = [for (final v in visits) v.id];

    final attachments = await (db.select(db.visitAttachments)..where((t) => t.visitId.isIn(visitIds))).get();
    final attachmentsByVisit = <String, List<VisitAttachment>>{};
    for (final a in attachments) {
      attachmentsByVisit.putIfAbsent(a.visitId, () => []).add(a);
    }
    final visitOfAttachment = {for (final a in attachments) a.id: a.visitId};

    final ops =
        await (db.select(db.outboxOps)
              ..where((t) => t.entityId.isIn([...visitIds, ...visitOfAttachment.keys])))
            .get();
    final opStatesByVisit = <String, Set<String>>{};
    for (final op in ops) {
      final visitId = op.entity == 'visit' ? op.entityId : visitOfAttachment[op.entityId];
      if (visitId != null) opStatesByVisit.putIfAbsent(visitId, () => {}).add(op.state);
    }

    final shas = {for (final a in attachments) a.sha256};
    final uploadState = {
      for (final row in await (db.select(db.attachmentQueue)..where((t) => t.sha256.isIn(shas))).get())
        row.sha256: row.state,
    };

    final templateNames = {
      for (final row
          in await (db.select(
            db.formTemplateVersions,
          )..where((t) => t.id.isIn({for (final v in visits) v.templateVersionId}))).get())
        row.id: row.name,
    };

    return [
      for (final visit in visits)
        VisitSummary(
          id: visit.id,
          templateName: templateNames[visit.templateVersionId],
          capturedAt: visit.capturedAt,
          status: switch (opStatesByVisit[visit.id] ?? const <String>{}) {
            final states when states.contains('quarantine') => VisitSyncStatus.rejected,
            final states when states.isNotEmpty => VisitSyncStatus.pending,
            _ => VisitSyncStatus.synced,
          },
          attachments: attachmentsByVisit[visit.id]?.length ?? 0,
          pendingUploads: _countIn(attachmentsByVisit[visit.id], uploadState, const {'pending', 'uploading'}),
          failedUploads: _countIn(attachmentsByVisit[visit.id], uploadState, const {'failed'}),
        ),
    ];
  }

  static int _countIn(List<VisitAttachment>? attachments, Map<String, String> uploadState, Set<String> states) =>
      (attachments ?? const <VisitAttachment>[]).where((a) => states.contains(uploadState[a.sha256])).length;
}
