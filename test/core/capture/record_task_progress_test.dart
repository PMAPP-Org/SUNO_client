// Costos, etapa 1: el registro guarda su tarea y su % sin red, y viajan juntos
// por el outbox; en una edición solo viajan si cambian.
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

void main() {
  late AppDatabase db;
  late RecordCapture capture;
  var ids = 0;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ids = 0;
    capture = RecordCapture(db: db, idGenerator: () => 'id-${ids++}', clock: () => DateTime.utc(2026, 11, 2, 10));
  });
  tearDown(() => db.close());

  Future<Map<String, dynamic>> lastPayload() async {
    final ops = await db.select(db.outboxOps).get();
    return jsonDecode(ops.last.payloadJson) as Map<String, dynamic>;
  }

  Future<Record> recordOf(String id) => (db.select(db.records)..where((t) => t.id.equals(id))).getSingle();

  Future<String> saveLinked() => capture.save(
    identity: _me,
    templateVersionId: 'tv-1',
    definition: _definition,
    answers: {'notas': 'x'},
    captured: const {},
    progress: const TaskProgress(taskId: 'task-1', pct: 35.5),
  );

  Future<RecordChange> edit(String recordId, {({TaskProgress? value})? progress}) => capture.update(
    identity: _me,
    recordId: recordId,
    definition: _definition,
    answers: {'notas': 'x'},
    captured: const {},
    progress: progress,
  );

  test('alta: la tarea y el % se guardan y viajan juntos', () async {
    final recordId = await saveLinked();
    final record = await recordOf(recordId);
    expect((record.taskId, record.progressPct), ('task-1', 35.5));
    final payload = await lastPayload();
    expect((payload['task_id'], payload['progress_pct']), ('task-1', 35.5));
  });

  test('alta sin tarea: el payload no lleva los campos', () async {
    await capture.save(
      identity: _me,
      templateVersionId: 'tv-1',
      definition: _definition,
      answers: {'notas': 'x'},
      captured: const {},
    );
    final payload = await lastPayload();
    expect(payload.containsKey('task_id'), isFalse);
    expect(payload.containsKey('progress_pct'), isFalse);
  });

  test('edición: cambiar el % envía el par; repetirlo no envía nada', () async {
    final recordId = await saveLinked();
    expect(await edit(recordId, progress: (value: const TaskProgress(taskId: 'task-1', pct: 50))), RecordChange.saved);
    expect(await lastPayload(), {'id': recordId, 'task_id': 'task-1', 'progress_pct': 50.0});
    expect(await edit(recordId, progress: (value: const TaskProgress(taskId: 'task-1', pct: 50))), RecordChange.unchanged);
  });

  test('edición: sin `progress` no se toca; con `null` se desvincula', () async {
    final recordId = await saveLinked();
    expect(await edit(recordId), RecordChange.unchanged);
    expect(await edit(recordId, progress: (value: null)), RecordChange.saved);
    expect(await lastPayload(), {'id': recordId, 'task_id': null, 'progress_pct': null});
    final record = await recordOf(recordId);
    expect((record.taskId, record.progressPct), (null, null));
  });
}
