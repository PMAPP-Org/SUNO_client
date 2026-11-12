// Migración de la base local 1 → 2 (costos, pieza 4b): columnas y tablas nuevas, sin
// perder registros ni tareas, y la lista de tareas vuelve a bajarse entera.
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/data/local/database.dart';

import 'generated/schema.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('1 → 2: el esquema queda igual al de una instalación nueva', () async {
    final schema = await verifier.schemaAt(1);
    final db = AppDatabase.forTesting(schema.newConnection());
    await verifier.migrateAndValidate(db, 2);
    await db.close();
  });

  test('1 → 2: conserva registros y tareas, con los valores por defecto nuevos', () async {
    final schema = await verifier.schemaAt(1);
    schema.rawDatabase
      ..execute(
        "INSERT INTO records (id, org_id, version, template_version_id, answers_json, captured_at, "
        "device_id, created_by, task_id, progress_pct) "
        "VALUES ('r-1', 'org-1', 1, 'tv-1', '{}', 1762500000, 'd-1', 'u-1', 't-1', 40.0)",
      )
      ..execute(
        "INSERT INTO schedule_tasks (id, org_id, user_id, project_id, project_name, wbs, "
        "outline_number, name, position) "
        "VALUES ('t-1', 'org-1', 'u-1', 'p-1', 'Obra', '1.1', '1.1', 'Excavación', 0)",
      )
      ..execute(
        "INSERT INTO schedule_task_state (id, org_id, user_id, version, updated_at) "
        "VALUES (0, 'org-1', 'u-1', 'v1', 1762500000)",
      );
    final db = AppDatabase.forTesting(schema.newConnection());
    await verifier.migrateAndValidate(db, 2);

    final record = await db.select(db.records).getSingle();
    expect((record.id, record.progressPct, record.quantitiesJson, record.knownValidated), ('r-1', 40.0, '[]', false));
    final task = await db.select(db.scheduleTasks).getSingle();
    expect((task.id, task.measuredBy), ('t-1', 'pct'));
    expect(await db.readScheduleTaskState(), isNull);
    expect(await db.select(db.taskPlannedItems).get(), isEmpty);
    await db.close();
  });
}
