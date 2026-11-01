// Costos, etapa 1: una visita rechazada por su tarea (retirada, ya no es
// responsable…) se reenvía sin tarea; "enviar la mía" manda el par completo.
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/sync/quarantine_service.dart';
import 'package:visitacampo/core/sync/result.dart';
import 'package:visitacampo/core/sync/sync_engine.dart';
import 'package:visitacampo/core/sync/sync_transport.dart';
import 'package:visitacampo/data/local/database.dart';

import 'fake_sync_transport.dart';

final _definition =
    (parseFormDefinition({
              'fields': [
                {
                  'key': 'notas',
                  'type': 'text',
                  'label': {'es': 'Notas'},
                },
              ],
            })
            as DefinitionOk)
        .definition;

void main() {
  late AppDatabase db;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late QuarantineService service;
  var ids = 0;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeSyncTransport();
    ids = 0;
    engine = SyncEngine(db: db, transport: transport, deviceId: 'device-1', idGenerator: () => 'op-${ids++}');
    service = QuarantineService(db: db, engine: engine, clock: () => DateTime.utc(2026, 11, 2));
  });
  tearDown(() => db.close());

  Future<void> pushWith(PushOpOutcome Function(OutboxOp op) outcome) async {
    final pending = await db.select(db.outboxOps).get();
    transport.pushResponses.add(
      Result.ok(PushResponse(schemaVersion: 1, results: [for (final op in pending) outcome(op)])),
    );
    await engine.drainOutbox();
  }

  test('rechazo por la tarea: se quita la tarea y se reenvía', () async {
    final visitId = await VisitCapture(db: db, idGenerator: () => 'cap-${ids++}').save(
      identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: _definition,
      answers: {'notas': 'x'},
      captured: const {},
      progress: const TaskProgress(taskId: 'task-1', pct: 35),
    );
    await pushWith(
      (op) => PushOpOutcome(
        opUuid: op.opUuid,
        status: 'rejected',
        error: const PushOpError(
          code: 'validation_error',
          message: 'The task was retired from the schedule.',
          details: {'field': 'task_id', 'reason': 'task_retired'},
        ),
      ),
    );
    final item = (await service.list(orgId: 'org-1')).single;
    expect(item.taskRejected, isTrue);

    await service.unlinkTask(item);

    final op = await db.select(db.outboxOps).getSingle();
    expect(op.state, 'pending');
    final payload = jsonDecode(op.payloadJson) as Map<String, dynamic>;
    expect(payload.containsKey('task_id'), isFalse);
    expect(payload.containsKey('progress_pct'), isFalse);
    final visit = await (db.select(db.visits)..where((t) => t.id.equals(visitId))).getSingle();
    expect((visit.taskId, visit.progressPct), (null, null));
  });

  test('rechazo por visita validada: no se ofrece quitar la tarea (se rechazaría igual)', () async {
    await VisitCapture(db: db, idGenerator: () => 'cap-${ids++}').save(
      identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: _definition,
      answers: {'notas': 'x'},
      captured: const {},
      progress: const TaskProgress(taskId: 'task-1', pct: 35),
    );
    await pushWith(
      (op) => PushOpOutcome(
        opUuid: op.opUuid,
        status: 'rejected',
        error: const PushOpError(
          code: 'validation_error',
          message: 'The visit was already validated.',
          details: {'field': 'progress_pct', 'reason': 'visit_validated'},
        ),
      ),
    );
    final item = (await service.list(orgId: 'org-1')).single;
    expect(item.visitValidated, isTrue);
    expect(item.taskRejected, isFalse);
  });

  test('conflicto: "enviar la mía" manda tarea y % juntos aunque solo cambie el %', () async {
    await db
        .into(db.visits)
        .insert(
          VisitsCompanion.insert(
            id: 'visit-1',
            orgId: 'org-1',
            version: 1,
            templateVersionId: 'tv-1',
            answersJson: '{}',
            capturedAt: DateTime.utc(2026, 11, 1),
            deviceId: 'device-1',
            createdBy: 'user-1',
            taskId: const Value('task-1'),
            progressPct: const Value(50.0),
          ),
        );
    await engine.enqueueVisitOp(
      entityId: 'visit-1',
      opType: 'update',
      baseVersion: 1,
      payload: {'id': 'visit-1', 'task_id': 'task-1', 'progress_pct': 50.0},
    );
    await pushWith(
      (op) => PushOpOutcome(
        opUuid: op.opUuid,
        status: 'conflict',
        serverVersion: 3,
        serverRow: {
          'entity': 'visit',
          'data': {
            'id': 'visit-1',
            'org_id': 'org-1',
            'version': 3,
            'change_seq': 9,
            'deleted_at': null,
            'assignment_id': null,
            'template_version_id': 'tv-1',
            'answers': <String, dynamic>{},
            'lat': null,
            'lon': null,
            'accuracy_m': null,
            'altitude_m': null,
            'captured_at': '2026-11-01T00:00:00.000Z',
            'device_id': 'device-1',
            'created_by': 'user-1',
            'task_id': 'task-1',
            'progress_pct': 30.0,
          },
        },
      ),
    );
    final item = (await service.list(orgId: 'org-1')).single;

    await service.resendMine(item);

    final op = await db.select(db.outboxOps).getSingle();
    expect(op.baseVersion, 3);
    expect(jsonDecode(op.payloadJson), {'id': 'visit-1', 'task_id': 'task-1', 'progress_pct': 50.0});
  });


  /// Conflicto sobre una edición del agente: [payload] es lo que editó; la
  /// visita local lleva task-1 al 50 % y el servidor task-2 al 30 %.
  Future<QuarantinedVisit> conflictOnEdit(Map<String, Object?> payload) async {
    await db
        .into(db.visits)
        .insert(
          VisitsCompanion.insert(
            id: 'visit-1',
            orgId: 'org-1',
            version: 1,
            templateVersionId: 'tv-1',
            answersJson: '{"notas":"mía"}',
            capturedAt: DateTime.utc(2026, 11, 1),
            deviceId: 'device-1',
            createdBy: 'user-1',
            taskId: const Value('task-1'),
            progressPct: const Value(50.0),
          ),
        );
    await engine.enqueueVisitOp(entityId: 'visit-1', opType: 'update', baseVersion: 1, payload: {'id': 'visit-1', ...payload});
    await pushWith(
      (op) => PushOpOutcome(
        opUuid: op.opUuid,
        status: 'conflict',
        serverVersion: 3,
        serverRow: {
          'entity': 'visit',
          'data': {
            'id': 'visit-1',
            'org_id': 'org-1',
            'version': 3,
            'change_seq': 9,
            'deleted_at': null,
            'assignment_id': null,
            'template_version_id': 'tv-1',
            'answers': {'notas': 'del servidor'},
            'lat': null,
            'lon': null,
            'accuracy_m': null,
            'altitude_m': null,
            'captured_at': '2026-11-01T00:00:00.000Z',
            'device_id': 'device-1',
            'created_by': 'user-1',
            'task_id': 'task-2',
            'progress_pct': 30.0,
          },
        },
      ),
    );
    return (await service.list(orgId: 'org-1')).single;
  }

  test('conflicto: si el agente no tocó la tarea, "enviar la mía" no la manda', () async {
    final item = await conflictOnEdit({'answers': {'notas': 'mía'}});
    expect(item.editedTask, isFalse);
    expect([for (final d in item.differences) d.field], ['notas']);

    await service.resendMine(item);

    final op = await db.select(db.outboxOps).getSingle();
    expect(jsonDecode(op.payloadJson), {'id': 'visit-1', 'answers': {'notas': 'mía'}});
  });

  test('conflicto: si el agente editó la tarea, "enviar la mía" la manda con su %', () async {
    final item = await conflictOnEdit({'task_id': 'task-1', 'progress_pct': 50.0});
    expect(item.editedTask, isTrue);

    await service.resendMine(item);

    final op = await db.select(db.outboxOps).getSingle();
    final payload = jsonDecode(op.payloadJson) as Map<String, dynamic>;
    expect(payload['task_id'], 'task-1');
    expect(payload['progress_pct'], 50.0);
  });

  test('conflicto: las diferencias de tarea y % se leen con EDT, nombre y porcentaje', () async {
    await db.replaceScheduleTasks(
      orgId: 'org-1',
      userId: 'user-1',
      version: 'v1',
      now: DateTime.utc(2026, 11, 2),
      rows: [
        for (final (i, (id, wbs, name)) in [('task-1', '1.1', 'Localización'), ('task-2', '1.2', 'Descapote')].indexed)
          ScheduleTasksCompanion.insert(
            id: id,
            orgId: 'org-1',
            userId: 'user-1',
            projectId: 'p-1',
            projectName: 'Obra Norte',
            wbs: wbs,
            outlineNumber: wbs,
            name: name,
            position: i,
          ),
      ],
    );
    final item = await conflictOnEdit({'task_id': 'task-1', 'progress_pct': 50.0});

    final byField = {for (final d in item.differences) d.field: d};
    expect(byField['task_id']!.mine, '1.1 Localización');
    expect(byField['task_id']!.server, '1.2 Descapote');
    expect(byField['progress_pct']!.mine, '50 %');
    expect(byField['progress_pct']!.server, '30 %');
  });


  test('rechazo por la tarea: las ediciones posteriores sin enviar también se desvinculan', () async {
    final capture = VisitCapture(db: db, idGenerator: () => 'cap-${ids++}');
    const me = CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1');
    final visitId = await capture.save(
      identity: me,
      templateVersionId: 'tv-1',
      definition: _definition,
      answers: {'notas': 'x'},
      captured: const {},
      progress: const TaskProgress(taskId: 'task-1', pct: 35),
    );
    // Solo el alta sale y es rechazada; la edición posterior queda pendiente.
    await pushWith(
      (op) => PushOpOutcome(
        opUuid: op.opUuid,
        status: 'rejected',
        error: const PushOpError(
          code: 'validation_error',
          message: 'The task was retired from the schedule.',
          details: {'field': 'task_id', 'reason': 'task_retired'},
        ),
      ),
    );
    await capture.update(
      identity: me,
      visitId: visitId,
      definition: _definition,
      answers: {'notas': 'x'},
      captured: const {},
      progress: (value: const TaskProgress(taskId: 'task-1', pct: 60)),
    );
    // La edición se rehúsa mientras hay algo en revisión: la insertamos a mano.
    expect(await db.select(db.outboxOps).get(), hasLength(1));
    await engine.enqueueVisitOp(
      entityId: visitId,
      opType: 'update',
      baseVersion: 2,
      payload: {'id': visitId, 'task_id': 'task-1', 'progress_pct': 60.0},
    );
    final item = (await service.list(orgId: 'org-1')).single;

    await service.unlinkTask(item);

    final ops = await db.select(db.outboxOps).get();
    expect(ops, hasLength(2));
    final create = jsonDecode(ops.first.payloadJson) as Map<String, dynamic>;
    final later = jsonDecode(ops.last.payloadJson) as Map<String, dynamic>;
    expect(create.containsKey('task_id'), isFalse);
    expect(later, {'id': visitId, 'task_id': null, 'progress_pct': null});
    expect(ops.every((op) => op.state == 'pending'), isTrue);
  });
}
