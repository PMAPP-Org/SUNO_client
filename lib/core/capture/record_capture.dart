// Guardado de un registro capturado (Paso 22, tarea 5) — la lógica, sin UI.
//
// Un registro se guarda **entero y offline** en una sola transacción local
// (`AppDatabase.saveRecordCapture`): el registro, sus adjuntos, las operaciones
// de outbox y la cola de subida. La UI lo ve al instante (optimista, doc 08
// §4.2 "FASE OFFLINE"); la red llega después, por el `SyncEngine` y el
// `AttachmentUploadService`.
//
// Reglas que decide este archivo:
//
// - **Solo viajan las respuestas de campos visibles.** El servidor admitiría
//   las de campos ocultos (bien tipadas), pero guardarlas sería guardar lo que
//   el agente dejó de ver; y para foto/firma, subir bytes que nadie pidió.
// - **Solo se guardan los adjuntos referenciados**: los de los campos
//   foto/firma visibles y las fotos adicionales. Una foto repetida antes de
//   guardar sustituye a la anterior, que no llega a crearse.
// - **Orden de las operaciones**: el registro primero y luego sus adjuntos, en
//   el orden de la plantilla; el servidor rechaza un adjunto cuyo registro no
//   existe todavía.
import 'dart:convert';

import 'package:drift/drift.dart' show BooleanExpressionOperators, InsertMode, Value;
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../data/local/database.dart';
import '../forms/answers.dart';
import '../forms/form_definition.dart';
import '../location/location_source.dart';

export '../forms/answers.dart' show keptAnswers;

/// Un archivo capturado en este registro y todavía no guardado.
@immutable
class PendingAttachment {
  const PendingAttachment({
    required this.id,
    required this.sha256,
    required this.localPath,
    required this.mime,
    required this.role,
    required this.capturedAt,
  });

  /// `record_attachment.id` (UUIDv7, generado en el dispositivo): es lo que se
  /// guarda en `answers` para un campo foto/firma.
  final String id;
  final String sha256;
  final String localPath;
  final String mime;

  /// `foto` | `firma`.
  final String role;
  final DateTime capturedAt;
}

/// Quién captura, desde qué dispositivo y para qué organización.
@immutable
class CaptureIdentity {
  const CaptureIdentity({required this.orgId, required this.userId, required this.deviceId, this.roles = const []});
  final String orgId;
  final String userId;
  final String deviceId;

  /// Roles del usuario en la organización (`UserProfile.roles`).
  final List<String> roles;
}

/// Costos, etapa 1: la tarea del cronograma y el % acumulado que reporta un
/// registro. Viajan siempre juntos (`task_id` + `progress_pct`).
@immutable
class TaskProgress {
  const TaskProgress({required this.taskId, required this.pct});
  final String taskId;
  final double pct;
}

class RecordCapture {
  RecordCapture({required this.db, String Function()? idGenerator, DateTime Function()? clock})
    : _newId = idGenerator ?? (() => const Uuid().v7()),
      _now = clock ?? DateTime.now;

  final AppDatabase db;
  final String Function() _newId;
  final DateTime Function() _now;

  String newAttachmentId() => _newId();

  /// Guarda el registro. Devuelve su `id`.
  ///
  /// [captured] son los archivos capturados para los campos foto/firma, por
  /// `id`; [extraPhotos], las fotos adicionales fuera de la plantilla.
  Future<String> save({
    required CaptureIdentity identity,
    required String templateVersionId,
    required FormDefinition definition,
    required Map<String, Object?> answers,
    required Map<String, PendingAttachment> captured,
    List<PendingAttachment> extraPhotos = const [],
    LocationFix? fix,
    String? assignmentId,
    TaskProgress? progress,
  }) async {
    final recordId = _newId();
    final now = _now().toUtc();

    final kept = keptAnswers(definition, answers);
    final attachments = [
      for (final (field, value) in answeredFields(definition, kept))
        if (field is AttachmentRefFieldDef && captured[value] != null) captured[value]!,
      ...extraPhotos,
    ];

    final payload = <String, Object?>{
      'id': recordId,
      'template_version_id': templateVersionId,
      'answers': kept,
      'captured_at': now.toIso8601String(),
      'device_id': identity.deviceId,
      'assignment_id': ?assignmentId,
      // Costos, etapa 1. Sin tarea no se envían: un servidor anterior los rechazaría.
      if (progress != null) ...{'task_id': progress.taskId, 'progress_pct': progress.pct},
      if (fix != null) ...{
        'lat': fix.lat,
        'lon': fix.lon,
        'accuracy_m': fix.accuracyM,
        if (fix.altitudeM != null) 'altitude_m': fix.altitudeM,
      },
    };

    await db.saveRecordCapture(
      record: RecordsCompanion.insert(
        id: recordId,
        orgId: identity.orgId,
        // `INITIAL_VERSION` del servidor; el valor autoritativo llega tras el push.
        version: 1,
        templateVersionId: templateVersionId,
        answersJson: jsonEncode(kept),
        lat: Value(fix?.lat),
        lon: Value(fix?.lon),
        accuracyM: Value(fix?.accuracyM),
        altitudeM: Value(fix?.altitudeM),
        capturedAt: now,
        deviceId: identity.deviceId,
        createdBy: identity.userId,
        assignmentId: Value(assignmentId),
        taskId: Value(progress?.taskId),
        progressPct: Value(progress?.pct),
      ),
      attachments: [
        for (final (order, a) in attachments.indexed)
          RecordAttachmentsCompanion.insert(
            id: a.id,
            orgId: identity.orgId,
            recordId: recordId,
            sha256: a.sha256,
            role: a.role,
            capturedAt: a.capturedAt.toUtc(),
            position: order,
          ),
      ],
      outboxOps: [
        _op(entity: 'record', entityId: recordId, payload: payload, now: now),
        for (final (order, a) in attachments.indexed) _attachmentOp(recordId, a, order, now),
      ],
      uploads: [
        for (final a in attachments)
          AttachmentQueueCompanion.insert(
            sha256: a.sha256,
            localPath: a.localPath,
            state: 'pending',
            createdAt: now,
            mime: Value(a.mime),
          ),
      ],
    );
    return recordId;
  }

  /// Edita un registro ya guardado (Fase A). Viaja como `update` con solo lo
  /// que cambió (respuestas y/o ubicación) y los adjuntos nuevos como altas.
  ///
  /// [captured] son los archivos capturados **en esta edición**; una foto
  /// que no se repitió conserva su adjunto. [fix] `null` mantiene la
  /// ubicación.
  ///
  /// El `base_version` es la versión que el agente estaba viendo más las
  /// ediciones suyas que aún no se aplicaron: así varias ediciones seguidas
  /// sin red encadenan bien, y si otro cambió el registro en el servidor el
  /// CAS lo detecta y la revisión muestra las dos versiones.
  Future<RecordChange> update({
    required CaptureIdentity identity,
    required String recordId,
    required FormDefinition definition,
    required Map<String, Object?> answers,
    required Map<String, PendingAttachment> captured,
    List<PendingAttachment> extraPhotos = const [],
    LocationFix? fix,

    /// Costos, etapa 1. `null`: no se toca. `(value: null)`: desvincular.
    /// `(value: TaskProgress(...))`: poner o cambiar la tarea y su %.
    ({TaskProgress? value})? progress,
  }) => db.transaction(() async {
    final record = await _editable(identity, recordId);
    if (record is! Record) return record as RecordChange;
    final now = _now().toUtc();

    final kept = keptAnswers(definition, answers);
    final link = progress?.value;
    final progressChanged = progress != null && (link?.taskId != record.taskId || link?.pct != record.progressPct);
    final changed = <String, Object?>{
      if (jsonEncode(kept) != record.answersJson) 'answers': kept,
      if (fix != null) ...{'lat': fix.lat, 'lon': fix.lon, 'accuracy_m': fix.accuracyM, 'altitude_m': fix.altitudeM},
      // El servidor exige el par completo, también en `update`.
      if (progressChanged) ...{'task_id': link?.taskId, 'progress_pct': link?.pct},
    };
    final attachments = [
      for (final (field, value) in answeredFields(definition, kept))
        if (field is AttachmentRefFieldDef && captured[value] != null) captured[value]!,
      ...extraPhotos,
    ];
    if (changed.isEmpty && attachments.isEmpty) return RecordChange.unchanged;

    final existing = await (db.select(db.recordAttachments)..where((t) => t.recordId.equals(recordId))).get();
    final firstPosition = existing.isEmpty ? 0 : existing.map((a) => a.position).reduce((a, b) => a > b ? a : b) + 1;

    if (changed.isNotEmpty) {
      await (db.update(db.records)..where((t) => t.id.equals(recordId))).write(
        RecordsCompanion(
          answersJson: Value(jsonEncode(kept)),
          lat: fix == null ? const Value.absent() : Value(fix.lat),
          lon: fix == null ? const Value.absent() : Value(fix.lon),
          accuracyM: fix == null ? const Value.absent() : Value(fix.accuracyM),
          altitudeM: fix == null ? const Value.absent() : Value(fix.altitudeM),
          taskId: progressChanged ? Value(link?.taskId) : const Value.absent(),
          progressPct: progressChanged ? Value(link?.pct) : const Value.absent(),
        ),
      );
      await db
          .into(db.outboxOps)
          .insert(
            _op(
              entity: 'record',
              entityId: recordId,
              opType: 'update',
              baseVersion: await _baseVersion(record),
              payload: {'id': recordId, ...changed},
              now: now,
            ),
          );
    }
    for (final (index, a) in attachments.indexed) {
      final order = firstPosition + index;
      await db
          .into(db.recordAttachments)
          .insert(
            RecordAttachmentsCompanion.insert(
              id: a.id,
              orgId: identity.orgId,
              recordId: recordId,
              sha256: a.sha256,
              role: a.role,
              capturedAt: a.capturedAt.toUtc(),
              position: order,
            ),
          );
      await db.into(db.outboxOps).insert(_attachmentOp(recordId, a, order, now));
      await db
          .into(db.attachmentQueue)
          .insert(
            AttachmentQueueCompanion.insert(
              sha256: a.sha256,
              localPath: a.localPath,
              state: 'pending',
              createdAt: now,
              mime: Value(a.mime),
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
    return RecordChange.saved;
  });

  /// Borra un registro (Fase A): sale de la lista ya y viaja como `delete`.
  /// Si su alta aún no se envió, viajan las dos en orden: el servidor la crea
  /// y la borra, y queda constancia (borrado lógico, `deleted_at`).
  Future<RecordChange> delete({required CaptureIdentity identity, required String recordId}) => db.transaction(() async {
    final record = await _editable(identity, recordId);
    if (record is! Record) return record as RecordChange;
    final now = _now().toUtc();
    await (db.update(db.records)..where((t) => t.id.equals(recordId))).write(RecordsCompanion(deletedAt: Value(now)));
    await db
        .into(db.outboxOps)
        .insert(
          _op(
            entity: 'record',
            entityId: recordId,
            opType: 'delete',
            baseVersion: await _baseVersion(record),
            payload: {'id': recordId},
            now: now,
          ),
        );
    return RecordChange.saved;
  });

  /// El registro, si [identity] puede editarla; si no, el motivo.
  Future<Object> _editable(CaptureIdentity identity, String recordId) async {
    final record = await (db.select(
      db.records,
    )..where((t) => t.id.equals(recordId) & t.orgId.equals(identity.orgId) & t.deletedAt.isNull())).getSingleOrNull();
    if (record == null) return RecordChange.notFound;
    if (!canEdit(record, userId: identity.userId, roles: identity.roles)) return RecordChange.notAllowed;
    final quarantined =
        await (db.select(db.outboxOps)
              ..where((t) => t.entityId.equals(recordId) & t.state.equals('quarantine'))
              ..limit(1))
            .get();
    // Con algo en revisión, una edición nueva quedaría detrás sin poder
    // salir: primero se resuelve la revisión.
    if (quarantined.isNotEmpty) return RecordChange.needsReview;
    return record;
  }

  /// La versión que el agente estaba viendo más sus ediciones aún sin aplicar.
  Future<int> _baseVersion(Record record) async {
    final pendingEdits =
        await (db.select(db.outboxOps)..where(
              (t) => t.entity.equals('record') & t.entityId.equals(record.id) & t.opType.isIn(const ['update', 'delete']),
            ))
            .get();
    return record.version + pendingEdits.length;
  }

  OutboxOpsCompanion _attachmentOp(String recordId, PendingAttachment a, int order, DateTime now) => _op(
    entity: 'record_attachment',
    entityId: a.id,
    payload: {
      'id': a.id,
      'record_id': recordId,
      'sha256': a.sha256,
      'role': a.role,
      'caption': null,
      'captured_at': a.capturedAt.toUtc().toIso8601String(),
      'order': order,
    },
    now: now,
  );

  OutboxOpsCompanion _op({
    required String entity,
    required String entityId,
    required Map<String, Object?> payload,
    required DateTime now,
    String opType = 'create',
    int? baseVersion,
  }) => OutboxOpsCompanion.insert(
    opUuid: _newId(),
    entity: entity,
    entityId: entityId,
    opType: opType,
    baseVersion: Value(baseVersion),
    payloadJson: jsonEncode(payload),
    state: 'pending',
    createdAt: now,
  );
}

/// Resultado de editar o borrar un registro.
enum RecordChange {
  saved,

  /// Nada que guardar: las respuestas y la ubicación son las mismas.
  unchanged,
  notFound,

  /// No es un registro de este agente.
  notAllowed,

  /// Tiene algo en "Para revisar": se resuelve primero.
  needsReview,
}

/// ¿Puede el usuario editar o borrar [record]? Su autor o supervisión: la
/// misma regla que impone el servidor (`can_modify_record`, ISO 27001
/// A.5.15). Aquí solo decide qué botones se muestran; quien autoriza es el
/// servidor, que rechaza con `forbidden` lo que no corresponda.
bool canEdit(Record record, {required String userId, required List<String> roles}) =>
    record.createdBy == userId || roles.any(supervisionRoles.contains);

/// Roles que supervisan el trabajo de campo (`SUPERVISION_ROLES` del servidor).
const supervisionRoles = {'OWNER', 'ADMIN', 'SUPERVISOR'};
