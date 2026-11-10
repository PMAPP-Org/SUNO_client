// Costos, pieza 4b: el pull guarda las cantidades del registro; un rechazo
// `record_validated` deja el registro marcado como validado (cantidades de solo lectura).
import 'dart:convert';

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
  'task_id': 'task-1',
  'progress_pct': null,
};

const _quantity = {
  'item_id': 'item-1',
  'location_id': null,
  'quantity': 4.5,
  'note': '',
  'client_id': 'c-1',
  'captured_at': '2026-11-01T09:58:00.000Z',
  'gps': {'lat': 4.6, 'lon': -74.08, 'accuracy_m': 7.0},
  'seen': {'planned': 10.0, 'validated': 0.0, 'location_id': null},
  'location_mode': 'task',
};

void main() {
  late AppDatabase db;
  late FakeSyncTransport transport;
  late SyncEngine engine;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeSyncTransport();
    var ids = 0;
    engine = SyncEngine(db: db, transport: transport, deviceId: 'device-1', idGenerator: () => 'op-${ids++}');
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

  test('guarda las cantidades del registro tal como llegan', () async {
    final record = await pullRow({
      ..._row(),
      'quantities': [_quantity],
    });
    expect(jsonDecode(record.quantitiesJson), [_quantity]);
  });

  test('una fila sin datos automáticos (captura anterior) se guarda con sus null', () async {
    const legacy = {
      'item_id': 'item-1',
      'location_id': null,
      'quantity': 2,
      'note': '',
      'client_id': null,
      'captured_at': null,
      'gps': null,
      'seen': null,
      'location_mode': null,
    };
    final record = await pullRow({
      ..._row(),
      'quantities': [legacy],
    });
    expect(jsonDecode(record.quantitiesJson), [legacy]);
  });

  test('una fila sin la clave (servidor anterior) deja []', () async {
    expect((await pullRow(_row())).quantitiesJson, '[]');
  });

  test('un rechazo record_validated marca el registro como validado', () async {
    await pullRow({
      ..._row(),
      'quantities': [_quantity],
    });
    await engine.enqueueRecordOp(
      entityId: 'record-1',
      opType: 'update',
      baseVersion: 1,
      payload: {
        'id': 'record-1',
        'task_id': 'task-1',
        'progress_pct': null,
        'quantities': [
          {..._quantity, 'quantity': 5},
        ],
      },
    );
    final op = await db.select(db.outboxOps).getSingle();
    transport.pushResponses.add(
      Result.ok(
        PushResponse(
          schemaVersion: 2,
          results: [
            PushOpOutcome(
              opUuid: op.opUuid,
              status: 'rejected',
              error: const PushOpError(
                code: 'validation_error',
                message: 'The record was validated: its task, progress and quantities cannot change.',
                details: {'field': 'quantities', 'reason': 'record_validated'},
              ),
            ),
          ],
        ),
      ),
    );
    await engine.drainOutbox();
    expect((await db.select(db.records).getSingle()).knownValidated, isTrue);

    // Un pull posterior no borra la marca.
    expect((await pullRow({..._row(), 'version': 2})).knownValidated, isTrue);
  });
}
