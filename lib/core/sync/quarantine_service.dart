// Revisión de la cuarentena (Paso 23): lo que el servidor rechazó o lo que
// chocó con un cambio hecho en el servidor, agrupado por registro, y las
// acciones para resolverlo.
//
// **Regla del paso (N-05, doc 08 §7.2): nada descarta el trabajo del agente
// sin que él lo pida.** Por eso:
// - un conflicto llega aquí con la fila del servidor guardada, sin aplicarla
//   (`SyncEngine`). El agente elige: [resendMine] (su versión gana, como
//   `update` sobre la versión actual del servidor) o [acceptServer];
// - un rechazo se puede [retry] (con `op_uuid` nuevo: el servidor recuerda el
//   rechazo de cada `op_uuid`), [correct] (corregir las respuestas y reenviar)
//   o [discard] (borra el registro del teléfono). Descartar y aceptar la del
//   servidor son las únicas acciones que pierden datos, y la UI las confirma.
//
// Un registro rechazado arrastra a sus adjuntos: el servidor también los
// rechaza (su registro no existe). Las acciones se aplican al grupo entero y
// conservan el orden (registro antes que adjuntos).
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import '../../data/local/database.dart';
import '../../data/local/schedule_task_repository.dart';
import '../schedule/progress_input.dart';
import '../schedule/quantity_rows.dart';
import 'sync_engine.dart';
import 'sync_transport.dart';

enum QuarantineKind { conflict, rejected }

/// Un campo que difiere entre la versión del agente y la del servidor.
typedef FieldDiff = ({String field, Object? mine, Object? server});

/// Costos, pieza 4b: motivos de rechazo de una fila de cantidad que se corrigen
/// reasignando el ítem o la ubicación, o quitando la fila.
const quantityRejectionReasons = {'item_not_in_project', 'location_outside_task'};

/// Una fila de cantidad que el servidor rechazó, identificada en el teléfono (el rechazo
/// no dice cuál): su posición en `Records.quantitiesJson`, el código del ítem (`''` si no
/// se conoce) y el motivo.
typedef QuantityFlag = ({int index, String code, String reason});

List<Map<String, Object?>> _quantitiesOf(Object? value) => [
  for (final row in value is List ? value : const [])
    if (row is Map) row.cast<String, Object?>(),
];

@immutable
class QuarantinedRecord {
  const QuarantinedRecord({
    required this.record,
    required this.templateName,
    required this.kind,
    required this.code,
    required this.message,
    required this.violations,
    required this.serverData,
    required this.ops,
    this.taskLabels = const {},
    this.quantityFlags = const [],
  });

  /// El registro tal como está en el teléfono (la versión del agente).
  final Record record;
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

  /// Costos, pieza 4b: las filas de cantidad señaladas.
  final List<QuantityFlag> quantityFlags;

  /// El servidor rechazó una fila de cantidad (ítem o ubicación): se corrige en
  /// `QuantityCorrectionScreen`. No si el registro ya está validado.
  bool get quantityRejected =>
      kind == QuarantineKind.rejected &&
      !recordValidated &&
      violations.any((v) => v.field == 'quantities' && quantityRejectionReasons.contains(v.reason));

  /// ¿El agente editó la tarea, el % o las cantidades de este registro? Solo entonces
  /// su versión los lleva; si no, "enviar la mía" respeta lo que tenga el servidor.
  bool get editedTask => ops.any((op) {
    if (op.entity != 'record' || op.opType == 'delete') return false;
    final payload = jsonDecode(op.payloadJson);
    return payload is Map &&
        (payload.containsKey('task_id') || payload.containsKey('progress_pct') || payload.containsKey('quantities'));
  });

  Map<String, Object?> get localAnswers => (jsonDecode(record.answersJson) as Map).cast<String, Object?>();

  /// El servidor ya tiene el registro: lo rechazado es una edición o un
  /// borrado, y descartarlo devuelve el registro a la versión del servidor.
  bool get existsOnServer => record.serverDataJson != null;

  /// ¿Tiene sentido abrir el formulario para corregir? Solo si el servidor
  /// señaló respuestas concretas.
  bool get canCorrect => kind == QuarantineKind.rejected && answerViolations.isNotEmpty;

  /// El servidor rechazó el cambio porque el registro ya fue validado
  /// (`record_validated`): reenviarlo, también sin tarea, se rechazaría igual.
  bool get recordValidated => kind == QuarantineKind.rejected && violations.any((v) => v.reason == 'record_validated');

  /// El servidor rechazó la tarea del cronograma (retirada, ya no es
  /// responsable, % fuera de rango…): se puede reenviar sin ella. No si el
  /// registro ya está validado: quitar la tarea sería otro cambio rechazado.
  bool get taskRejected =>
      kind == QuarantineKind.rejected &&
      !recordValidated &&
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
    for (final (key, mine) in [('lat', record.lat), ('lon', record.lon)]) {
      if (!_sameJson(mine, server[key])) diffs.add((field: key, mine: mine, server: server[key]));
    }
    if (editedTask) {
      String? task(Object? id) => id is String ? taskLabels[id] ?? id : null;
      String? pct(Object? value) => value is num ? '${formatProgressPct(value.toDouble())} %' : null;
      if (!_sameJson(record.taskId, server['task_id'])) {
        diffs.add((field: 'task_id', mine: task(record.taskId), server: task(server['task_id'])));
      }
      final serverPct = server['progress_pct'];
      if (!_sameJson(record.progressPct, serverPct is num ? serverPct.toDouble() : serverPct)) {
        diffs.add((field: 'progress_pct', mine: pct(record.progressPct), server: pct(serverPct)));
      }
      final mine = _quantitiesOf(jsonDecode(record.quantitiesJson));
      final theirs = _quantitiesOf(server['quantities']);
      if (!sameQuantities(mine, theirs)) diffs.add((field: 'quantities', mine: mine, server: theirs));
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

  /// Los registros de [orgId] con algo en cuarentena, la más reciente primero.
  Future<List<QuarantinedRecord>> list({required String orgId}) async {
    final ops =
        await (db.select(db.outboxOps)
              ..where((t) => t.state.equals(_quarantine))
              ..orderBy([
                (t) => OrderingTerm.asc(t.createdAt),
                (t) => OrderingTerm.asc(const CustomExpression<int>('rowid')),
              ]))
            .get();
    final byRecord = <String, List<OutboxOp>>{};
    for (final op in ops) {
      final recordId = _recordOf(op);
      if (recordId != null) byRecord.putIfAbsent(recordId, () => []).add(op);
    }
    if (byRecord.isEmpty) return const [];

    final records =
        await (db.select(db.records)
              ..where((t) => t.id.isIn(byRecord.keys) & t.orgId.equals(orgId))
              ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)]))
            .get();
    final names = {
      for (final row
          in await (db.select(
            db.formTemplateVersions,
          )..where((t) => t.id.isIn({for (final v in records) v.templateVersionId}))).get())
        row.id: row.name,
    };

    final taskIds = <String>{
      for (final v in records) ?v.taskId,
      for (final op in ops) ..._taskIdsOf(op),
    };
    final taskLabels = taskIds.isEmpty
        ? const <String, String>{}
        : {
            for (final row in await (db.select(db.scheduleTasks)..where((t) => t.id.isIn(taskIds))).get())
              row.id: ScheduleTaskItem.fromRow(row).label,
          };

    return [
      for (final record in records)
        _describe(
          record,
          names[record.templateVersionId],
          byRecord[record.id]!,
          taskLabels,
          await _quantityFlags(record, byRecord[record.id]!),
        ),
    ];
  }

  /// Cuántas registros de [orgId] esperan revisión (para el aviso de la portada).
  Future<int> count({required String orgId}) async => (await list(orgId: orgId)).length;

  /// Reintenta el grupo tal cual, con `op_uuid` nuevos y en el mismo orden.
  /// Útil cuando la causa ya desapareció (p. ej. la plantilla llegó por fin).
  Future<void> retry(QuarantinedRecord item) => db.transaction(() async {
    for (final op in item.ops) {
      await engine.retryQuarantined(op.opUuid);
    }
  });

  /// Corrige las respuestas de un registro rechazado y reenvía el grupo.
  /// [answers] son las respuestas ya corregidas (solo campos visibles).
  Future<void> correct(QuarantinedRecord item, Map<String, Object?> answers) => db.transaction(() async {
    final answersJson = jsonEncode(answers);
    await (db.update(db.records)..where((t) => t.id.equals(item.record.id))).write(
      RecordsCompanion(answersJson: Value(answersJson)),
    );
    for (final op in item.ops) {
      if (op.entity == 'record' && op.opType != 'delete') {
        final payload = (jsonDecode(op.payloadJson) as Map).cast<String, Object?>()..['answers'] = answers;
        await (db.update(db.outboxOps)..where((t) => t.opUuid.equals(op.opUuid))).write(
          OutboxOpsCompanion(payloadJson: Value(jsonEncode(payload))),
        );
      }
      await engine.retryQuarantined(op.opUuid);
    }
  });

  /// Rechazo por la tarea: el registro se queda sin tarea ni cantidades y se reenvía.
  /// En un alta los campos se quitan; en una edición el par viaja en `null`
  /// (desvincular, que no exige ser responsable) y sin cantidades (un `update` con el
  /// par en `null` deja las cantidades vacías en el servidor).
  Future<void> unlinkTask(QuarantinedRecord item) => db.transaction(() async {
    await (db.update(db.records)..where((t) => t.id.equals(item.record.id))).write(
      const RecordsCompanion(taskId: Value(null), progressPct: Value(null), quantitiesJson: Value('[]')),
    );
    for (final op in item.ops) {
      if (op.entity == 'record' && op.opType != 'delete') {
        final payload = (jsonDecode(op.payloadJson) as Map).cast<String, Object?>();
        if (op.opType == 'create') {
          payload
            ..remove('task_id')
            ..remove('progress_pct')
            ..remove('quantities');
        } else if (payload.containsKey('task_id') ||
            payload.containsKey('progress_pct') ||
            payload.containsKey('quantities')) {
          payload['task_id'] = null;
          payload['progress_pct'] = null;
          payload.remove('quantities');
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
                  t.entity.equals('record') &
                  t.entityId.equals(item.record.id) &
                  t.opType.equals('update') &
                  t.state.equals(_pending),
            ))
            .get();
    for (final op in later) {
      if (quarantined.contains(op.opUuid)) continue;
      final payload = (jsonDecode(op.payloadJson) as Map).cast<String, Object?>();
      if (!payload.containsKey('task_id') &&
          !payload.containsKey('progress_pct') &&
          !payload.containsKey('quantities')) {
        continue;
      }
      payload['task_id'] = null;
      payload['progress_pct'] = null;
      payload.remove('quantities');
      await (db.update(db.outboxOps)..where((t) => t.opUuid.equals(op.opUuid))).write(
        OutboxOpsCompanion(payloadJson: Value(jsonEncode(payload))),
      );
    }
  });

  /// Costos, pieza 4b: corrige las cantidades de un registro rechazado (ítem o ubicación
  /// reasignados, filas quitadas) y reenvía el grupo. [rows] son las filas ya corregidas
  /// (`RecordQuantityPayload`).
  Future<void> correctQuantities(QuarantinedRecord item, List<Map<String, Object?>> rows) =>
      db.transaction(() async {
        await (db.update(db.records)..where((t) => t.id.equals(item.record.id))).write(
          RecordsCompanion(quantitiesJson: Value(jsonEncode(rows))),
        );
        for (final op in item.ops) {
          if (op.entity == 'record' && op.opType != 'delete') {
            final payload = (jsonDecode(op.payloadJson) as Map).cast<String, Object?>();
            if (payload.containsKey('quantities')) {
              payload['quantities'] = rows;
              await (db.update(db.outboxOps)..where((t) => t.opUuid.equals(op.opUuid))).write(
                OutboxOpsCompanion(payloadJson: Value(jsonEncode(payload))),
              );
            }
          }
          await engine.retryQuarantined(op.opUuid);
        }
      });

  /// Las filas que el servidor pudo rechazar por [ops]: el rechazo solo dice el motivo,
  /// así que se buscan con lo que sabe el teléfono. `item_not_in_project`: ítem que no
  /// está ni en el plan de la tarea ni en el catálogo de su proyecto.
  /// `location_outside_task`: ubicación que no es una de las opciones de la tarea.
  Future<List<QuantityFlag>> _quantityFlags(Record record, List<OutboxOp> ops) async {
    final reasons = {
      for (final op in ops)
        for (final v in _violations(op.errorFieldsJson))
          if (v.field == 'quantities' && quantityRejectionReasons.contains(v.reason)) v.reason,
    };
    final taskId = record.taskId;
    if (reasons.isEmpty || taskId == null) return const [];
    final rows = decodeQuantities(record.quantitiesJson);
    final schedule = ScheduleTaskRepository(db);
    final task = await schedule.byId(taskId);
    final context = await schedule.quantityContext(taskId: taskId, projectId: task?.projectId);
    final known = await schedule.knownItems({for (final row in rows) row['item_id']! as String});
    final measurable = {for (final i in context.allItems) i.itemId};
    final locations = {for (final l in context.locations) l.id};
    String code(Map<String, Object?> row) => known[row['item_id']]?.code ?? '';
    return [
      for (final (index, row) in rows.indexed) ...[
        if (reasons.contains('item_not_in_project') && !measurable.contains(row['item_id']))
          (index: index, code: code(row), reason: 'item_not_in_project'),
        if (reasons.contains('location_outside_task') &&
            row['location_id'] is String &&
            !locations.contains(row['location_id']))
          (index: index, code: code(row), reason: 'location_outside_task'),
      ],
    ];
  }

  /// Conflicto: la versión del agente gana. Se envía como `update` sobre la
  /// versión **actual** del servidor (su `version` como `base_version`), con
  /// los campos en los que difieren. Si ya no difieren, es lo mismo que
  /// aceptar la del servidor.
  Future<void> resendMine(QuarantinedRecord item) => db.transaction(() async {
    final server = item.serverData;
    if (item.kind != QuarantineKind.conflict || server == null) {
      throw StateError('resendMine solo resuelve conflictos con fila del servidor.');
    }
    final record = item.record;
    // Lo del agente era **borrarla** (Fase A): su versión gana borrándola
    // sobre la versión actual del servidor, no reenviando sus campos.
    if (item.ops.any((op) => op.entity == 'record' && op.opType == 'delete')) {
      final serverVersion = server['version'] as int;
      await _deleteOps(item.ops);
      await db
          .into(db.outboxOps)
          .insert(
            OutboxOpsCompanion.insert(
              opUuid: engine.newOpUuid(),
              entity: 'record',
              entityId: record.id,
              opType: 'delete',
              baseVersion: Value(serverVersion),
              payloadJson: jsonEncode({'id': record.id}),
              state: _pending,
              createdAt: _now().toUtc(),
            ),
          );
      return;
    }
    // Tal como están guardadas: una fila sin datos automáticos (del pull) se reenvía
    // sin ellos.
    final localQuantities = decodeQuantities(record.quantitiesJson);
    final changed = <String, Object?>{};
    if (!_sameJson(item.localAnswers, server['answers'])) changed['answers'] = item.localAnswers;
    for (final (key, mine) in [
      ('lat', record.lat),
      ('lon', record.lon),
      ('accuracy_m', record.accuracyM),
      ('altitude_m', record.altitudeM),
      // La tarea solo si el agente la editó: si no, queda la del servidor.
      if (item.editedTask) ...[('task_id', record.taskId), ('progress_pct', record.progressPct)],
    ]) {
      if (!_sameJson(mine, server[key])) changed[key] = mine;
    }
    // Costos, pieza 4b: las cantidades, si el agente las editó y difieren.
    if (item.editedTask && !sameQuantities(localQuantities, _quantitiesOf(server['quantities']))) {
      changed['quantities'] = localQuantities;
    }
    // El servidor exige `task_id` y `progress_pct` juntos; las cantidades viajan con ellos
    // (sin la clave, el servidor deja la lista vacía).
    if (changed.containsKey('task_id') || changed.containsKey('progress_pct') || changed.containsKey('quantities')) {
      changed['task_id'] = record.taskId;
      changed['progress_pct'] = record.progressPct;
      if (localQuantities.isEmpty) {
        changed.remove('quantities');
      } else {
        changed['quantities'] = localQuantities;
      }
    }
    if (changed.isEmpty) {
      await _acceptServer(item, server);
      return;
    }
    final serverVersion = server['version'] as int;
    await _deleteOps(item.ops);
    await (db.update(db.records)..where((t) => t.id.equals(record.id))).write(
      RecordsCompanion(version: Value(serverVersion)),
    );
    await db
        .into(db.outboxOps)
        .insert(
          OutboxOpsCompanion.insert(
            opUuid: engine.newOpUuid(),
            entity: 'record',
            entityId: record.id,
            opType: 'update',
            baseVersion: Value(serverVersion),
            payloadJson: jsonEncode({'id': record.id, ...changed}),
            state: _pending,
            createdAt: _now().toUtc(),
          ),
        );
  });

  /// Conflicto: el agente se queda con la versión del servidor. **Pierde sus
  /// cambios**: la UI lo confirma antes de llamar aquí.
  Future<void> acceptServer(QuarantinedRecord item) => db.transaction(() async {
    final server = item.serverData;
    if (item.kind != QuarantineKind.conflict || server == null) {
      throw StateError('acceptServer solo resuelve conflictos con fila del servidor.');
    }
    await _acceptServer(item, server);
  });

  /// Rechazo: descarta lo que el servidor no aceptó, con sus operaciones.
  ///
  /// - Registro que el servidor **nunca tuvo**: se borra del teléfono con sus
  ///   adjuntos. **Pierde el registro**.
  /// - Registro que el servidor **ya tiene** (lo rechazado era una edición o un
  ///   borrado, Fase A): se descartan los cambios sin enviar y el registro
  ///   vuelve a la última versión confirmada por el servidor
  ///   (`serverDataJson`); los adjuntos que solo existían en esas ediciones
  ///   se van con ellas. **Pierde la edición**.
  ///
  /// La UI lo confirma antes de llamar aquí. Las fotos que ningún otro
  /// registro usa salen también de la cola de subida.
  Future<void> discard(QuarantinedRecord item) => db.transaction(() async {
    final recordId = item.record.id;
    final current = await (db.select(db.records)..where((t) => t.id.equals(recordId))).getSingleOrNull();
    final serverData = current?.serverDataJson;
    final all = await (db.select(db.recordAttachments)..where((t) => t.recordId.equals(recordId))).get();
    final List<RecordAttachment> attachments;
    if (serverData == null) {
      attachments = all;
    } else {
      // Solo los adjuntos cuya alta sigue sin enviar: los demás ya están en
      // el servidor y se quedan.
      final unsent = {
        for (final op
            in await (db.select(db.outboxOps)
                  ..where((t) => t.entity.equals('record_attachment') & t.entityId.isIn([for (final a in all) a.id])))
                .get())
          op.entityId,
      };
      attachments = [for (final a in all) if (unsent.contains(a.id)) a];
    }
    final attachmentIds = [for (final a in attachments) a.id];
    await (db.delete(db.outboxOps)..where((t) => t.entityId.isIn([recordId, ...attachmentIds]))).go();
    await (db.delete(db.recordAttachments)..where((t) => t.id.isIn(attachmentIds))).go();
    if (serverData == null) {
      await (db.delete(db.records)..where((t) => t.id.equals(recordId))).go();
    } else if (!await engine.applyServerRecord({'entity': 'record', 'data': jsonDecode(serverData)})) {
      throw StateError('La copia del servidor guardada no tiene la forma del contrato.');
    }
    for (final sha in {for (final a in attachments) a.sha256}) {
      final stillUsed = await (db.select(db.recordAttachments)..where((t) => t.sha256.equals(sha))).get();
      if (stillUsed.isEmpty) {
        await (db.delete(
          db.attachmentQueue,
        )..where((t) => t.sha256.equals(sha) & t.state.isNotValue('uploaded'))).go();
      }
    }
  });

  Future<void> _acceptServer(QuarantinedRecord item, Map<String, dynamic> server) async {
    if (!await engine.applyServerRecord({'entity': 'record', 'data': server})) {
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

  QuarantinedRecord _describe(
    Record record,
    String? templateName,
    List<OutboxOp> ops,
    Map<String, String> taskLabels,
    List<QuantityFlag> quantityFlags,
  ) {
    final recordOp = ops.where((op) => op.entity == 'record').firstOrNull;
    final lead = recordOp ?? ops.first;
    final isConflict = lead.errorCode == 'conflict' && lead.serverRowJson != null;
    final serverRecord = isConflict ? jsonDecode(lead.serverRowJson!) : null;
    return QuarantinedRecord(
      record: record,
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
      quantityFlags: quantityFlags,
    );
  }

  static List<FieldViolation> _violations(String? json) {
    if (json == null) return const [];
    final decoded = jsonDecode(json);
    return decoded is List ? fieldViolations({'errors': decoded}) : const [];
  }

  static String? _recordOf(OutboxOp op) {
    if (op.entity == 'record') return op.entityId;
    if (op.entity == 'record_attachment') {
      final payload = jsonDecode(op.payloadJson);
      return payload is Map && payload['record_id'] is String ? payload['record_id'] as String : null;
    }
    return null;
  }
}
