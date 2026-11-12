// Costos, etapa 1: las filas `record` del servidor traen `task_id` y
// `progress_pct`; el teléfono las guarda (una fila de un servidor anterior, sin
// esas claves, deja el registro sin tarea).
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/sync/result.dart';
import 'package:suno/core/sync/sync_engine.dart';
import 'package:suno/core/sync/sync_transport.dart';
import 'package:suno/data/local/database.dart';

import 'fake_sync_transport.dart';

Map<String, dynamic> _row() => {
  'id': 'record-1',
  'org_id': 'org-1',
  'version': 1,
  'change_seq': 42,
  'deleted_at': null,
  'assignment_id': null,
  'template_version_id': 'tv-1',
  'answers': <String, dynamic>{},
  'lat': null,
  'lon': null,
  'accuracy_m': null,
  'altitude_m': null,
  'captured_at': '2026-11-01T10:00:00.000Z',
  'device_id': 'device-1',
  'created_by': 'user-1',
};

void main() {
  late AppDatabase db;
  late FakeSyncTransport transport;
  late SyncEngine engine;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeSyncTransport();
    engine = SyncEngine(db: db, transport: transport, deviceId: 'device-1');
  });
  tearDown(() => db.close());

  Future<Record> pullRow(Map<String, dynamic> row) async {
    transport.pullResponses.add(
      Result.ok(
        PullResponse(
          rows: [PullRow(entity: 'record', data: row)],
          tombstones: const [],
          nextCursor: 'c1:00000000000000000042',
          hasMore: false,
        ),
      ),
    );
    await engine.pull();
    return db.select(db.records).getSingle();
  }

  test('guarda la tarea y el % del registro', () async {
    final record = await pullRow({..._row(), 'task_id': 'task-1', 'progress_pct': 40});
    expect((record.taskId, record.progressPct), ('task-1', 40.0));
  });

  test('una fila sin esas claves (servidor anterior) deja el registro sin tarea', () async {
    final record = await pullRow(_row());
    expect((record.taskId, record.progressPct), (null, null));
  });
}
