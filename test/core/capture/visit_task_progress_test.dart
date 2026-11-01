// Costos, etapa 1: la visita guarda su tarea y su % sin red, y viajan juntos
// por el outbox; en una edición solo viajan si cambian.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/data/local/database.dart';

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
  late VisitCapture capture;
  var ids = 0;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ids = 0;
    capture = VisitCapture(db: db, idGenerator: () => 'id-${ids++}', clock: () => DateTime.utc(2026, 11, 2, 10));
  });
  tearDown(() => db.close());

  Future<Map<String, dynamic>> lastPayload() async {
    final ops = await db.select(db.outboxOps).get();
    return jsonDecode(ops.last.payloadJson) as Map<String, dynamic>;
  }

  Future<Visit> visitOf(String id) => (db.select(db.visits)..where((t) => t.id.equals(id))).getSingle();

  Future<String> saveLinked() => capture.save(
    identity: _me,
    templateVersionId: 'tv-1',
    definition: _definition,
    answers: {'notas': 'x'},
    captured: const {},
    progress: const TaskProgress(taskId: 'task-1', pct: 35.5),
  );

  Future<VisitChange> edit(String visitId, {({TaskProgress? value})? progress}) => capture.update(
    identity: _me,
    visitId: visitId,
    definition: _definition,
    answers: {'notas': 'x'},
    captured: const {},
    progress: progress,
  );

  test('alta: la tarea y el % se guardan y viajan juntos', () async {
    final visitId = await saveLinked();
    final visit = await visitOf(visitId);
    expect((visit.taskId, visit.progressPct), ('task-1', 35.5));
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
    final visitId = await saveLinked();
    expect(await edit(visitId, progress: (value: const TaskProgress(taskId: 'task-1', pct: 50))), VisitChange.saved);
    expect(await lastPayload(), {'id': visitId, 'task_id': 'task-1', 'progress_pct': 50.0});
    expect(await edit(visitId, progress: (value: const TaskProgress(taskId: 'task-1', pct: 50))), VisitChange.unchanged);
  });

  test('edición: sin `progress` no se toca; con `null` se desvincula', () async {
    final visitId = await saveLinked();
    expect(await edit(visitId), VisitChange.unchanged);
    expect(await edit(visitId, progress: (value: null)), VisitChange.saved);
    expect(await lastPayload(), {'id': visitId, 'task_id': null, 'progress_pct': null});
    final visit = await visitOf(visitId);
    expect((visit.taskId, visit.progressPct), (null, null));
  });
}
