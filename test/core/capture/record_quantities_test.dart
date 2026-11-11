// Costos, pieza 4b: un registro de una tarea medida por cantidades guarda sus filas sin
// red y las envía con `progress_pct: null`; una tarea por % sigue sin `quantities`.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/capture/record_capture.dart';
import 'package:suno/core/forms/form_definition.dart';
import 'package:suno/data/local/database.dart';

const _me = CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1');

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

Map<String, Object?> _row(double quantity, {String clientId = 'c-1'}) => {
  'item_id': 'item-1',
  'location_id': null,
  'quantity': quantity,
  'note': '',
  'client_id': clientId,
  'captured_at': '2026-11-09T14:00:00.000Z',
  'gps': null,
  'seen': {'planned': 10.0, 'validated': 4.0, 'location_id': null},
  'location_mode': 'task',
};

void main() {
  late AppDatabase db;
  late RecordCapture capture;
  var ids = 0;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ids = 0;
    capture = RecordCapture(db: db, idGenerator: () => 'id-${ids++}', clock: () => DateTime.utc(2026, 11, 9, 10));
  });
  tearDown(() => db.close());

  Future<Map<String, dynamic>> lastPayload() async {
    final ops = await db.select(db.outboxOps).get();
    return jsonDecode(ops.last.payloadJson) as Map<String, dynamic>;
  }

  Future<Record> recordOf(String id) => (db.select(db.records)..where((t) => t.id.equals(id))).getSingle();

  Future<String> saveWith(TaskProgress progress) => capture.save(
    identity: _me,
    templateVersionId: 'tv-1',
    definition: _definition,
    answers: {'notas': 'x'},
    captured: const {},
    progress: progress,
  );

  Future<RecordChange> edit(String recordId, ({TaskProgress? value}) progress) => capture.update(
    identity: _me,
    recordId: recordId,
    definition: _definition,
    answers: {'notas': 'x'},
    captured: const {},
    progress: progress,
  );

  test('alta por cantidades: viajan con progress_pct null y quedan en el registro', () async {
    final recordId = await saveWith(TaskProgress(taskId: 'task-1', quantities: [_row(3)]));
    final payload = await lastPayload();
    expect((payload['task_id'], payload['progress_pct']), ('task-1', null));
    expect(payload['quantities'], [_row(3)]);
    final record = await recordOf(recordId);
    expect(record.progressPct, isNull);
    expect(jsonDecode(record.quantitiesJson), [_row(3)]);
  });

  test('alta por %: sin la clave quantities y el registro con []', () async {
    final recordId = await saveWith(const TaskProgress(taskId: 'task-1', pct: 35));
    expect((await lastPayload()).containsKey('quantities'), isFalse);
    expect((await recordOf(recordId)).quantitiesJson, '[]');
  });

  test('editar sin cambiar las cantidades no envía nada', () async {
    final recordId = await saveWith(TaskProgress(taskId: 'task-1', quantities: [_row(3)]));
    final change = await edit(recordId, (
      value: TaskProgress(
        taskId: 'task-1',
        quantities: [_row(3, clientId: 'otro')],
      ),
    ));
    expect(change, RecordChange.unchanged);
  });

  test('cambiar una cantidad envía la tarea, el % y las cantidades', () async {
    final recordId = await saveWith(TaskProgress(taskId: 'task-1', quantities: [_row(3)]));
    expect(await edit(recordId, (value: TaskProgress(taskId: 'task-1', quantities: [_row(4)]))), RecordChange.saved);
    expect(await lastPayload(), {
      'id': recordId,
      'task_id': 'task-1',
      'progress_pct': null,
      'quantities': [_row(4)],
    });
    expect(jsonDecode((await recordOf(recordId)).quantitiesJson), [_row(4)]);
  });

  test('pasar a una tarea por % vacía las cantidades', () async {
    final recordId = await saveWith(TaskProgress(taskId: 'task-1', quantities: [_row(3)]));
    await edit(recordId, (value: const TaskProgress(taskId: 'task-2', pct: 20)));
    expect(await lastPayload(), {'id': recordId, 'task_id': 'task-2', 'progress_pct': 20.0});
    expect((await recordOf(recordId)).quantitiesJson, '[]');
  });
}
