// Estado de sincronización de cada registro, para el agente (Paso 22, tarea 6).
//
// Se deriva de lo que ya hay en la BD local, sin estado propio:
// - **pendiente**: alguna operación del registro o de sus adjuntos sigue en el
//   outbox (`pending`/`inflight`);
// - **rechazado**: alguna está en `quarantine` (se revisa en la pantalla de
//   conflictos, Paso 23);
// - **sincronizado**: ninguna queda en el outbox.
// Aparte, el estado de sus adjuntos en `AttachmentQueue` (Paso 18): cuántos
// están por subir (`pending`/`uploading`, se suben solos) y cuántos fallaron
// de forma permanente (`failed`, necesitan que el agente actúe). Un registro
// puede estar sincronizado con fotos todavía por subir.
//
// Fase A: búsqueda (por plantilla y por lo respondido) y el detalle de un
// registro, para que el agente encuentre y revise lo que capturó.
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import '../../core/forms/geometry.dart';
import '../../core/schedule/quantity_rows.dart';
import 'database.dart';
import 'schedule_task_repository.dart';

enum RecordSyncStatus { pending, synced, rejected }

/// Un registro para el mapa: su punto y sus geometrías (GeoJSON, WGS84).
typedef MapRecord = ({RecordSummary summary, double lat, double lon, List<Map<String, Object?>> geometries});

@immutable
class RecordSummary {
  const RecordSummary({
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
  final RecordSyncStatus status;
  final int attachments;

  /// Por subir: se reintentan solos.
  final int pendingUploads;

  /// Fallidos de forma permanente: hay que reintentarlos a mano.
  final int failedUploads;
}

/// Un adjunto del registro y dónde está su archivo, si sigue en el teléfono.
@immutable
class RecordAttachmentView {
  const RecordAttachmentView({required this.id, required this.role, this.localPath, this.uploadState});

  final String id;
  final String role;

  /// `null` si el archivo no está en este dispositivo (p. ej. llegó por pull).
  final String? localPath;

  /// `pending` | `uploading` | `uploaded` | `failed`; `null` sin cola local.
  final String? uploadState;
}

@immutable
class RecordDetail {
  const RecordDetail({
    required this.record,
    required this.summary,
    required this.attachments,
    this.quantities = const [],
  });

  final Record record;
  final RecordSummary summary;
  final List<RecordAttachmentView> attachments;

  /// Costos, pieza 4b: las cantidades del registro, con los datos del ítem y la etiqueta
  /// de la ubicación que el teléfono conozca.
  final List<QuantityLine> quantities;

  Map<String, dynamic> get answers => jsonDecode(record.answersJson) as Map<String, dynamic>;
}

class RecordStatusRepository {
  const RecordStatusRepository(this.db);

  final AppDatabase db;

  /// Los registros más recientes de [orgId], con su estado. Cinco consultas en
  /// total, sean 1 o [limit] registros.
  ///
  /// Con [query], solo las que lo contienen en el nombre de la plantilla o en
  /// alguna respuesta (sin distinguir mayúsculas ni tildes). La búsqueda
  /// recorre en memoria los registros de la organización: en un teléfono son
  /// cientos o pocos miles, y así no depende de cómo se guarda `answers`.
  Future<List<RecordSummary>> recentRecords({required String orgId, int limit = 50, String? query}) async {
    final needle = _fold(query?.trim() ?? '');
    final select = db.select(db.records)
      ..where((t) => t.orgId.equals(orgId) & t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)]);
    if (needle.isEmpty) select.limit(limit);
    var records = await select.get();
    if (records.isEmpty) return const [];

    final templateNames = await _templateNames(records);
    if (needle.isNotEmpty) {
      records = records.where((v) => _matches(v, templateNames[v.templateVersionId], needle)).take(limit).toList();
    }
    return _summarize(records, templateNames);
  }

  /// Los registros de [orgId] con ubicación, para el mapa (Fase B). Hasta
  /// [limit], las más recientes: miles de marcadores no se leen en un
  /// teléfono, y la búsqueda de la lista sigue llegando a todas.
  ///
  /// Con cada registro, las líneas y polígonos de sus respuestas (Fase C), para
  /// dibujarlos.
  Future<List<MapRecord>> mapRecords({required String orgId, int limit = 2000}) async {
    final records =
        await (db.select(db.records)
              ..where((t) => t.orgId.equals(orgId) & t.deletedAt.isNull() & t.lat.isNotNull() & t.lon.isNotNull())
              ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)])
              ..limit(limit))
            .get();
    final summaries = await _summarize(records, await _templateNames(records));
    return [
      for (final (index, record) in records.indexed)
        (summary: summaries[index], lat: record.lat!, lon: record.lon!, geometries: _geometries(record.answersJson)),
    ];
  }

  static List<Map<String, Object?>> _geometries(String answersJson) {
    final Object? answers;
    try {
      answers = jsonDecode(answersJson);
    } on FormatException {
      return const [];
    }
    if (answers is! Map<String, Object?>) return const [];
    // Las respuestas y cada fila de un grupo son contenedores de campos, no
    // geometrías: un campo de texto llamado `type` con valor "Polygon" no
    // convierte toda la fila en un polígono.
    Iterable<Map<String, Object?>> collect(Map<String, Object?> fields) sync* {
      for (final value in fields.values) {
        if (value is Map<String, Object?>) {
          if (kindOf(value) != null) yield value;
        } else if (value is List<Object?>) {
          for (final row in value) {
            if (row is Map<String, Object?>) yield* collect(row);
          }
        }
      }
    }

    return collect(answers).toList();
  }

  /// Un registro con su estado, sus adjuntos y sus cantidades; `null` si no existe en [orgId]
  /// o está borrado.
  Future<RecordDetail?> detail({required String orgId, required String recordId}) async {
    final record = await (db.select(
      db.records,
    )..where((t) => t.orgId.equals(orgId) & t.id.equals(recordId) & t.deletedAt.isNull())).getSingleOrNull();
    if (record == null) return null;
    final summary = (await _summarize([record], await _templateNames([record]))).single;

    final attachments =
        await (db.select(db.recordAttachments)
              ..where((t) => t.recordId.equals(recordId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get();
    final queue = {
      for (final row in await (db.select(
        db.attachmentQueue,
      )..where((t) => t.sha256.isIn({for (final a in attachments) a.sha256}))).get())
        row.sha256: row,
    };
    final stored = decodeQuantities(record.quantitiesJson);
    final schedule = ScheduleTaskRepository(db);
    final items = await schedule.knownItems({for (final row in stored) row['item_id']! as String});
    final locationLabels = await schedule.locationLabels({
      for (final row in stored)
        if (row['location_id'] is String) row['location_id']! as String,
    });
    return RecordDetail(
      record: record,
      summary: summary,
      attachments: [
        for (final a in attachments)
          RecordAttachmentView(
            id: a.id,
            role: a.role,
            localPath: queue[a.sha256]?.localPath,
            uploadState: queue[a.sha256]?.state,
          ),
      ],
      quantities: [
        for (final row in stored)
          QuantityLine.fromStored(row, item: items[row['item_id']], locationLabel: locationLabels[row['location_id']]),
      ],
    );
  }

  Future<Map<String, String?>> _templateNames(List<Record> records) async => {
    for (final row in await (db.select(
      db.formTemplateVersions,
    )..where((t) => t.id.isIn({for (final v in records) v.templateVersionId}))).get())
      row.id: row.name,
  };

  Future<List<RecordSummary>> _summarize(List<Record> records, Map<String, String?> templateNames) async {
    if (records.isEmpty) return const [];
    final recordIds = [for (final v in records) v.id];

    final attachments = await (db.select(db.recordAttachments)..where((t) => t.recordId.isIn(recordIds))).get();
    final attachmentsByRecord = <String, List<RecordAttachment>>{};
    for (final a in attachments) {
      attachmentsByRecord.putIfAbsent(a.recordId, () => []).add(a);
    }
    final recordOfAttachment = {for (final a in attachments) a.id: a.recordId};

    final ops = await (db.select(
      db.outboxOps,
    )..where((t) => t.entityId.isIn([...recordIds, ...recordOfAttachment.keys]))).get();
    final opStatesByRecord = <String, Set<String>>{};
    for (final op in ops) {
      final recordId = op.entity == 'record' ? op.entityId : recordOfAttachment[op.entityId];
      if (recordId != null) opStatesByRecord.putIfAbsent(recordId, () => {}).add(op.state);
    }

    final shas = {for (final a in attachments) a.sha256};
    final uploadState = {
      for (final row in await (db.select(db.attachmentQueue)..where((t) => t.sha256.isIn(shas))).get())
        row.sha256: row.state,
    };

    return [
      for (final record in records)
        RecordSummary(
          id: record.id,
          templateName: templateNames[record.templateVersionId],
          capturedAt: record.capturedAt,
          status: switch (opStatesByRecord[record.id] ?? const <String>{}) {
            final states when states.contains('quarantine') => RecordSyncStatus.rejected,
            final states when states.isNotEmpty => RecordSyncStatus.pending,
            _ => RecordSyncStatus.synced,
          },
          attachments: attachmentsByRecord[record.id]?.length ?? 0,
          pendingUploads: _countIn(attachmentsByRecord[record.id], uploadState, const {'pending', 'uploading'}),
          failedUploads: _countIn(attachmentsByRecord[record.id], uploadState, const {'failed'}),
        ),
    ];
  }

  static int _countIn(List<RecordAttachment>? attachments, Map<String, String> uploadState, Set<String> states) =>
      (attachments ?? const <RecordAttachment>[]).where((a) => states.contains(uploadState[a.sha256])).length;

  /// Solo los **valores** de las respuestas: buscar "altura" no debe
  /// encontrar todos los registros por tener un campo `altura_cm`.
  static bool _matches(Record record, String? templateName, String needle) {
    if (templateName != null && _fold(templateName).contains(needle)) return true;
    final Object? answers;
    try {
      answers = jsonDecode(record.answersJson);
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
