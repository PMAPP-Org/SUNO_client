// Teléfono compartido: los viajes sin enviar de otro usuario bloquean la entrada
// y se borran, con el catálogo, al cambiar de organización.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/auth/auth_models.dart';
import 'package:visitacampo/core/session/device_handover.dart';
import 'package:visitacampo/data/local/database.dart';

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

  Future<void> trip({required String user, String org = 'org-1', String state = 'pending'}) => db
      .into(db.tripOutbox)
      .insert(
        TripOutboxCompanion.insert(
          id: 't-$user-$state',
          orgId: org,
          userId: user,
          vehicleId: const Value('v-1'),
          routeId: 'r-1',
          materialId: 'm-1',
          volumeM3: 10,
          recordedAt: DateTime.utc(2026, 11, 8),
          requestedBy: 'p-1',
          dispatchedBy: 'p-2',
          receivedBy: 'p-3',
          state: Value(state),
        ),
      );

  test('un viaje sin enviar de otro usuario bloquea la entrada', () async {
    await trip(user: 'ana');

    final result = await handover.prepare(_beto);

    expect(
      result,
      isA<HandoverBlocked>()
          .having((r) => r.trips, 'trips', 1)
          .having((r) => r.visits, 'visits', 0)
          .having((r) => r.fuelFills, 'fuelFills', 0),
    );
  });

  test('el mismo usuario entra con su cola; un rechazado ajeno no bloquea', () async {
    await trip(user: 'ana');
    await trip(user: 'beto', state: 'rejected');

    expect(await handover.prepare(_ana), isA<HandoverReady>());
    expect(await db.select(db.tripOutbox).get(), hasLength(2));
  });

  test('al cambiar de organización se borran la cola y el catálogo de transporte', () async {
    await db
        .into(db.equipmentCache)
        .insert(EquipmentCacheCompanion.insert(id: 'e-1', orgId: 'org-1', code: 'EQ-1', qrIdentifier: 'q', dataJson: '{}'));
    await db.into(db.transportCatalogCache).insert(TransportCatalogCacheCompanion.insert(orgId: 'org-1', version: 't1', dataJson: '{}'));
    await trip(user: 'carla', org: 'org-2', state: 'rejected');

    final result = await handover.prepare(_carla);

    expect(result, isA<HandoverReady>().having((r) => r.wiped, 'wiped', true));
    expect(await db.select(db.tripOutbox).get(), isEmpty);
    expect(await db.select(db.transportCatalogCache).get(), isEmpty);
  });
}
