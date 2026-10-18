// Guardado de una visita capturada (Paso 22, tarea 5) — la lógica, sin UI.
//
// Una visita se guarda **entera y offline** en una sola transacción local
// (`AppDatabase.saveVisitCapture`): la visita, sus adjuntos, las operaciones
// de outbox y la cola de subida. La UI la ve al instante (optimista, doc 08
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
// - **Orden de las operaciones**: la visita primero y luego sus adjuntos, en
//   el orden de la plantilla; el servidor rechaza un adjunto cuya visita no
//   existe todavía.
import 'dart:convert';

import 'package:drift/drift.dart' show BooleanExpressionOperators, InsertMode, Value;
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../data/local/database.dart';
import '../forms/answers.dart';
import '../forms/form_definition.dart';
import '../location/location_source.dart';

/// Un archivo capturado en esta visita y todavía no guardado.
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

  /// `visit_attachment.id` (UUIDv7, generado en el dispositivo): es lo que se
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
  const CaptureIdentity({
    required this.orgId,
    required this.userId,
    required this.deviceId,
    this.roles = const [],
  });
  final String orgId;
  final String userId;
  final String deviceId;

  /// Roles del usuario en la organización (`UserProfile.roles`).
  final List<String> roles;
}

class VisitCapture {
  VisitCapture({required this.db, String Function()? idGenerator, DateTime Function()? clock})
    : _newId = idGenerator ?? (() => const Uuid().v7()),
      _now = clock ?? DateTime.now;

  final AppDatabase db;
  final String Function() _newId;
  final DateTime Function() _now;

  String newAttachmentId() => _newId();

  /// Guarda la visita. Devuelve su `id`.
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
  }) async {
    final visitId = _newId();
    final now = _now().toUtc();

    final kept = keptAnswers(definition, answers);
    final attachments = [
      for (final field in definition.fields)
        if (field is AttachmentRefFieldDef && captured[kept[field.key]] != null) captured[kept[field.key]]!,
      ...extraPhotos,
    ];

    final payload = <String, Object?>{
      'id': visitId,
      'template_version_id': templateVersionId,
      'answers': kept,
      'captured_at': now.toIso8601String(),
      'device_id': identity.deviceId,
      'assignment_id': ?assignmentId,
      if (fix != null) ...{
        'lat': fix.lat,
        'lon': fix.lon,
        'accuracy_m': fix.accuracyM,
        if (fix.altitudeM != null) 'altitude_m': fix.altitudeM,
      },
    };

    await db.saveVisitCapture(
      visit: VisitsCompanion.insert(
        id: visitId,
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
      ),
      attachments: [
        for (final (order, a) in attachments.indexed)
          VisitAttachmentsCompanion.insert(
            id: a.id,
            orgId: identity.orgId,
            visitId: visitId,
            sha256: a.sha256,
            role: a.role,
            capturedAt: a.capturedAt.toUtc(),
            position: order,
          ),
      ],
      outboxOps: [
        _op(entity: 'visit', entityId: visitId, payload: payload, now: now),
        for (final (order, a) in attachments.indexed) _attachmentOp(visitId, a, order, now),
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
    return visitId;
  }

  /// Edita una visita ya guardada (Fase A). Viaja como `update` con solo lo
  /// que cambió (respuestas y/o ubicación) y los adjuntos nuevos como altas.
  ///
  /// [captured] son los archivos capturados **en esta edición**; una foto
  /// que no se repitió conserva su adjunto. [fix] `null` mantiene la
  /// ubicación.
  ///
  /// El `base_version` es la versión que el agente estaba viendo más las
  /// ediciones suyas que aún no se aplicaron: así varias ediciones seguidas
  /// sin red encadenan bien, y si otro cambió la visita en el servidor el
  /// CAS lo detecta y la revisión muestra las dos versiones.
  Future<VisitChange> update({
    required CaptureIdentity identity,
    required String visitId,
    required FormDefinition definition,
    required Map<String, Object?> answers,
    required Map<String, PendingAttachment> captured,
    List<PendingAttachment> extraPhotos = const [],
    LocationFix? fix,
  }) => db.transaction(() async {
    final visit = await _editable(identity, visitId);
    if (visit is! Visit) return visit as VisitChange;
    final now = _now().toUtc();

    final kept = keptAnswers(definition, answers);
    final changed = <String, Object?>{
      if (jsonEncode(kept) != visit.answersJson) 'answers': kept,
      if (fix != null) ...{
        'lat': fix.lat,
        'lon': fix.lon,
        'accuracy_m': fix.accuracyM,
        'altitude_m': fix.altitudeM,
      },
    };
    final attachments = [
      for (final field in definition.fields)
        if (field is AttachmentRefFieldDef && captured[kept[field.key]] != null) captured[kept[field.key]]!,
      ...extraPhotos,
    ];
    if (changed.isEmpty && attachments.isEmpty) return VisitChange.unchanged;

    final existing = await (db.select(db.visitAttachments)..where((t) => t.visitId.equals(visitId))).get();
    final firstPosition = existing.isEmpty ? 0 : existing.map((a) => a.position).reduce((a, b) => a > b ? a : b) + 1;

    if (changed.isNotEmpty) {
      await (db.update(db.visits)..where((t) => t.id.equals(visitId))).write(
        VisitsCompanion(
          answersJson: Value(jsonEncode(kept)),
          lat: fix == null ? const Value.absent() : Value(fix.lat),
          lon: fix == null ? const Value.absent() : Value(fix.lon),
          accuracyM: fix == null ? const Value.absent() : Value(fix.accuracyM),
          altitudeM: fix == null ? const Value.absent() : Value(fix.altitudeM),
        ),
      );
      await db
          .into(db.outboxOps)
          .insert(
            _op(
              entity: 'visit',
              entityId: visitId,
              opType: 'update',
              baseVersion: await _baseVersion(visit),
              payload: {'id': visitId, ...changed},
              now: now,
            ),
          );
    }
    for (final (index, a) in attachments.indexed) {
      final order = firstPosition + index;
      await db
          .into(db.visitAttachments)
          .insert(
            VisitAttachmentsCompanion.insert(
              id: a.id,
              orgId: identity.orgId,
              visitId: visitId,
              sha256: a.sha256,
              role: a.role,
              capturedAt: a.capturedAt.toUtc(),
              position: order,
            ),
          );
      await db.into(db.outboxOps).insert(_attachmentOp(visitId, a, order, now));
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
    return VisitChange.saved;
  });

  /// Borra una visita (Fase A): sale de la lista ya y viaja como `delete`.
  /// Si su alta aún no se envió, viajan las dos en orden: el servidor la crea
  /// y la borra, y queda constancia (borrado lógico, `deleted_at`).
  Future<VisitChange> delete({required CaptureIdentity identity, required String visitId}) =>
      db.transaction(() async {
        final visit = await _editable(identity, visitId);
        if (visit is! Visit) return visit as VisitChange;
        final now = _now().toUtc();
        await (db.update(db.visits)..where((t) => t.id.equals(visitId))).write(
          VisitsCompanion(deletedAt: Value(now)),
        );
        await db
            .into(db.outboxOps)
            .insert(
              _op(
                entity: 'visit',
                entityId: visitId,
                opType: 'delete',
                baseVersion: await _baseVersion(visit),
                payload: {'id': visitId},
                now: now,
              ),
            );
        return VisitChange.saved;
      });

  /// La visita, si [identity] puede editarla; si no, el motivo.
  Future<Object> _editable(CaptureIdentity identity, String visitId) async {
    final visit =
        await (db.select(db.visits)
              ..where((t) => t.id.equals(visitId) & t.orgId.equals(identity.orgId) & t.deletedAt.isNull()))
            .getSingleOrNull();
    if (visit == null) return VisitChange.notFound;
    if (!canEdit(visit, userId: identity.userId, roles: identity.roles)) return VisitChange.notAllowed;
    final quarantined =
        await (db.select(db.outboxOps)
              ..where((t) => t.entityId.equals(visitId) & t.state.equals('quarantine'))
              ..limit(1))
            .get();
    // Con algo en revisión, una edición nueva quedaría detrás sin poder
    // salir: primero se resuelve la revisión.
    if (quarantined.isNotEmpty) return VisitChange.needsReview;
    return visit;
  }

  /// La versión que el agente estaba viendo más sus ediciones aún sin aplicar.
  Future<int> _baseVersion(Visit visit) async {
    final pendingEdits =
        await (db.select(db.outboxOps)..where(
              (t) => t.entity.equals('visit') & t.entityId.equals(visit.id) & t.opType.isIn(const ['update', 'delete']),
            ))
            .get();
    return visit.version + pendingEdits.length;
  }

  OutboxOpsCompanion _attachmentOp(String visitId, PendingAttachment a, int order, DateTime now) => _op(
    entity: 'visit_attachment',
    entityId: a.id,
    payload: {
      'id': a.id,
      'visit_id': visitId,
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

/// Resultado de editar o borrar una visita.
enum VisitChange {
  saved,

  /// Nada que guardar: las respuestas y la ubicación son las mismas.
  unchanged,
  notFound,

  /// No es una visita de este agente.
  notAllowed,

  /// Tiene algo en "Para revisar": se resuelve primero.
  needsReview,
}

/// ¿Puede el usuario editar o borrar [visit]? Su autor o supervisión: la
/// misma regla que impone el servidor (`can_modify_visit`, ISO 27001
/// A.5.15). Aquí solo decide qué botones se muestran; quien autoriza es el
/// servidor, que rechaza con `forbidden` lo que no corresponda.
bool canEdit(Visit visit, {required String userId, required List<String> roles}) =>
    visit.createdBy == userId || roles.any(supervisionRoles.contains);

/// Roles que supervisan el trabajo de campo (`SUPERVISION_ROLES` del servidor).
const supervisionRoles = {'OWNER', 'ADMIN', 'SUPERVISOR'};

/// Las respuestas que se guardan: solo las de campos visibles.
Map<String, Object?> keptAnswers(FormDefinition definition, Map<String, Object?> answers) => {
  for (final field in visibleFields(definition, answers))
    if (answers.containsKey(field.key)) field.key: answers[field.key],
};
