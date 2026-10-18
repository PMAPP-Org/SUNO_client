// Fase B: las asignaciones llegan por el pull, el agente ve las suyas
// (pendientes primero) y una visita que la referencia la marca como hecha.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/location/geo.dart';
import 'package:visitacampo/core/sync/result.dart';
import 'package:visitacampo/core/sync/sync_engine.dart';
import 'package:visitacampo/core/sync/sync_transport.dart';
import 'package:visitacampo/data/local/assignment_repository.dart';
import 'package:visitacampo/data/local/database.dart';

import '../../core/sync/fake_sync_transport.dart';

Map<String, dynamic> _assignment(String id, {String to = 'user-1', String? scheduled, Object? deletedAt}) => {
  'id': id,
  'org_id': 'org-1',
  'version': 1,
  'change_seq': 3,
  'deleted_at': deletedAt,
  'template_version_id': 'tv-1',
  'assigned_to': to,
  'title': 'Finca $id',
  'scheduled_for': scheduled,
  'lat': 4.6,
  'lon': -74,
};

void main() {
  late AppDatabase db;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late AssignmentRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeSyncTransport();
    engine = SyncEngine(db: db, transport: transport, deviceId: 'device-1');
    repository = AssignmentRepository(db);
  });
  tearDown(() => db.close());

  Future<void> pull(List<Map<String, dynamic>> assignments, {List<PullTombstone> tombstones = const []}) async {
    transport.pullResponses.add(
      Result.ok(
        PullResponse(
          rows: [for (final a in assignments) PullRow(entity: 'assignment', data: a)],
          tombstones: tombstones,
          nextCursor: 'c1:00000000000000000010',
          hasMore: false,
        ),
      ),
    );
    await engine.pull();
  }

  test('el pull guarda las asignaciones y el agente ve solo las suyas, por fecha', () async {
    await pull([
      _assignment('b', scheduled: '2026-10-20T08:00:00Z'),
      _assignment('a', scheduled: '2026-10-19T08:00:00Z'),
      _assignment('sin-fecha'),
      _assignment('de-otro', to: 'user-2'),
    ]);

    final mine = await repository.forUser(orgId: 'org-1', userId: 'user-1');
    expect(mine.map((a) => a.id), ['a', 'b', 'sin-fecha']);
    expect(mine.first.hasPoint, isTrue);
    expect(mine.first.done, isFalse);
  });

  test('una borrada en el servidor sale del teléfono', () async {
    await pull([_assignment('a')]);
    await pull(
      const [],
      tombstones: [PullTombstone(entity: 'assignment', id: 'a', deletedAt: DateTime.utc(2026, 10, 18), changeSeq: 11)],
    );
    expect(await repository.forUser(orgId: 'org-1', userId: 'user-1'), isEmpty);
  });

  test('la visita guardada desde una asignación la marca como hecha y viaja con su id', () async {
    await pull([_assignment('a'), _assignment('b')]);
    final visitId = await VisitCapture(db: db).save(
      identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: (parseFormDefinition({'fields': <Object>[]}) as DefinitionOk).definition,
      answers: const {},
      captured: const {},
      assignmentId: 'a',
    );

    final mine = await repository.forUser(orgId: 'org-1', userId: 'user-1');
    expect(mine.map((a) => (a.id, a.done)), [('b', false), ('a', true)], reason: 'pendientes primero');
    expect(mine.last.visitId, visitId);
    final op = await db.select(db.outboxOps).getSingle();
    expect((jsonDecode(op.payloadJson) as Map<String, dynamic>)['assignment_id'], 'a');
  });

  test('distancia entre dos puntos (haversine)', () {
    // ~111 m por milésima de grado de latitud.
    expect(distanceM(4.6, -74, 4.601, -74), closeTo(111.2, 0.5));
    expect(distanceM(4.6, -74, 4.6, -74), 0);
  });
}
