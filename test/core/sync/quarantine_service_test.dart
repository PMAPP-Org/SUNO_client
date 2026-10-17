// `QuarantineService` (Paso 23): resolver rechazos y conflictos sin perder el
// trabajo del agente salvo que él lo pida.
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/sync/quarantine_service.dart';
import 'package:visitacampo/core/sync/result.dart';
import 'package:visitacampo/core/sync/sync_engine.dart';
import 'package:visitacampo/core/sync/sync_transport.dart';
import 'package:visitacampo/data/local/database.dart';

import 'fake_sync_transport.dart';

const _org = 'org-1';
const _photoSha = 'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00';

FormDefinition _definition() =>
    (parseFormDefinition({
              'fields': [
                {
                  'key': 'altura_cm',
                  'type': 'number',
                  'label': {'es': 'Altura'},
                  'max': 500,
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

void main() {
  late AppDatabase db;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late QuarantineService service;
  var ids = 0;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeSyncTransport();
    ids = 0;
    engine = SyncEngine(db: db, transport: transport, deviceId: 'device-1', idGenerator: () => 'op-${ids++}');
    service = QuarantineService(db: db, engine: engine, clock: () => DateTime.utc(2026, 10, 18));
  });
  tearDown(() => db.close());

  Future<List<OutboxOp>> ops() => db.select(db.outboxOps).get();

  /// Responde al siguiente push con [outcome] para cada op enviada.
  Future<void> pushWith(PushOpOutcome Function(OutboxOp op) outcome) async {
    final pending = await ops();
    transport.pushResponses.add(
      Result.ok(PushResponse(schemaVersion: 1, results: [for (final op in pending) outcome(op)])),
    );
    await engine.drainOutbox();
  }

  group('rechazo', () {
    late String visitId;

    setUp(() async {
      final photo = PendingAttachment(
        id: 'att-1',
        sha256: _photoSha,
        localPath: '/fotos/1.jpg',
        mime: 'image/jpeg',
        role: 'foto',
        capturedAt: DateTime.utc(2026, 10, 17),
      );
      visitId = await VisitCapture(db: db, idGenerator: () => 'cap-${ids++}').save(
        identity: const CaptureIdentity(orgId: _org, userId: 'user-1', deviceId: 'device-1'),
        templateVersionId: 'tv-1',
        definition: _definition(),
        answers: {'altura_cm': 900, 'foto': 'att-1'},
        captured: {'att-1': photo},
      );
      // El servidor rechaza la visita por una respuesta y, por tanto, el adjunto.
      await pushWith(
        (op) => PushOpOutcome(
          opUuid: op.opUuid,
          status: 'rejected',
          error: op.entity == 'visit'
              ? const PushOpError(
                  code: 'validation_error',
                  message: 'Answers do not match the form template version schema.',
                  details: {
                    'errors': [
                      {'field': 'answers.altura_cm', 'reason': 'out_of_range'},
                    ],
                  },
                )
              : const PushOpError(
                  code: 'not_found',
                  message: 'Referenced visit_id does not exist in this organization.',
                  details: {'field': 'visit_id', 'reason': 'unknown_reference'},
                ),
        ),
      );
    });

    test('se agrupa por visita, con el campo que corregir', () async {
      final items = await service.list(orgId: _org);

      expect(items, hasLength(1));
      final item = items.single;
      expect((item.visit.id, item.kind, item.code), (visitId, QuarantineKind.rejected, 'validation_error'));
      expect(item.ops.map((o) => o.entity), ['visit', 'visit_attachment'], reason: 'el adjunto viaja con su visita');
      expect(item.answerViolations, {'altura_cm': 'out_of_range'});
      expect(item.canCorrect, isTrue);
      expect(await service.count(orgId: _org), 1);
      expect(await service.list(orgId: 'otra-org'), isEmpty);
    });

    test('corregir: respuestas nuevas, op_uuid nuevos y la visita antes que su adjunto', () async {
      final item = (await service.list(orgId: _org)).single;
      final oldUuids = {for (final op in item.ops) op.opUuid};

      await service.correct(item, {'altura_cm': 120, 'foto': 'att-1'});

      final visit = await db.select(db.visits).getSingle();
      expect(jsonDecode(visit.answersJson), {'altura_cm': 120, 'foto': 'att-1'});
      final pending = await ops();
      expect(pending.every((op) => op.state == 'pending' && !oldUuids.contains(op.opUuid)), isTrue);

      transport.pushResponses.add(const Result.err(SyncError.network('sin red')));
      await engine.drainOutbox();
      final sent = transport.pushCalls.last.ops;
      expect(sent.map((op) => op.entity), ['visit', 'visit_attachment']);
      expect(sent.first.payload['answers'], {'altura_cm': 120, 'foto': 'att-1'});
      expect(await service.list(orgId: _org), isEmpty);
    });

    test('reintentar: el grupo vuelve a pending con op_uuid nuevos', () async {
      final item = (await service.list(orgId: _org)).single;
      await service.retry(item);

      final pending = await ops();
      expect(pending.map((op) => op.state).toSet(), {'pending'});
      expect(pending.map((op) => op.opUuid).toSet().intersection({for (final op in item.ops) op.opUuid}), isEmpty);
    });

    test('descartar: se va la visita con sus adjuntos y sus fotos sin subir', () async {
      // Otra visita que comparte la misma foto: su subida no se toca.
      await db
          .into(db.visitAttachments)
          .insert(
            VisitAttachmentsCompanion.insert(
              id: 'att-otra',
              orgId: _org,
              visitId: 'visita-otra',
              sha256: 'f' * 64,
              role: 'foto',
              capturedAt: DateTime.utc(2026),
              position: 0,
            ),
          );
      await db
          .into(db.attachmentQueue)
          .insert(
            AttachmentQueueCompanion.insert(sha256: 'f' * 64, localPath: '/x', state: 'pending', createdAt: DateTime.utc(2026)),
          );

      await service.discard((await service.list(orgId: _org)).single);

      expect(await (db.select(db.visits)..where((t) => t.id.equals(visitId))).get(), isEmpty);
      expect(await ops(), isEmpty);
      expect((await db.select(db.visitAttachments).get()).map((a) => a.id), ['att-otra']);
      expect((await db.select(db.attachmentQueue).get()).map((u) => u.sha256), ['f' * 64]);
    });
  });

  group('conflicto', () {
    Map<String, dynamic> serverData({Map<String, Object?> answers = const {'altura_cm': 20}, double lat = 4.7}) => {
      'id': 'visit-1',
      'org_id': _org,
      'version': 3,
      'change_seq': 90,
      'deleted_at': null,
      'assignment_id': null,
      'template_version_id': 'tv-1',
      'answers': answers,
      'lat': lat,
      'lon': -74.0,
      'accuracy_m': null,
      'altitude_m': null,
      'captured_at': '2026-10-17T10:00:00.000Z',
      'device_id': 'device-1',
      'created_by': 'user-1',
    };

    Future<void> conflictWith(Map<String, dynamic> server) async {
      await db
          .into(db.visits)
          .insert(
            VisitsCompanion.insert(
              id: 'visit-1',
              orgId: _org,
              version: 1,
              templateVersionId: 'tv-1',
              answersJson: jsonEncode({'altura_cm': 10}),
              lat: const Value(4.6),
              lon: const Value(-74.0),
              capturedAt: DateTime.utc(2026, 10, 17, 10),
              deviceId: 'device-1',
              createdBy: 'user-1',
            ),
          );
      await engine.enqueueVisitOp(
        entityId: 'visit-1',
        opType: 'update',
        baseVersion: 1,
        payload: {
          'id': 'visit-1',
          'answers': {'altura_cm': 10},
        },
      );
      await pushWith(
        (op) => PushOpOutcome(
          opUuid: op.opUuid,
          status: 'conflict',
          serverVersion: 3,
          serverRow: {'entity': 'visit', 'data': server},
          error: const PushOpError(code: 'conflict', message: 'The row changed on the server since base_version.'),
        ),
      );
    }

    test('la versión del agente sigue intacta y se ven las diferencias', () async {
      await conflictWith(serverData());

      final item = (await service.list(orgId: _org)).single;
      expect(item.kind, QuarantineKind.conflict);
      expect(item.differences, [
        (field: 'altura_cm', mine: 10, server: 20),
        (field: 'lat', mine: 4.6, server: 4.7),
      ]);
      final visit = await db.select(db.visits).getSingle();
      expect(visit.version, 1, reason: 'nada se pisó');
      expect(jsonDecode(visit.answersJson), {'altura_cm': 10});
    });

    test('enviar mi versión: update sobre la versión actual del servidor, solo lo que difiere', () async {
      await conflictWith(serverData());
      await service.resendMine((await service.list(orgId: _org)).single);

      final op = (await ops()).single;
      expect((op.opType, op.baseVersion, op.state), ('update', 3, 'pending'));
      expect(jsonDecode(op.payloadJson), {
        'id': 'visit-1',
        'answers': {'altura_cm': 10},
        'lat': 4.6,
      });
      expect((await db.select(db.visits).getSingle()).version, 3);
    });

    test('quedarme con la del servidor: la fila local pasa a ser la del servidor', () async {
      await conflictWith(serverData());
      await service.acceptServer((await service.list(orgId: _org)).single);

      expect(await ops(), isEmpty);
      final visit = await db.select(db.visits).getSingle();
      expect((visit.version, visit.lat), (3, 4.7));
      expect(jsonDecode(visit.answersJson), {'altura_cm': 20});
    });

    test('si ya no difieren, enviar mi versión equivale a aceptar la del servidor', () async {
      await conflictWith(serverData(answers: const {'altura_cm': 10}, lat: 4.6));
      await service.resendMine((await service.list(orgId: _org)).single);

      expect(await ops(), isEmpty, reason: 'no se envía un update vacío');
      expect((await db.select(db.visits).getSingle()).version, 3);
    });
  });
}
