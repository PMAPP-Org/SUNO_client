// Revisión de la cuarentena (Paso 23): lo que el servidor rechazó o lo que
// chocó con un cambio hecho en el servidor, agrupado por visita, y las
// acciones para resolverlo.
//
// **Regla del paso (N-05, doc 08 §7.2): nada descarta el trabajo del agente
// sin que él lo pida.** Por eso:
// - un conflicto llega aquí con la fila del servidor guardada, sin aplicarla
//   (`SyncEngine`). El agente elige: [resendMine] (su versión gana, como
//   `update` sobre la versión actual del servidor) o [acceptServer];
// - un rechazo se puede [retry] (con `op_uuid` nuevo: el servidor recuerda el
//   rechazo de cada `op_uuid`), [correct] (corregir las respuestas y reenviar)
//   o [discard] (borra la visita del teléfono). Descartar y aceptar la del
//   servidor son las únicas acciones que pierden datos, y la UI las confirma.
//
// Una visita rechazada arrastra a sus adjuntos: el servidor también los
// rechaza (su visita no existe). Las acciones se aplican al grupo entero y
// conservan el orden (visita antes que adjuntos).
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import '../../data/local/database.dart';
import '../../data/local/schedule_task_repository.dart';
import '../schedule/progress_input.dart';
import 'sync_engine.dart';
import 'sync_transport.dart';

enum QuarantineKind { conflict, rejected }

/// Un campo que difiere entre la versión del agente y la del servidor.
typedef FieldDiff = ({String field, Object? mine, Object? server});

@immutable
class QuarantinedVisit {
  const QuarantinedVisit({
    required this.visit,
    required this.templateName,
    required this.kind,
    required this.code,
    required this.message,
    required this.violations,
    required this.serverData,
    required this.ops,
    this.taskLabels = const {},
  });

  /// La visita tal como está en el teléfono (la versión del agente).
  final Visit visit;
  final String? templateName;
  final QuarantineKind kind;

  /// `code` del contrato (`validation_error`, `not_found`, `conflict`…).
  final String? code;
  final String message;

  /// Campos señalados por el servidor, tal cual (`answers.altura_cm`,
  /// `template_version_id`…).
  final List<FieldViolation> violations;

  /// Las violaciones que son de **respuestas**, por clave de campo
  /// (`altura_cm` → `out_of_range`): lo que el agente puede corregir.
  Map<String, String> get answerViolations => {
    for (final v in violations)
      if (v.field.startsWith('answers.')) v.field.substring('answers.'.length): v.reason,
  };

  /// `data` de la fila autoritativa, solo en conflictos.
  final Map<String, dynamic>? serverData;

  /// Las operaciones en cuarentena del grupo, en orden de envío.
  final List<OutboxOp> ops;

  /// Etiqueta (EDT y nombre) de las tareas conocidas en el teléfono, por id.
  final Map<String, String> taskLabels;

  /// ¿El agente editó la tarea o el % de esta visita? Solo entonces su
  /// versión los lleva; si no, "enviar la mía" respeta lo que tenga el servidor.
  bool get editedTask => ops.any((op) {
    if (op.entity != 'visit' || op.opType == 'delete') return false;
    final payload = jsonDecode(op.payloadJson);
    return payload is Map && (payload.containsKey('task_id') || payload.containsKey('progress_pct'));
  });

  Map<String, Object?> get localAnswers => (jsonDecode(visit.answersJson) as Map).cast<String, Object?>();

  /// El servidor ya tiene la visita: lo rechazado es una edición o un
  /// borrado, y descartarlo devuelve la visita a la versión del servidor.
  bool get existsOnServer => visit.serverDataJson != null;

  /// ¿Tiene sentido abrir el formulario para corregir? Solo si el servidor
  /// señaló respuestas concretas.
  bool get canCorrect => kind == QuarantineKind.rejected && answerViolations.isNotEmpty;

  /// El servidor rechazó el cambio porque la visita ya fue validada
  /// (`visit_validated`): reenviarlo, también sin tarea, se rechazaría igual.
  bool get visitValidated => kind == QuarantineKind.rejected && violations.any((v) => v.reason == 'visit_validated');

  /// El servidor rechazó la tarea del cronograma (retirada, ya no es
  /// responsable, % fuera de rango…): se puede reenviar sin ella. No si la
  /// visita ya está validada: quitar la tarea sería otro cambio rechazado.
  bool get taskRejected =>
      kind == QuarantineKind.rejected &&
      !visitValidated &&
      violations.any((v) => v.field == 'task_id' || v.field == 'progress_pct');

  /// Diferencias campo a campo con el servidor (conflictos): respuestas y
  /// ubicación. Las claves de respuesta van tal cual (`altura_cm`).
  List<FieldDiff> get differences {
    final server = serverData;
    if (server == null) return const [];
    final mineAnswers = localAnswers;
    final serverAnswers = (server['answers'] as Map?)?.cast<String, Object?>() ?? const {};
    final diffs = <FieldDiff>[
      for (final key in {...mineAnswers.keys, ...serverAnswers.keys})
        if (!_sameJson(mineAnswers[key], serverAnswers[key]))
          (field: key, mine: mineAnswers[key], server: serverAnswers[key]),
    ];
    for (final (key, mine) in [('lat', visit.lat), ('lon', visit.lon)]) {
      if (!_sameJson(mine, server[key])) diffs.add((field: key, mine: mine, server: server[key]));
    }
    if (editedTask) {
      String? task(Object? id) => id is String ? taskLabels[id] ?? id : null;
      String? pct(Object? value) => value is num ? '${formatProgressPct(value.toDouble())} %' : null;
      if (!_sameJson(visit.taskId, server['task_id'])) {
        diffs.add((field: 'task_id', mine: task(visit.taskId), server: task(server['task_id'])));
      }
      final serverPct = server['progress_pct'];
      if (!_sameJson(visit.progressPct, serverPct is num ? serverPct.toDouble() : serverPct)) {
        diffs.add((field: 'progress_pct', mine: pct(visit.progressPct), server: pct(serverPct)));
      }
    }
    return diffs;
  }
}

bool _sameJson(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

class QuarantineService {
  QuarantineService({required this.db, required this.engine, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase db;
  final SyncEngine engine;
  final DateTime Function() _now;

  static const _quarantine = 'quarantine';
  static const _pending = 'pending';

  /// Las visitas de [orgId] con algo en cuarentena, la más reciente primero.
  Future<List<QuarantinedVisit>> list({required String orgId}) async {
    final ops =
        await (db.select(db.outboxOps)
              ..where((t) => t.state.equals(_quarantine))
              ..orderBy([
                (t) => OrderingTerm.asc(t.createdAt),
                (t) => OrderingTerm.asc(const CustomExpression<int>('rowid')),
              ]))
            .get();
    final byVisit = <String, List<OutboxOp>>{};
    for (final op in ops) {
      final visitId = _visitOf(op);
      if (visitId != null) byVisit.putIfAbsent(visitId, () => []).add(op);
    }
    if (byVisit.isEmpty) return const [];

    final visits =
        await (db.select(db.visits)
              ..where((t) => t.id.isIn(byVisit.keys) & t.orgId.equals(orgId))
              ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)]))
            .get();
    final names = {
      for (final row
          in await (db.select(
            db.formTemplateVersions,
          )..where((t) => t.id.isIn({for (final v in visits) v.templateVersionId}))).get())
        row.id: row.name,
    };

    final taskIds = <String>{
      for (final v in visits) ?v.taskId,
      for (final op in ops) ..._taskIdsOf(op),
    };
    final taskLabels = taskIds.isEmpty
        ? const <String, String>{}
        : {
            for (final row in await (db.select(db.scheduleTasks)..where((t) => t.id.isIn(taskIds))).get())
              row.id: ScheduleTaskItem.fromRow(row).label,
          };

    return [
      for (final visit in visits)
        _describe(visit, names[visit.templateVersionId], byVisit[visit.id]!, taskLabels),
    ];
  }

  /// Cuántas visitas de [orgId] esperan revisión (para el aviso de la portada).
  Future<int> count({required String orgId}) async => (await list(orgId: orgId)).length;

  /// Reintenta el grupo tal cual, con `op_uuid` nuevos y en el mismo orden.
  /// Útil cuando la causa ya desapareció (p. ej. la plantilla llegó por fin).
  Future<void> retry(QuarantinedVisit item) => db.transaction(() async {
    for (final op in item.ops) {
      await engine.retryQuarantined(op.opUuid);
    }
  });

  /// Corrige las respuestas de una visita rechazada y reenvía el grupo.
  /// [answers] son las respuestas ya corregidas (solo campos visibles).
  Future<void> correct(QuarantinedVisit item, Map<String, Object?> answers) => db.transaction(() async {
    final answersJson = jsonEncode(answers);
    await (db.update(db.visits)..where((t) => t.id.equals(item.visit.id))).write(
      VisitsCompanion(answersJson: Value(answersJson)),
    );
    for (final op in item.ops) {
      if (op.entity == 'visit' && op.opType != 'delete') {
        final payload = (jsonDecode(op.payloadJson) as Map).cast<String, Object?>()..['answers'] = answers;
        await (db.update(db.outboxOps)..where((t) => t.opUuid.equals(op.opUuid))).write(
          OutboxOpsCompanion(payloadJson: Value(jsonEncode(payload))),
        );
      }
      await engine.retryQuarantined(op.opUuid);
    }
  });

  /// Rechazo por la tarea: la visita se queda sin tarea y se reenvía. En un
  /// alta los dos campos se quitan; en una edición viajan en `null`
  /// (desvincular, que no exige ser responsable).
  Future<void> unlinkTask(QuarantinedVisit item) => db.transaction(() async {
    await (db.update(db.visits)..where((t) => t.id.equals(item.visit.id))).write(
      const VisitsCompanion(taskId: Value(null), progressPct: Value(null)),
    );
    for (final op in item.ops) {
      if (op.entity == 'visit' && op.opType != 'delete') {
        final payload = (jsonDecode(op.payloadJson) as Map).cast<String, Object?>();
        if (op.opType == 'create') {
          payload
            ..remove('task_id')
            ..remove('progress_pct');
        } else if (payload.containsKey('task_id') || payload.containsKey('progress_pct')) {
          payload['task_id'] = null;
          payload['progress_pct'] = null;
        }
        await (db.update(db.outboxOps)..where((t) => t.opUuid.equals(op.opUuid))).write(
          OutboxOpsCompanion(payloadJson: Value(jsonEncode(payload))),
        );
      }
      await engine.retryQuarantined(op.opUuid);
    }
    // Ediciones posteriores aún sin enviar que llevan la tarea: si salieran,
    // la volverían a poner. Se quedan con el par en `null`.
    final quarantined = {for (final op in item.ops) op.opUuid};
    final later =
        await (db.select(db.outboxOps)..where(
              (t) =>
                  t.entity.equals('visit') &
                  t.entityId.equals(item.visit.id) &
                  t.opType.equals('update') &
                  t.state.equals(_pending),
            ))
            .get();
    for (final op in later) {
      if (quarantined.contains(op.opUuid)) continue;
      final payload = (jsonDecode(op.payloadJson) as Map).cast<String, Object?>();
      if (!payload.containsKey('task_id') && !payload.containsKey('progress_pct')) continue;
      payload['task_id'] = null;
      payload['progress_pct'] = null;
      await (db.update(db.outboxOps)..where((t) => t.opUuid.equals(op.opUuid))).write(
        OutboxOpsCompanion(payloadJson: Value(jsonEncode(payload))),
      );
    }
  });

  /// Conflicto: la versión del agente gana. Se envía como `update` sobre la
  /// versión **actual** del servidor (su `version` como `base_version`), con
  /// los campos en los que difieren. Si ya no difieren, es lo mismo que
  /// aceptar la del servidor.
  Future<void> resendMine(QuarantinedVisit item) => db.transaction(() async {
    final server = item.serverData;
    if (item.kind != QuarantineKind.conflict || server == null) {
      throw StateError('resendMine solo resuelve conflictos con fila del servidor.');
    }
    final visit = item.visit;
    // Lo del agente era **borrarla** (Fase A): su versión gana borrándola
    // sobre la versión actual del servidor, no reenviando sus campos.
    if (item.ops.any((op) => op.entity == 'visit' && op.opType == 'delete')) {
      final serverVersion = server['version'] as int;
      await _deleteOps(item.ops);
      await db
          .into(db.outboxOps)
          .insert(
            OutboxOpsCompanion.insert(
              opUuid: engine.newOpUuid(),
              entity: 'visit',
              entityId: visit.id,
              opType: 'delete',
              baseVersion: Value(serverVersion),
              payloadJson: jsonEncode({'id': visit.id}),
              state: _pending,
              createdAt: _now().toUtc(),
            ),
          );
      return;
    }
    final changed = <String, Object?>{};
    if (!_sameJson(item.localAnswers, server['answers'])) changed['answers'] = item.localAnswers;
    for (final (key, mine) in [
      ('lat', visit.lat),
      ('lon', visit.lon),
      ('accuracy_m', visit.accuracyM),
      ('altitude_m', visit.altitudeM),
      // La tarea solo si el agente la editó: si no, queda la del servidor.
      if (item.editedTask) ...[('task_id', visit.taskId), ('progress_pct', visit.progressPct)],
    ]) {
      if (!_sameJson(mine, server[key])) changed[key] = mine;
    }
    // El servidor exige `task_id` y `progress_pct` juntos.
    if (changed.containsKey('task_id') || changed.containsKey('progress_pct')) {
      changed['task_id'] = visit.taskId;
      changed['progress_pct'] = visit.progressPct;
    }
    if (changed.isEmpty) {
      await _acceptServer(item, server);
      return;
    }
    final serverVersion = server['version'] as int;
    await _deleteOps(item.ops);
    await (db.update(db.visits)..where((t) => t.id.equals(visit.id))).write(
      VisitsCompanion(version: Value(serverVersion)),
    );
    await db
        .into(db.outboxOps)
        .insert(
          OutboxOpsCompanion.insert(
            opUuid: engine.newOpUuid(),
            entity: 'visit',
            entityId: visit.id,
            opType: 'update',
            baseVersion: Value(serverVersion),
            payloadJson: jsonEncode({'id': visit.id, ...changed}),
            state: _pending,
            createdAt: _now().toUtc(),
          ),
        );
  });

  /// Conflicto: el agente se queda con la versión del servidor. **Pierde sus
  /// cambios**: la UI lo confirma antes de llamar aquí.
  Future<void> acceptServer(QuarantinedVisit item) => db.transaction(() async {
    final server = item.serverData;
    if (item.kind != QuarantineKind.conflict || server == null) {
      throw StateError('acceptServer solo resuelve conflictos con fila del servidor.');
    }
    await _acceptServer(item, server);
  });

  /// Rechazo: descarta lo que el servidor no aceptó, con sus operaciones.
  ///
  /// - Visita que el servidor **nunca tuvo**: se borra del teléfono con sus
  ///   adjuntos. **Pierde la visita**.
  /// - Visita que el servidor **ya tiene** (lo rechazado era una edición o un
  ///   borrado, Fase A): se descartan los cambios sin enviar y la visita
  ///   vuelve a la última versión confirmada por el servidor
  ///   (`serverDataJson`); los adjuntos que solo existían en esas ediciones
  ///   se van con ellas. **Pierde la edición**.
  ///
  /// La UI lo confirma antes de llamar aquí. Las fotos que ninguna otra
  /// visita usa salen también de la cola de subida.
  Future<void> discard(QuarantinedVisit item) => db.transaction(() async {
    final visitId = item.visit.id;
    final current = await (db.select(db.visits)..where((t) => t.id.equals(visitId))).getSingleOrNull();
    final serverData = current?.serverDataJson;
    final all = await (db.select(db.visitAttachments)..where((t) => t.visitId.equals(visitId))).get();
    final List<VisitAttachment> attachments;
    if (serverData == null) {
      attachments = all;
    } else {
      // Solo los adjuntos cuya alta sigue sin enviar: los demás ya están en
      // el servidor y se quedan.
      final unsent = {
        for (final op
            in await (db.select(db.outboxOps)
                  ..where((t) => t.entity.equals('visit_attachment') & t.entityId.isIn([for (final a in all) a.id])))
                .get())
          op.entityId,
      };
      attachments = [for (final a in all) if (unsent.contains(a.id)) a];
    }
    final attachmentIds = [for (final a in attachments) a.id];
    await (db.delete(db.outboxOps)..where((t) => t.entityId.isIn([visitId, ...attachmentIds]))).go();
    await (db.delete(db.visitAttachments)..where((t) => t.id.isIn(attachmentIds))).go();
    if (serverData == null) {
      await (db.delete(db.visits)..where((t) => t.id.equals(visitId))).go();
    } else if (!await engine.applyServerRecord({'entity': 'visit', 'data': jsonDecode(serverData)})) {
      throw StateError('La copia del servidor guardada no tiene la forma del contrato.');
    }
    for (final sha in {for (final a in attachments) a.sha256}) {
      final stillUsed = await (db.select(db.visitAttachments)..where((t) => t.sha256.equals(sha))).get();
      if (stillUsed.isEmpty) {
        await (db.delete(
          db.attachmentQueue,
        )..where((t) => t.sha256.equals(sha) & t.state.isNotValue('uploaded'))).go();
      }
    }
  });

  Future<void> _acceptServer(QuarantinedVisit item, Map<String, dynamic> server) async {
    if (!await engine.applyServerRecord({'entity': 'visit', 'data': server})) {
      throw StateError('La fila del servidor guardada no tiene la forma del contrato.');
    }
    await _deleteOps(item.ops);
  }

  Future<void> _deleteOps(List<OutboxOp> ops) =>
      (db.delete(db.outboxOps)..where((t) => t.opUuid.isIn([for (final op in ops) op.opUuid]))).go();

  /// Las tareas que cita el servidor en una fila de conflicto (para etiquetarlas).
  static Iterable<String> _taskIdsOf(OutboxOp op) {
    final row = op.serverRowJson == null ? null : jsonDecode(op.serverRowJson!);
    final data = row is Map ? row['data'] : null;
    return data is Map && data['task_id'] is String ? [data['task_id'] as String] : const [];
  }

  QuarantinedVisit _describe(
    Visit visit,
    String? templateName,
    List<OutboxOp> ops,
    Map<String, String> taskLabels,
  ) {
    final visitOp = ops.where((op) => op.entity == 'visit').firstOrNull;
    final lead = visitOp ?? ops.first;
    final isConflict = lead.errorCode == 'conflict' && lead.serverRowJson != null;
    final serverRecord = isConflict ? jsonDecode(lead.serverRowJson!) : null;
    return QuarantinedVisit(
      visit: visit,
      templateName: templateName,
      kind: isConflict ? QuarantineKind.conflict : QuarantineKind.rejected,
      code: lead.errorCode,
      message: lead.errorMessage ?? '',
      violations: [for (final op in ops) ..._violations(op.errorFieldsJson)],
      serverData: serverRecord is Map && serverRecord['data'] is Map
          ? (serverRecord['data'] as Map).cast<String, dynamic>()
          : null,
      ops: ops,
      taskLabels: taskLabels,
    );
  }

  static List<FieldViolation> _violations(String? json) {
    if (json == null) return const [];
    final decoded = jsonDecode(json);
    return decoded is List ? fieldViolations({'errors': decoded}) : const [];
  }

  static String? _visitOf(OutboxOp op) {
    if (op.entity == 'visit') return op.entityId;
    if (op.entity == 'visit_attachment') {
      final payload = jsonDecode(op.payloadJson);
      return payload is Map && payload['visit_id'] is String ? payload['visit_id'] as String : null;
    }
    return null;
  }
}
