import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/data/local/schedule_task_repository.dart';

const _items = [
  ScheduleTaskItem(id: 'a', projectName: 'Obra Norte', code: '1.2', name: 'Descapote', lastValidatedPct: null),
  ScheduleTaskItem(id: 'b', projectName: 'Obra Sur', code: '2.1', name: 'Excavación de zanjas', lastValidatedPct: 10),
];

void main() {
  test('busca por EDT, nombre o proyecto, sin tildes ni mayúsculas', () {
    expect(searchScheduleTasks(_items, '  '), _items);
    expect(searchScheduleTasks(_items, 'EXCAVACION').single.id, 'b');
    expect(searchScheduleTasks(_items, '1.2').single.id, 'a');
    expect(searchScheduleTasks(_items, 'sur').single.id, 'b');
    expect(searchScheduleTasks(_items, 'zzz'), isEmpty);
  });

  test('forUser: solo las del usuario y su organización, en el orden recibido', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    ScheduleTasksCompanion row(String id, String user, int position, {String org = 'org-1'}) =>
        ScheduleTasksCompanion.insert(
          id: id,
          orgId: org,
          userId: user,
          projectId: 'p-1',
          projectName: 'Obra Norte',
          wbs: '',
          outlineNumber: '1.$position',
          name: 'Tarea $id',
          lastValidatedPct: const Value(null),
          position: position,
        );
    await db.batch(
      (b) => b.insertAll(db.scheduleTasks, [
        row('z', 'ana', 2),
        row('y', 'ana', 1),
        row('x', 'beto', 0),
        row('w', 'ana', 0, org: 'org-2'),
      ]),
    );
    final items = await ScheduleTaskRepository(db).forUser(orgId: 'org-1', userId: 'ana');
    expect([for (final i in items) i.label], ['1.1 Tarea y', '1.2 Tarea z'], reason: 'sin EDT se usa el número de esquema');
  });
}
