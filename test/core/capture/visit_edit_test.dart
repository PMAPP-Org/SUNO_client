// Fase A: editar y borrar visitas sin red, y que el motor las envíe en orden
// y con el `base_version` correcto (el servidor guarda con CAS sobre él).
import 'dart:convert';

import 'package:drift/drift.dart' show CustomExpression, OrderingTerm, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/core/sync/quarantine_service.dart';
import 'package:visitacampo/core/sync/result.dart';
import 'package:visitacampo/core/sync/sync_engine.dart';
import 'package:visitacampo/core/sync/sync_transport.dart';
import 'package:visitacampo/data/local/database.dart';

import '../sync/fake_sync_transport.dart';

const _me = CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1');
const _other = CaptureIdentity(orgId: 'org-1', userId: 'user-2', deviceId: 'device-2');

final _definition =
    (parseFormDefinition({
              'fields': [
                {
                  'key': 'altura_cm',
                  'type': 'number',
                  'label': {'es': 'Altura (cm)'},
                },
                {
                  'key': 'foto',
                  'type': 'photo',
                  'label': {'es': 'Foto'},
                },
              ],
            })
            as DefinitionOk)
        .definition;

PendingAttachment _photo(String id) => PendingAttachment(
  id: id,
  sha256: id.padRight(64, '0'),
  localPath: '/fotos/$id.jpg',
  mime: 'image/jpeg',
  role: 'foto',
  capturedAt: DateTime.utc(2026, 10, 18, 9),
);

void main() {
  late AppDatabase db;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late VisitCapture capture;
  var ids = 0;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeSyncTransport();
    engine = SyncEngine(db: db, transport: transport, deviceId: 'device-1');
    capture = VisitCapture(db: db, idGenerator: () => 'id-${ids++}');
  });
  tearDown(() => db.close());

  Future<String> newVisit({CaptureIdentity identity = _me}) => capture.save(
    identity: identity,
    templateVersionId: 'tv-1',
    definition: _definition,
    answers: {'altura_cm': 10},
    captured: const {},
  );

  Future<VisitChange> edit(String id, Map<String, Object?> answers, {Map<String, PendingAttachment> captured = const {}, LocationFix? fix}) =>
      capture.update(identity: _me, visitId: id, definition: _definition, answers: answers, captured: captured, fix: fix);

  Future<List<OutboxOp>> ops() =>
      (db.select(db.outboxOps)..orderBy([(t) => OrderingTerm.asc(const CustomExpression<int>('rowid'))])).get();

  /// El servidor aplica todo lo enviado y devuelve la versión resultante.
  void serverApplies(Map<String, int> versions) => transport.pushResponses.add(
    Result.ok(
      PushResponse(
        schemaVersion: 1,
        results: [
          for (final entry in versions.entries)
            PushOpOutcome(opUuid: entry.key, status: 'applied', serverVersion: entry.value),
        ],
      ),
    ),
  );

  group('editar', () {
    test('solo viaja lo que cambió, sobre la versión que el agente veía', () async {
      final id = await newVisit();
      expect(await edit(id, {'altura_cm': 35}), VisitChange.saved);

      final update = (await ops()).last;
      expect((update.opType, update.baseVersion), ('update', 1));
      expect(jsonDecode(update.payloadJson), {
        'id': id,
        'answers': {'altura_cm': 35},
      });
      final visit = await (db.select(db.visits)..where((t) => t.id.equals(id))).getSingle();
      expect(jsonDecode(visit.answersJson), {'altura_cm': 35}, reason: 'la pantalla ya lo ve, sin red');
    });

    test('varias ediciones sin red encadenan su base_version', () async {
      final id = await newVisit();
      await edit(id, {'altura_cm': 20});
      await edit(id, {'altura_cm': 30});
      expect([for (final op in await ops()) op.baseVersion], [null, 1, 2]);
    });

    test('sin cambios no encola nada', () async {
      final id = await newVisit();
      expect(await edit(id, {'altura_cm': 10}), VisitChange.unchanged);
      expect(await ops(), hasLength(1));
    });

    test('nueva ubicación y nueva foto: el update y luego el alta del adjunto', () async {
      final id = await newVisit();
      final photo = _photo('foto-nueva');
      await edit(
        id,
        {'altura_cm': 10, 'foto': photo.id},
        captured: {photo.id: photo},
        fix: const LocationFix(lat: 4.6, lon: -74.1, accuracyM: 3),
      );

      final all = await ops();
      expect([for (final op in all) (op.entity, op.opType)], [
        ('visit', 'create'),
        ('visit', 'update'),
        ('visit_attachment', 'create'),
      ]);
      final payload = jsonDecode(all[1].payloadJson) as Map<String, dynamic>;
      expect(payload['lat'], 4.6);
      expect(await db.select(db.attachmentQueue).get(), hasLength(1));
    });

    test('supervisión puede editar y borrar las de otro (como el servidor)', () async {
      const supervisor = CaptureIdentity(
        orgId: 'org-1',
        userId: 'user-9',
        deviceId: 'device-9',
        roles: ['SUPERVISOR'],
      );
      final id = await newVisit(identity: _other);
      expect(
        await capture.update(
          identity: supervisor,
          visitId: id,
          definition: _definition,
          answers: {'altura_cm': 77},
          captured: const {},
        ),
        VisitChange.saved,
      );
      expect(await capture.delete(identity: supervisor, visitId: id), VisitChange.saved);
    });

    test('solo las propias', () async {
      final id = await newVisit(identity: _other);
      expect(await edit(id, {'altura_cm': 99}), VisitChange.notAllowed);
      expect(await capture.delete(identity: _me, visitId: id), VisitChange.notAllowed);
    });

    test('con algo en revisión, primero se resuelve', () async {
      final id = await newVisit();
      await db.update(db.outboxOps).write(const OutboxOpsCompanion(state: Value('quarantine')));
      expect(await edit(id, {'altura_cm': 99}), VisitChange.needsReview);
    });
  });

  group('borrar', () {
    test('sale de la lista ya y viaja como delete sobre su versión', () async {
      final id = await newVisit();
      await edit(id, {'altura_cm': 20});
      expect(await capture.delete(identity: _me, visitId: id), VisitChange.saved);

      final visit = await (db.select(db.visits)..where((t) => t.id.equals(id))).getSingle();
      expect(visit.deletedAt, isNotNull);
      final delete = (await ops()).last;
      expect((delete.opType, delete.baseVersion), ('delete', 2));
      expect(jsonDecode(delete.payloadJson), {'id': id});
    });
  });

  group('motor', () {
    test('aplica la versión que devuelve el servidor y la siguiente edición parte de ella', () async {
      final id = await newVisit();
      await edit(id, {'altura_cm': 20});
      final [create, update] = await ops();
      serverApplies({create.opUuid: 1, update.opUuid: 2});
      await engine.drainOutbox();

      final visit = await (db.select(db.visits)..where((t) => t.id.equals(id))).getSingle();
      expect(visit.version, 2);
      await edit(id, {'altura_cm': 30});
      expect((await ops()).single.baseVersion, 2);
    });

    test('un update no adelanta a su create en revisión', () async {
      final id = await newVisit();
      await edit(id, {'altura_cm': 20});
      await (db.update(db.outboxOps)..where((t) => t.opType.equals('create'))).write(
        const OutboxOpsCompanion(state: Value('quarantine')),
      );

      expect(await engine.drainOutbox(), DrainReport.empty);
      expect(transport.pushCalls, isEmpty);
      expect(id, isNotEmpty);
    });

    test('el adjunto espera a su visita', () async {
      final id = await newVisit();
      final photo = _photo('foto-1');
      await edit(id, {'altura_cm': 10, 'foto': photo.id}, captured: {photo.id: photo});
      // La alta de la visita en revisión: ni su adjunto (otra entidad) sale.
      await (db.update(db.outboxOps)..where((t) => t.entity.equals('visit'))).write(
        const OutboxOpsCompanion(state: Value('quarantine')),
      );

      expect(await engine.drainOutbox(), DrainReport.empty);
    });

    test('un envío cortado (inflight) se reenvía en la siguiente sesión', () async {
      await newVisit();
      await db.update(db.outboxOps).write(const OutboxOpsCompanion(state: Value('inflight')));
      final op = (await ops()).single;
      serverApplies({op.opUuid: 1});

      final report = await SyncEngine(db: db, transport: transport, deviceId: 'device-1').drainOutbox();
      expect(report.applied, 1);
      expect(await ops(), isEmpty);
    });

    test('el pull no pisa una edición sin enviar, pero guarda la copia del servidor', () async {
      final id = await newVisit();
      final create = (await ops()).single;
      serverApplies({create.opUuid: 1});
      await engine.drainOutbox();
      await edit(id, {'altura_cm': 50});

      final serverRow = {
        'id': id,
        'org_id': 'org-1',
        'version': 2,
        'change_seq': 7,
        'deleted_at': null,
        'template_version_id': 'tv-1',
        'answers': {'altura_cm': 99},
        'lat': null,
        'lon': null,
        'accuracy_m': null,
        'altitude_m': null,
        'captured_at': '2026-10-18T09:00:00Z',
        'device_id': 'device-2',
        'created_by': 'user-1',
      };
      transport.pullResponses.add(
        Result.ok(
          PullResponse(
            rows: [PullRow(entity: 'visit', data: serverRow)],
            tombstones: const [],
            nextCursor: 'c1:00000000000000000007',
            hasMore: false,
          ),
        ),
      );
      await engine.pull();

      final visit = await (db.select(db.visits)..where((t) => t.id.equals(id))).getSingle();
      expect(jsonDecode(visit.answersJson), {'altura_cm': 50}, reason: 'lo del agente sigue en pantalla');
      expect((jsonDecode(visit.serverDataJson!) as Map<String, dynamic>)['answers'], {'altura_cm': 99});
    });
  });

  group('revisión', () {
    Future<String> syncedVisitWithRejectedEdit() async {
      final id = await newVisit();
      final create = (await ops()).single;
      transport.pushResponses.add(
        Result.ok(
          PushResponse(
            schemaVersion: 1,
            results: [
              PushOpOutcome(
                opUuid: create.opUuid,
                status: 'applied',
                serverVersion: 1,
                serverRow: {
                  'entity': 'visit',
                  'data': {
                    'id': id,
                    'org_id': 'org-1',
                    'version': 1,
                    'change_seq': 1,
                    'deleted_at': null,
                    'template_version_id': 'tv-1',
                    'answers': {'altura_cm': 10},
                    'lat': null,
                    'lon': null,
                    'accuracy_m': null,
                    'altitude_m': null,
                    'captured_at': '2026-10-18T09:00:00Z',
                    'device_id': 'device-1',
                    'created_by': 'user-1',
                  },
                },
              ),
            ],
          ),
        ),
      );
      await engine.drainOutbox();
      await edit(id, {'altura_cm': 9999});
      await db.update(db.outboxOps).write(const OutboxOpsCompanion(state: Value('quarantine')));
      return id;
    }

    test('descartar una edición rechazada vuelve a la versión del servidor, sin borrar la visita', () async {
      final id = await syncedVisitWithRejectedEdit();
      final quarantine = QuarantineService(db: db, engine: engine);
      final item = (await quarantine.list(orgId: 'org-1')).single;
      expect(item.existsOnServer, isTrue);

      await quarantine.discard(item);
      final visit = await (db.select(db.visits)..where((t) => t.id.equals(id))).getSingle();
      expect(jsonDecode(visit.answersJson), {'altura_cm': 10});
      expect(await ops(), isEmpty);
    });

    test('"enviar mi versión" de un borrado en conflicto vuelve a borrar sobre la versión del servidor', () async {
      final id = await newVisit();
      await capture.delete(identity: _me, visitId: id);
      final serverData = {
        'id': id,
        'org_id': 'org-1',
        'version': 4,
        'change_seq': 9,
        'deleted_at': null,
        'template_version_id': 'tv-1',
        'answers': {'altura_cm': 77},
        'lat': null,
        'lon': null,
        'accuracy_m': null,
        'altitude_m': null,
        'captured_at': '2026-10-18T09:00:00Z',
        'device_id': 'device-2',
        'created_by': 'user-1',
      };
      // El alta ya se aplicó; el borrado chocó con un cambio en el servidor.
      await (db.delete(db.outboxOps)..where((t) => t.opType.equals('create'))).go();
      await db.update(db.outboxOps).write(
        OutboxOpsCompanion(
          state: const Value('quarantine'),
          errorCode: const Value('conflict'),
          serverRowJson: Value(jsonEncode({'entity': 'visit', 'data': serverData})),
        ),
      );
      final quarantine = QuarantineService(db: db, engine: engine);
      await quarantine.resendMine((await quarantine.list(orgId: 'org-1')).single);

      final resent = (await ops()).single;
      expect((resent.opType, resent.baseVersion, resent.state), ('delete', 4, 'pending'));
    });
  });
}
