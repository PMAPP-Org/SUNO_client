// Teléfono compartido: los preoperacionales sin enviar de otro usuario bloquean
// la entrada y se borran al cambiar de organización.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/auth/auth_models.dart';
import 'package:suno/core/session/device_handover.dart';
import 'package:suno/data/local/database.dart';

const _ana = UserProfile(id: 'ana', username: 'ana', orgId: 'org-1', roles: ['agent']);
const _beto = UserProfile(id: 'beto', username: 'beto', orgId: 'org-1', roles: ['agent']);
const _carla = UserProfile(id: 'carla', username: 'carla', orgId: 'org-2', roles: ['agent']);

void main() {
  late AppDatabase db;
  late DeviceHandover handover;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    handover = DeviceHandover(db, deleteFile: (_) async {});
  });
  tearDown(() => db.close());

  Future<void> inspection({required String user, String org = 'org-1', String state = 'pending'}) => db
      .into(db.inspectionOutbox)
      .insert(
        InspectionOutboxCompanion.insert(
          id: 'i-$user-$state',
          orgId: org,
          userId: user,
          equipmentId: 'e-1',
          capturedAt: DateTime.utc(2026, 11, 8),
          itemsJson: '[]',
          state: Value(state),
        ),
      );

  test('un preoperacional sin enviar de otro usuario bloquea la entrada', () async {
    await inspection(user: 'ana');

    final result = await handover.prepare(_beto);

    expect(
      result,
      isA<HandoverBlocked>()
          .having((r) => r.inspections, 'inspections', 1)
          .having((r) => r.records, 'records', 0)
          .having((r) => r.readings, 'readings', 0),
    );
  });

  test('el mismo usuario entra con su cola; un rechazado ajeno no bloquea', () async {
    await inspection(user: 'ana');
    await inspection(user: 'beto', state: 'rejected');

    expect(await handover.prepare(_ana), isA<HandoverReady>());
    expect(await db.select(db.inspectionOutbox).get(), hasLength(2));
  });

  test('al cambiar de organización se borra la cola de preoperacionales', () async {
    await db
        .into(db.equipmentCache)
        .insert(
          EquipmentCacheCompanion.insert(id: 'e-1', orgId: 'org-1', code: 'EQ-1', qrIdentifier: 'q', dataJson: '{}'),
        );
    await inspection(user: 'carla', org: 'org-2', state: 'rejected');

    final result = await handover.prepare(_carla);

    expect(result, isA<HandoverReady>().having((r) => r.wiped, 'wiped', true));
    expect(await db.select(db.inspectionOutbox).get(), isEmpty);
  });
}
