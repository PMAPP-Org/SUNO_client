// Regla operativa del Paso 11: ninguna migración destructiva sin un test de
// upgrade N-1→N con datos de ejemplo. Primera migración real: v1 (Paso 11)
// → v2 (Paso 12, añade `sync_cursor` y `outbox_ops.error_message`).
//
// Recrea el esquema v1 con SQL crudo (idéntico al que generaba
// `MigrationStrategy.onCreate` antes de este paso), inserta datos de
// ejemplo, y abre esa misma conexión con el `AppDatabase` real declarando
// `schemaVersion=2` — Drift detecta la diferencia de `user_version` y corre
// `onUpgrade`. Verifica que los datos v1 sobreviven intactos y que lo nuevo
// existe y es usable.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:visitacampo/core/sync/quarantine_service.dart';
import 'package:visitacampo/core/sync/sync_engine.dart';
import 'package:visitacampo/data/local/database.dart';

import '../../core/sync/fake_sync_transport.dart';

void main() {
  test('v1 → v2: los datos existentes sobreviven, sync_cursor queda disponible', () async {
    final raw = sqlite3.sqlite3.openInMemory();
    addTearDown(raw.close);

    // Esquema v1 (Paso 11) reconstruido a mano — deliberadamente independiente
    // de `tables.dart` actual: si este test importara las tablas de hoy para
    // "recrear v1", dejaría de probar una migración real y empezaría a
    // probar un no-op.
    raw.execute('''
      CREATE TABLE visits (
        id TEXT NOT NULL PRIMARY KEY,
        org_id TEXT NOT NULL,
        version INTEGER NOT NULL,
        change_seq INTEGER NULL,
        deleted_at INTEGER NULL,
        template_version_id TEXT NOT NULL,
        answers_json TEXT NOT NULL,
        lat REAL NULL,
        lon REAL NULL,
        accuracy_m REAL NULL,
        altitude_m REAL NULL,
        captured_at INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        created_by TEXT NOT NULL
      );
      CREATE TABLE outbox_ops (
        op_uuid TEXT NOT NULL PRIMARY KEY,
        entity TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        op_type TEXT NOT NULL,
        base_version INTEGER NULL,
        payload_json TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE attachment_queue (
        sha256 TEXT NOT NULL PRIMARY KEY,
        local_path TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
    ''');
    raw.execute('PRAGMA user_version = 1;');

    raw.execute(
      'INSERT INTO visits (id, org_id, version, change_seq, template_version_id, answers_json, '
      'captured_at, device_id, created_by) VALUES '
      "('visit-1', 'org-1', 1, 42, 'template-1', '{}', 1767225600, 'device-1', 'user-1');",
    );
    raw.execute(
      "INSERT INTO outbox_ops (op_uuid, entity, entity_id, op_type, payload_json, state, created_at) "
      "VALUES ('op-1', 'visit', 'visit-1', 'create', '{}', 'pending', 1767225600);",
    );

    final db = AppDatabase.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    // Abrir ya dispara la migración (Drift la corre en el primer acceso).
    final visit = await (db.select(db.visits)..where((t) => t.id.equals('visit-1'))).getSingle();
    expect(visit.orgId, 'org-1', reason: 'los datos de v1 sobreviven la migración sin cambios');
    expect(visit.changeSeq, 42);

    final op = await (db.select(db.outboxOps)..where((t) => t.opUuid.equals('op-1'))).getSingle();
    expect(op.state, 'pending');
    expect(op.errorMessage, isNull, reason: 'columna nueva, sin valor previo: null por defecto');

    // La tabla nueva existe y es usable de inmediato.
    expect(await db.readCursor(), isNull);
    await db.writeCursor('c1:00000000000000000001', now: DateTime.utc(2026, 1, 1));
    expect(await db.readCursor(), 'c1:00000000000000000001');
  });

  test('v2 → v3: visitas, outbox y cursor sobreviven; la caché de plantillas queda disponible', () async {
    final raw = sqlite3.sqlite3.openInMemory();
    addTearDown(raw.close);

    // Esquema v2 (Paso 12) a mano, por el mismo motivo que el test anterior.
    raw.execute('''
      CREATE TABLE visits (
        id TEXT NOT NULL PRIMARY KEY,
        org_id TEXT NOT NULL,
        version INTEGER NOT NULL,
        change_seq INTEGER NULL,
        deleted_at INTEGER NULL,
        template_version_id TEXT NOT NULL,
        answers_json TEXT NOT NULL,
        lat REAL NULL,
        lon REAL NULL,
        accuracy_m REAL NULL,
        altitude_m REAL NULL,
        captured_at INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        created_by TEXT NOT NULL
      );
      CREATE TABLE outbox_ops (
        op_uuid TEXT NOT NULL PRIMARY KEY,
        entity TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        op_type TEXT NOT NULL,
        base_version INTEGER NULL,
        payload_json TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        error_message TEXT NULL
      );
      CREATE TABLE attachment_queue (
        sha256 TEXT NOT NULL PRIMARY KEY,
        local_path TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE sync_cursor (
        id INTEGER NOT NULL PRIMARY KEY,
        cursor TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      );
    ''');
    raw.execute('PRAGMA user_version = 2;');
    raw.execute(
      'INSERT INTO visits (id, org_id, version, change_seq, template_version_id, answers_json, '
      'captured_at, device_id, created_by) VALUES '
      "('visit-1', 'org-1', 3, 77, 'template-1', '{\"altura_cm\": 42}', 1767225600, 'device-1', 'user-1');",
    );
    raw.execute(
      "INSERT INTO outbox_ops (op_uuid, entity, entity_id, op_type, payload_json, state, created_at, error_message) "
      "VALUES ('op-1', 'visit', 'visit-1', 'update', '{}', 'quarantine', 1767225600, 'validation_error');",
    );
    raw.execute("INSERT INTO sync_cursor (id, cursor, updated_at) VALUES (0, 'c1:00000000000000000077', 1767225600);");

    final db = AppDatabase.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final visit = await (db.select(db.visits)..where((t) => t.id.equals('visit-1'))).getSingle();
    expect(visit.answersJson, '{"altura_cm": 42}');
    final op = await (db.select(db.outboxOps)..where((t) => t.opUuid.equals('op-1'))).getSingle();
    expect(op.errorMessage, 'validation_error');
    // Sobrevive hasta v7; el paso v7 → v8 lo reinicia a propósito para
    // recibir las asignaciones que el pull descartaba (ver el test v7 → v8).
    expect(await db.readCursor(), isNull);

    await db
        .into(db.formTemplateVersions)
        .insert(
          FormTemplateVersionsCompanion.insert(
            id: 'v-1',
            orgId: 'org-1',
            templateId: 't-1',
            versionNumber: 1,
            definitionJson: '{"fields": []}',
            version: 1,
          ),
        );
    expect(await db.select(db.formTemplateVersions).get(), hasLength(1));
  });

  test('v3 → v4: la cola de subida conserva sus fotos (JPEG) y nace la tabla de adjuntos', () async {
    final raw = sqlite3.sqlite3.openInMemory();
    addTearDown(raw.close);

    // Esquema v3 (Paso 21) a mano: v2 + `form_template_versions`.
    raw.execute('''
      CREATE TABLE visits (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL, deleted_at INTEGER NULL, template_version_id TEXT NOT NULL,
        answers_json TEXT NOT NULL, lat REAL NULL, lon REAL NULL, accuracy_m REAL NULL,
        altitude_m REAL NULL, captured_at INTEGER NOT NULL, device_id TEXT NOT NULL,
        created_by TEXT NOT NULL
      );
      CREATE TABLE outbox_ops (
        op_uuid TEXT NOT NULL PRIMARY KEY, entity TEXT NOT NULL, entity_id TEXT NOT NULL,
        op_type TEXT NOT NULL, base_version INTEGER NULL, payload_json TEXT NOT NULL,
        state TEXT NOT NULL, created_at INTEGER NOT NULL, error_message TEXT NULL
      );
      CREATE TABLE attachment_queue (
        sha256 TEXT NOT NULL PRIMARY KEY, local_path TEXT NOT NULL, state TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE sync_cursor (id INTEGER NOT NULL PRIMARY KEY, cursor TEXT NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE form_template_versions (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, template_id TEXT NOT NULL,
        version_number INTEGER NOT NULL, name TEXT NULL, definition_json TEXT NOT NULL,
        published_at INTEGER NULL, deleted_at INTEGER NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL
      );
    ''');
    raw.execute('PRAGMA user_version = 3;');
    raw.execute(
      "INSERT INTO attachment_queue (sha256, local_path, state, created_at) "
      "VALUES ('${'c' * 64}', '/fotos/1.jpg', 'pending', 1767225600);",
    );

    final db = AppDatabase.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final upload = await db.select(db.attachmentQueue).getSingle();
    expect(upload.localPath, '/fotos/1.jpg');
    expect(upload.mime, 'image/jpeg', reason: 'antes de v4 solo había fotos de cámara (JPEG)');

    await db
        .into(db.visitAttachments)
        .insert(
          VisitAttachmentsCompanion.insert(
            id: 'att-1',
            orgId: 'org-1',
            visitId: 'visit-1',
            sha256: 'c' * 64,
            role: 'foto',
            capturedAt: DateTime.utc(2026, 10, 17),
            position: 0,
          ),
        );
    expect(await db.select(db.visitAttachments).get(), hasLength(1));
  });

  test('v4 → v5: las subidas encoladas conservan su estado y empiezan sin backoff', () async {
    final raw = sqlite3.sqlite3.openInMemory();
    addTearDown(raw.close);

    // Esquema v4 (Paso 22) a mano: solo las tablas que esta migración toca o
    // necesita para abrir; `createAll` no se ejecuta en un upgrade.
    raw.execute('''
      CREATE TABLE visits (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL, deleted_at INTEGER NULL, template_version_id TEXT NOT NULL,
        answers_json TEXT NOT NULL, lat REAL NULL, lon REAL NULL, accuracy_m REAL NULL,
        altitude_m REAL NULL, captured_at INTEGER NOT NULL, device_id TEXT NOT NULL,
        created_by TEXT NOT NULL
      );
      CREATE TABLE outbox_ops (
        op_uuid TEXT NOT NULL PRIMARY KEY, entity TEXT NOT NULL, entity_id TEXT NOT NULL,
        op_type TEXT NOT NULL, base_version INTEGER NULL, payload_json TEXT NOT NULL,
        state TEXT NOT NULL, created_at INTEGER NOT NULL, error_message TEXT NULL
      );
      CREATE TABLE attachment_queue (
        sha256 TEXT NOT NULL PRIMARY KEY, local_path TEXT NOT NULL, state TEXT NOT NULL,
        created_at INTEGER NOT NULL, mime TEXT NOT NULL DEFAULT 'image/jpeg'
      );
      CREATE TABLE sync_cursor (id INTEGER NOT NULL PRIMARY KEY, cursor TEXT NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE form_template_versions (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, template_id TEXT NOT NULL,
        version_number INTEGER NOT NULL, name TEXT NULL, definition_json TEXT NOT NULL,
        published_at INTEGER NULL, deleted_at INTEGER NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL
      );
      CREATE TABLE visit_attachments (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, visit_id TEXT NOT NULL,
        sha256 TEXT NOT NULL, role TEXT NOT NULL, caption TEXT NULL, captured_at INTEGER NOT NULL,
        position INTEGER NOT NULL, version INTEGER NULL, change_seq INTEGER NULL
      );
    ''');
    raw.execute('PRAGMA user_version = 4;');
    raw.execute(
      "INSERT INTO attachment_queue (sha256, local_path, state, created_at, mime) VALUES "
      "('${'a' * 64}', '/firmas/1.png', 'failed', 1767225600, 'image/png'), "
      "('${'b' * 64}', '/fotos/2.jpg', 'pending', 1767225600, 'image/jpeg');",
    );

    final db = AppDatabase.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final rows = {for (final r in await db.select(db.attachmentQueue).get()) r.sha256: r};
    expect((rows['a' * 64]!.state, rows['a' * 64]!.mime), ('failed', 'image/png'), reason: 'los datos de v4 sobreviven');
    expect(rows['b' * 64]!.state, 'pending');
    for (final r in rows.values) {
      expect((r.attempts, r.nextAttemptAt, r.lastError), (0, null, null), reason: 'sin backoff heredado');
    }
  });

  test('v5 → v6: una op ya en cuarentena conserva su motivo y queda revisable', () async {
    final raw = sqlite3.sqlite3.openInMemory();
    addTearDown(raw.close);

    // Esquema v5 (Paso 18): v4 + reintento de la cola de subida.
    raw.execute('''
      CREATE TABLE visits (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL, deleted_at INTEGER NULL, template_version_id TEXT NOT NULL,
        answers_json TEXT NOT NULL, lat REAL NULL, lon REAL NULL, accuracy_m REAL NULL,
        altitude_m REAL NULL, captured_at INTEGER NOT NULL, device_id TEXT NOT NULL,
        created_by TEXT NOT NULL
      );
      CREATE TABLE outbox_ops (
        op_uuid TEXT NOT NULL PRIMARY KEY, entity TEXT NOT NULL, entity_id TEXT NOT NULL,
        op_type TEXT NOT NULL, base_version INTEGER NULL, payload_json TEXT NOT NULL,
        state TEXT NOT NULL, created_at INTEGER NOT NULL, error_message TEXT NULL
      );
      CREATE TABLE attachment_queue (
        sha256 TEXT NOT NULL PRIMARY KEY, local_path TEXT NOT NULL, state TEXT NOT NULL,
        created_at INTEGER NOT NULL, mime TEXT NOT NULL DEFAULT 'image/jpeg',
        attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NULL, last_error TEXT NULL
      );
      CREATE TABLE sync_cursor (id INTEGER NOT NULL PRIMARY KEY, cursor TEXT NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE form_template_versions (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, template_id TEXT NOT NULL,
        version_number INTEGER NOT NULL, name TEXT NULL, definition_json TEXT NOT NULL,
        published_at INTEGER NULL, deleted_at INTEGER NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL
      );
      CREATE TABLE visit_attachments (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, visit_id TEXT NOT NULL,
        sha256 TEXT NOT NULL, role TEXT NOT NULL, caption TEXT NULL, captured_at INTEGER NOT NULL,
        position INTEGER NOT NULL, version INTEGER NULL, change_seq INTEGER NULL
      );
    ''');
    raw.execute('PRAGMA user_version = 5;');
    raw.execute(
      "INSERT INTO visits (id, org_id, version, template_version_id, answers_json, captured_at, device_id, created_by) "
      "VALUES ('visit-1', 'org-1', 1, 'tv-1', '{}', 1767225600, 'device-1', 'user-1');",
    );
    raw.execute(
      "INSERT INTO outbox_ops (op_uuid, entity, entity_id, op_type, payload_json, state, created_at, error_message) "
      "VALUES ('op-1', 'visit', 'visit-1', 'create', '{\"id\": \"visit-1\"}', 'quarantine', 1767225600, 'Plantilla desconocida.');",
    );

    final db = AppDatabase.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final op = await db.select(db.outboxOps).getSingle();
    expect((op.state, op.errorMessage), ('quarantine', 'Plantilla desconocida.'));
    expect((op.errorCode, op.errorFieldsJson, op.serverRowJson), (null, null, null), reason: 'sin detalle previo');

    // Y la revisión la entiende como un rechazo sin campos que corregir.
    final item = (await QuarantineService(
      db: db,
      engine: SyncEngine(db: db, transport: FakeSyncTransport(), deviceId: 'device-1'),
    ).list(orgId: 'org-1')).single;
    expect((item.kind, item.canCorrect, item.message), (QuarantineKind.rejected, false, 'Plantilla desconocida.'));
  });

  test('v6 → v7: las visitas sobreviven y empiezan sin copia del servidor', () async {
    final raw = sqlite3.sqlite3.openInMemory();
    addTearDown(raw.close);

    // Esquema v6 (Paso 23): v5 + detalle de la cuarentena.
    raw.execute('''
      CREATE TABLE visits (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL, deleted_at INTEGER NULL, template_version_id TEXT NOT NULL,
        answers_json TEXT NOT NULL, lat REAL NULL, lon REAL NULL, accuracy_m REAL NULL,
        altitude_m REAL NULL, captured_at INTEGER NOT NULL, device_id TEXT NOT NULL,
        created_by TEXT NOT NULL
      );
      CREATE TABLE outbox_ops (
        op_uuid TEXT NOT NULL PRIMARY KEY, entity TEXT NOT NULL, entity_id TEXT NOT NULL,
        op_type TEXT NOT NULL, base_version INTEGER NULL, payload_json TEXT NOT NULL,
        state TEXT NOT NULL, created_at INTEGER NOT NULL, error_message TEXT NULL,
        error_code TEXT NULL, error_fields_json TEXT NULL, server_row_json TEXT NULL
      );
      CREATE TABLE attachment_queue (
        sha256 TEXT NOT NULL PRIMARY KEY, local_path TEXT NOT NULL, state TEXT NOT NULL,
        created_at INTEGER NOT NULL, mime TEXT NOT NULL DEFAULT 'image/jpeg',
        attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NULL, last_error TEXT NULL
      );
      CREATE TABLE sync_cursor (id INTEGER NOT NULL PRIMARY KEY, cursor TEXT NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE form_template_versions (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, template_id TEXT NOT NULL,
        version_number INTEGER NOT NULL, name TEXT NULL, definition_json TEXT NOT NULL,
        published_at INTEGER NULL, deleted_at INTEGER NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL
      );
      CREATE TABLE visit_attachments (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, visit_id TEXT NOT NULL,
        sha256 TEXT NOT NULL, role TEXT NOT NULL, caption TEXT NULL, captured_at INTEGER NOT NULL,
        position INTEGER NOT NULL, version INTEGER NULL, change_seq INTEGER NULL
      );
    ''');
    raw.execute('PRAGMA user_version = 6;');
    raw.execute(
      "INSERT INTO visits (id, org_id, version, template_version_id, answers_json, captured_at, device_id, created_by) "
      "VALUES ('visit-1', 'org-1', 3, 'tv-1', '{\"altura_cm\": 35}', 1767225600, 'device-1', 'user-1');",
    );

    final db = AppDatabase.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final visit = await db.select(db.visits).getSingle();
    expect((visit.version, visit.answersJson), (3, '{"altura_cm": 35}'));
    expect(visit.serverDataJson, isNull);
  });

  test('v7 → v8: nace la tabla de asignaciones y el pull vuelve a empezar', () async {
    final raw = sqlite3.sqlite3.openInMemory();
    addTearDown(raw.close);

    // Esquema v7 (Fase A): v6 + `visits.server_data_json`.
    raw.execute('''
      CREATE TABLE visits (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL, deleted_at INTEGER NULL, template_version_id TEXT NOT NULL,
        answers_json TEXT NOT NULL, lat REAL NULL, lon REAL NULL, accuracy_m REAL NULL,
        altitude_m REAL NULL, captured_at INTEGER NOT NULL, device_id TEXT NOT NULL,
        created_by TEXT NOT NULL, server_data_json TEXT NULL
      );
      CREATE TABLE outbox_ops (
        op_uuid TEXT NOT NULL PRIMARY KEY, entity TEXT NOT NULL, entity_id TEXT NOT NULL,
        op_type TEXT NOT NULL, base_version INTEGER NULL, payload_json TEXT NOT NULL,
        state TEXT NOT NULL, created_at INTEGER NOT NULL, error_message TEXT NULL,
        error_code TEXT NULL, error_fields_json TEXT NULL, server_row_json TEXT NULL
      );
      CREATE TABLE attachment_queue (
        sha256 TEXT NOT NULL PRIMARY KEY, local_path TEXT NOT NULL, state TEXT NOT NULL,
        created_at INTEGER NOT NULL, mime TEXT NOT NULL DEFAULT 'image/jpeg',
        attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at INTEGER NULL, last_error TEXT NULL
      );
      CREATE TABLE sync_cursor (id INTEGER NOT NULL PRIMARY KEY, cursor TEXT NOT NULL, updated_at INTEGER NOT NULL);
      CREATE TABLE form_template_versions (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, template_id TEXT NOT NULL,
        version_number INTEGER NOT NULL, name TEXT NULL, definition_json TEXT NOT NULL,
        published_at INTEGER NULL, deleted_at INTEGER NULL, version INTEGER NOT NULL,
        change_seq INTEGER NULL
      );
      CREATE TABLE visit_attachments (
        id TEXT NOT NULL PRIMARY KEY, org_id TEXT NOT NULL, visit_id TEXT NOT NULL,
        sha256 TEXT NOT NULL, role TEXT NOT NULL, caption TEXT NULL, captured_at INTEGER NOT NULL,
        position INTEGER NOT NULL, version INTEGER NULL, change_seq INTEGER NULL
      );
    ''');
    raw.execute('PRAGMA user_version = 7;');
    raw.execute(
      "INSERT INTO visits (id, org_id, version, template_version_id, answers_json, captured_at, device_id, created_by) "
      "VALUES ('visit-1', 'org-1', 2, 'tv-1', '{}', 1767225600, 'device-1', 'user-1');",
    );
    raw.execute("INSERT INTO sync_cursor (id, cursor, updated_at) VALUES (0, 'c1:00000000000000000099', 1767225600);");

    final db = AppDatabase.forTesting(NativeDatabase.opened(raw));
    addTearDown(db.close);

    final visit = await db.select(db.visits).getSingle();
    expect((visit.version, visit.assignmentId), (2, null));
    expect(await db.select(db.assignments).get(), isEmpty);
    expect(await db.readCursor(), isNull, reason: 'el pull vuelve a traer todo, asignaciones incluidas');
  });
}
