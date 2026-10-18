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
//
// Fase A: búsqueda (por plantilla y por lo respondido) y el detalle de una
// visita, para que el agente encuentre y revise lo que capturó.
import 'dart:convert';

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

/// Un adjunto de la visita y dónde está su archivo, si sigue en el teléfono.
@immutable
class VisitAttachmentView {
  const VisitAttachmentView({required this.id, required this.role, this.localPath, this.uploadState});

  final String id;
  final String role;

  /// `null` si el archivo no está en este dispositivo (p. ej. llegó por pull).
  final String? localPath;

  /// `pending` | `uploading` | `uploaded` | `failed`; `null` sin cola local.
  final String? uploadState;
}

@immutable
class VisitDetail {
  const VisitDetail({required this.visit, required this.summary, required this.attachments});

  final Visit visit;
  final VisitSummary summary;
  final List<VisitAttachmentView> attachments;

  Map<String, dynamic> get answers => jsonDecode(visit.answersJson) as Map<String, dynamic>;
}

class VisitStatusRepository {
  const VisitStatusRepository(this.db);

  final AppDatabase db;

  /// Las visitas más recientes de [orgId], con su estado. Cinco consultas en
  /// total, sean 1 o [limit] visitas.
  ///
  /// Con [query], solo las que lo contienen en el nombre de la plantilla o en
  /// alguna respuesta (sin distinguir mayúsculas ni tildes). La búsqueda
  /// recorre en memoria las visitas de la organización: en un teléfono son
  /// cientos o pocos miles, y así no depende de cómo se guarda `answers`.
  Future<List<VisitSummary>> recentVisits({required String orgId, int limit = 50, String? query}) async {
    final needle = _fold(query?.trim() ?? '');
    final select = db.select(db.visits)
      ..where((t) => t.orgId.equals(orgId) & t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)]);
    if (needle.isEmpty) select.limit(limit);
    var visits = await select.get();
    if (visits.isEmpty) return const [];

    final templateNames = await _templateNames(visits);
    if (needle.isNotEmpty) {
      visits = visits
          .where((v) => _matches(v, templateNames[v.templateVersionId], needle))
          .take(limit)
          .toList();
    }
    return _summarize(visits, templateNames);
  }

  /// Las visitas de [orgId] con ubicación, para el mapa (Fase B). Hasta
  /// [limit], las más recientes: miles de marcadores no se leen en un
  /// teléfono, y la búsqueda de la lista sigue llegando a todas.
  Future<List<({VisitSummary summary, double lat, double lon})>> mapVisits({
    required String orgId,
    int limit = 2000,
  }) async {
    final visits =
        await (db.select(db.visits)
              ..where((t) => t.orgId.equals(orgId) & t.deletedAt.isNull() & t.lat.isNotNull() & t.lon.isNotNull())
              ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)])
              ..limit(limit))
            .get();
    final summaries = await _summarize(visits, await _templateNames(visits));
    return [
      for (final (index, visit) in visits.indexed) (summary: summaries[index], lat: visit.lat!, lon: visit.lon!),
    ];
  }

  /// Una visita con su estado y sus adjuntos; `null` si no existe en [orgId]
  /// o está borrada.
  Future<VisitDetail?> detail({required String orgId, required String visitId}) async {
    final visit =
        await (db.select(db.visits)
              ..where((t) => t.orgId.equals(orgId) & t.id.equals(visitId) & t.deletedAt.isNull()))
            .getSingleOrNull();
    if (visit == null) return null;
    final summary = (await _summarize([visit], await _templateNames([visit]))).single;

    final attachments =
        await (db.select(db.visitAttachments)
              ..where((t) => t.visitId.equals(visitId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get();
    final queue = {
      for (final row
          in await (db.select(
            db.attachmentQueue,
          )..where((t) => t.sha256.isIn({for (final a in attachments) a.sha256}))).get())
        row.sha256: row,
    };
    return VisitDetail(
      visit: visit,
      summary: summary,
      attachments: [
        for (final a in attachments)
          VisitAttachmentView(
            id: a.id,
            role: a.role,
            localPath: queue[a.sha256]?.localPath,
            uploadState: queue[a.sha256]?.state,
          ),
      ],
    );
  }

  Future<Map<String, String?>> _templateNames(List<Visit> visits) async => {
    for (final row
        in await (db.select(
          db.formTemplateVersions,
        )..where((t) => t.id.isIn({for (final v in visits) v.templateVersionId}))).get())
      row.id: row.name,
  };

  Future<List<VisitSummary>> _summarize(List<Visit> visits, Map<String, String?> templateNames) async {
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

  /// Solo los **valores** de las respuestas: buscar "altura" no debe
  /// encontrar todas las visitas por tener un campo `altura_cm`.
  static bool _matches(Visit visit, String? templateName, String needle) {
    if (templateName != null && _fold(templateName).contains(needle)) return true;
    final Object? answers;
    try {
      answers = jsonDecode(visit.answersJson);
    } on FormatException {
      return false;
    }
    return _values(answers).any((value) => _fold(value).contains(needle));
  }

  static Iterable<String> _values(Object? node) sync* {
    switch (node) {
      case final Map<String, dynamic> map:
        for (final value in map.values) {
          yield* _values(value);
        }
      case final List<dynamic> list:
        for (final value in list) {
          yield* _values(value);
        }
      case null:
        break;
      default:
        yield '$node';
    }
  }

  /// Minúsculas y sin tildes: "Peña" encuentra "pena" y al revés.
  static String _fold(String text) {
    const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
    const to = 'aaaaaeeeeiiiiooooouuuunc';
    final lower = text.toLowerCase();
    final buffer = StringBuffer();
    for (final char in lower.split('')) {
      final index = from.indexOf(char);
      buffer.write(index < 0 ? char : to[index]);
    }
    return buffer.toString();
  }
}
