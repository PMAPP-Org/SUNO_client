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
}
