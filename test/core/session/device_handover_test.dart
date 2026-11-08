// Teléfono compartido (Fase A): las visitas sin enviar de un agente no salen
// con la sesión de otro, y los datos de otra organización se borran.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/auth/auth_models.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/session/device_handover.dart';
import 'package:visitacampo/data/local/database.dart';

const _ana = UserProfile(id: 'ana', username: 'ana', orgId: 'org-1', roles: ['agent']);
const _beto = UserProfile(id: 'beto', username: 'beto', orgId: 'org-1', roles: ['agent']);
const _carla = UserProfile(id: 'carla', username: 'carla', orgId: 'org-2', roles: ['agent']);

final _definition =
    (parseFormDefinition({
              'fields': [
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
  late List<String> deleted;
  late DeviceHandover handover;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    deleted = [];
    handover = DeviceHandover(db, deleteFile: (path) async => deleted.add(path));
  });
  tearDown(() => db.close());

  Future<String> captureAs(UserProfile user) {
    final photo = PendingAttachment(
      id: 'foto-${user.id}',
      sha256: user.id.padRight(64, '0'),
      localPath: '/fotos/${user.id}.jpg',
      mime: 'image/jpeg',
      role: 'foto',
      capturedAt: DateTime.utc(2026, 10, 18),
    );
    return VisitCapture(db: db).save(
      identity: CaptureIdentity(orgId: user.orgId, userId: user.id, deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: _definition,
      answers: {'foto': photo.id},
      captured: {photo.id: photo},
    );
  }

  test('el mismo agente vuelve a entrar con lo suyo pendiente', () async {
    await captureAs(_ana);
    expect(await handover.prepare(_ana), isA<HandoverReady>().having((r) => r.wiped, 'wiped', false));
    expect(await handover.unsentVisitsOf(_ana), 1);
  });

  test('otro agente no entra mientras haya visitas sin enviar de alguien más', () async {
    await captureAs(_ana);
    final result = await handover.prepare(_beto);
    expect(result, isA<HandoverBlocked>().having((r) => r.visits, 'visits', 1));
    expect(await db.select(db.outboxOps).get(), hasLength(2), reason: 'no se toca nada');
  });

  test('ya enviado todo, otro agente de la misma organización entra sin borrar nada', () async {
    await captureAs(_ana);
    await db.delete(db.outboxOps).go();
    expect(await handover.prepare(_beto), isA<HandoverReady>().having((r) => r.wiped, 'wiped', false));
    expect(await db.select(db.visits).get(), hasLength(1));
  });

  test('con otra organización se borran sus datos, fotos incluidas, y el cursor', () async {
    await captureAs(_ana);
    await db.delete(db.outboxOps).go();
    await db.writeCursor('c1:00000000000000000042', now: DateTime.utc(2026, 10, 18));

    final result = await handover.prepare(_carla);
    expect(result, isA<HandoverReady>().having((r) => r.wiped, 'wiped', true));
    expect(await db.select(db.visits).get(), isEmpty);
    expect(await db.select(db.attachmentQueue).get(), isEmpty);
    expect(await db.readCursor(), isNull);
    expect(deleted, ['/fotos/ana.jpg']);
  });

  test('una op sin visita en el teléfono cuenta como ajena', () async {
    await db
        .into(db.outboxOps)
        .insert(
          OutboxOpsCompanion.insert(
            opUuid: 'op-huerfana',
            entity: 'visit',
            entityId: 'visita-que-no-esta',
            opType: 'update',
            baseVersion: const Value(1),
            payloadJson: '{}',
            state: 'pending',
            createdAt: DateTime.utc(2026, 10, 18),
          ),
        );
    expect(await handover.prepare(_ana), isA<HandoverBlocked>());
  });

  test('al cambiar de organización también se borran las tareas del cronograma', () async {
    await db
        .into(db.visits)
        .insert(
          VisitsCompanion.insert(
            id: 'v-ana',
            orgId: 'org-1',
            version: 1,
            templateVersionId: 'tv-1',
            answersJson: '{}',
            capturedAt: DateTime.utc(2026, 11, 1),
            deviceId: 'device-1',
            createdBy: 'ana',
          ),
        );
    await db.replaceScheduleTasks(
      orgId: 'org-1',
      userId: 'ana',
      version: 'v1',
      now: DateTime.utc(2026, 11, 1),
      rows: [
        ScheduleTasksCompanion.insert(
          id: 't-1',
          orgId: 'org-1',
          userId: 'ana',
          projectId: 'p-1',
          projectName: 'Obra',
          wbs: '1.1',
          outlineNumber: '1.1',
          name: 'Excavación',
          position: 0,
        ),
      ],
    );

    final result = await handover.prepare(_carla);

    expect(result, isA<HandoverReady>().having((r) => r.wiped, 'wiped', isTrue));
    expect(await db.select(db.scheduleTasks).get(), isEmpty);
    expect(await db.readScheduleTaskState(), isNull);
  });

  group('maquinaria y equipos', () {
    Future<void> reading({required String user, String org = 'org-1', String state = 'pending'}) => db
        .into(db.meterReadingOutbox)
        .insert(
          MeterReadingOutboxCompanion.insert(
            id: 'r-$user-$state',
            orgId: org,
            userId: user,
            equipmentId: 'e-1',
            meterUnit: 'hours',
            value: 10,
            readAt: DateTime.utc(2026, 11, 8),
            state: Value(state),
          ),
        );

    test('una lectura de medidor sin enviar de otro usuario bloquea la entrada', () async {
      await reading(user: 'ana');

      final result = await handover.prepare(_beto);

      expect(result, isA<HandoverBlocked>().having((r) => r.readings, 'readings', 1).having((r) => r.visits, 'v', 0));
    });

    test('el mismo usuario entra y conserva su cola; una rechazada ajena no bloquea', () async {
      await reading(user: 'ana');
      await reading(user: 'beto', state: 'rejected');

      expect(await handover.prepare(_ana), isA<HandoverReady>());
      expect(await db.select(db.meterReadingOutbox).get(), hasLength(2));
    });

    test('al cambiar de organización se borran la caché de equipos y la cola', () async {
      await db
          .into(db.equipmentCache)
          .insert(
            EquipmentCacheCompanion.insert(
              id: 'e-1',
              orgId: 'org-1',
              code: 'EQ-1',
              qrIdentifier: 'suno:eq:e-1',
              dataJson: '{}',
            ),
          );
      await db
          .into(db.equipmentCatalogMeta)
          .insert(EquipmentCatalogMetaCompanion.insert(orgId: 'org-1', version: 'v1', fetchedAt: DateTime.utc(2026, 11, 8)));
      await reading(user: 'carla', org: 'org-2', state: 'rejected');

      final result = await handover.prepare(_carla);

      expect(result, isA<HandoverReady>().having((r) => r.wiped, 'wiped', true));
      expect(await db.select(db.equipmentCache).get(), isEmpty);
      expect(await db.select(db.equipmentCatalogMeta).get(), isEmpty);
      expect(await db.select(db.meterReadingOutbox).get(), isEmpty);
    });
  });
}
