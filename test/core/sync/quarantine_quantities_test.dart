// Costos, pieza 4b: `item_not_in_project` y `location_outside_task` llevan el registro a
// "Para revisar" con la fila señalada (el teléfono la identifica: el rechazo no dice
// cuál); corregir reescribe las cantidades y reenvía; quitar la tarea las vacía.
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/capture/record_capture.dart';
import 'package:suno/core/forms/form_definition.dart';
import 'package:suno/core/schedule/quantity_rows.dart';
import 'package:suno/core/sync/quarantine_service.dart';
import 'package:suno/core/sync/result.dart';
import 'package:suno/core/sync/sync_engine.dart';
import 'package:suno/core/sync/sync_transport.dart';
import 'package:suno/data/local/database.dart';

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

Map<String, Object?> _row(String clientId, String itemId, {String? location, String note = ''}) => {
  'item_id': itemId,
  'location_id': location,
  'quantity': 2.0,
  'note': note,
  'client_id': clientId,
  'captured_at': '2026-11-09T14:00:00.000Z',
  'gps': null,
  'seen': null,
  'location_mode': location == null ? 'task' : 'refined',
};

void main() {
  late AppDatabase db;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late QuarantineService service;
  var ids = 0;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeSyncTransport();
    ids = 0;
    engine = SyncEngine(db: db, transport: transport, deviceId: 'device-1', idGenerator: () => 'op-${ids++}');
    service = QuarantineService(db: db, engine: engine, clock: () => DateTime.utc(2026, 11, 9));
    await db.replaceScheduleTasks(
      orgId: 'org-1',
      userId: 'user-1',
      version: 'v1',
      now: DateTime.utc(2026, 11, 9),
      rows: [
        ScheduleTasksCompanion.insert(
          id: 'task-1',
          orgId: 'org-1',
          userId: 'user-1',
          projectId: 'p-1',
          projectName: 'Obra',
          wbs: '1.2',
          outlineNumber: '1.2',
          name: 'Descapote',
          position: 0,
          measuredBy: const Value('quantities'),
        ),
      ],
      planned: [
        TaskPlannedItemsCompanion.insert(
          taskId: 'task-1',
          itemId: 'item-1',
          code: '2.1',
          description: 'Concreto zapatas',
          unit: 'm3',
          plannedQuantity: 10,
          validatedQuantity: 0,
          position: 0,
        ),
      ],
      locations: [
        TaskLocationOptionsCompanion.insert(
          taskId: 'task-1',
          locationId: 'loc-1',
          label: 'Tramo 2',
          isTaskLocation: true,
          position: 0,
        ),
      ],
      catalog: [
        ProjectItemsCompanion.insert(
          projectId: 'p-1',
          itemId: 'item-1',
          code: '2.1',
          description: 'Concreto zapatas',
          unit: 'm3',
          position: 0,
        ),
        ProjectItemsCompanion.insert(
          projectId: 'p-1',
          itemId: 'item-2',
          code: '2.2',
          description: 'Acero',
          unit: 'kg',
          position: 1,
        ),
      ],
    );
    // El 9.9 se vio en otra descarga y ya no está en el catálogo.
    await db
        .into(db.knownItems)
        .insert(KnownItemsCompanion.insert(itemId: 'item-9', code: '9.9', description: 'Retirado', unit: 'un'));
    await RecordCapture(db: db, idGenerator: () => 'cap-${ids++}').save(
      identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: _definition,
      answers: {'notas': 'x'},
      captured: const {},
      progress: TaskProgress(
        taskId: 'task-1',
        quantities: [
          _row('q-1', 'item-1'),
          _row('q-2', 'item-9', note: 'viejo'),
          _row('q-3', 'item-1', location: 'loc-x'),
        ],
      ),
    );
  });
  tearDown(() => db.close());

  Future<void> rejectWith(String reason, {String field = 'quantities'}) async {
    final op = await db.select(db.outboxOps).getSingle();
    transport.pushResponses.add(
      Result.ok(
        PushResponse(
          schemaVersion: 2,
          results: [
            PushOpOutcome(
              opUuid: op.opUuid,
              status: 'rejected',
              error: PushOpError(
                code: 'validation_error',
                message: 'Rejected.',
                details: {'field': field, 'reason': reason},
              ),
            ),
          ],
        ),
      ),
    );
    await engine.drainOutbox();
  }

  test('item_not_in_project señala la fila del ítem fuera del plan y del catálogo', () async {
    await rejectWith('item_not_in_project');
    final item = (await service.list(orgId: 'org-1')).single;
    expect(item.quantityRejected, isTrue);
    expect(item.quantityFlags, [(index: 1, code: '9.9', reason: 'item_not_in_project')]);
  });

  test('location_outside_task señala la fila con una ubicación que no es de la tarea', () async {
    await rejectWith('location_outside_task');
    final item = (await service.list(orgId: 'org-1')).single;
    expect(item.quantityFlags, [(index: 2, code: '2.1', reason: 'location_outside_task')]);
  });

  test('corregir reescribe las cantidades del registro y de la operación, y la reenvía', () async {
    await rejectWith('item_not_in_project');
    final item = (await service.list(orgId: 'org-1')).single;
    final rows = decodeQuantities(item.record.quantitiesJson);
    final fixed = [
      rows[0],
      {...rows[1], 'item_id': 'item-2', 'note': 'reasignado'},
      rows[2],
    ];
    await service.correctQuantities(item, fixed);
    final op = await db.select(db.outboxOps).getSingle();
    expect(op.state, 'pending');
    expect((jsonDecode(op.payloadJson) as Map)['quantities'], fixed);
    expect(decodeQuantities((await db.select(db.records).getSingle()).quantitiesJson), fixed);
  });

  test('quitar la tarea también quita las cantidades', () async {
    await rejectWith('task_retired', field: 'task_id');
    final item = (await service.list(orgId: 'org-1')).single;
    expect(item.taskRejected, isTrue);
    await service.unlinkTask(item);
    final payload = jsonDecode((await db.select(db.outboxOps).getSingle()).payloadJson) as Map<String, dynamic>;
    expect(payload.containsKey('quantities'), isFalse);
    expect((await db.select(db.records).getSingle()).quantitiesJson, '[]');
  });

  test('un rechazo record_validated no es una corrección de filas', () async {
    await rejectWith('record_validated');
    final item = (await service.list(orgId: 'org-1')).single;
    expect((item.recordValidated, item.quantityRejected), (true, false));
    expect(item.quantityFlags, isEmpty);
  });
}
