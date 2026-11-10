// Teléfono compartido: los tanqueos sin enviar de otro usuario bloquean la
// entrada y se borran, con el catálogo, al cambiar de organización.
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

  Future<void> fill({required String user, String org = 'org-1', String state = 'pending'}) => db
      .into(db.fuelFillOutbox)
      .insert(
        FuelFillOutboxCompanion.insert(
          id: 'f-$user-$state',
          orgId: org,
          userId: user,
          equipmentId: 'e-1',
          source: 'station',
          voucherNumber: 'V-1',
          filledAt: DateTime.utc(2026, 11, 8),
          gallons: 10,
          state: Value(state),
        ),
      );

  test('un tanqueo sin enviar de otro usuario bloquea la entrada', () async {
    await fill(user: 'ana');

    final result = await handover.prepare(_beto);

    expect(
      result,
      isA<HandoverBlocked>()
          .having((r) => r.fuelFills, 'fuelFills', 1)
          .having((r) => r.records, 'records', 0)
          .having((r) => r.readings, 'readings', 0)
          .having((r) => r.inspections, 'inspections', 0),
    );
  });

  test('el mismo usuario entra con su cola; un rechazado ajeno no bloquea', () async {
    await fill(user: 'ana');
    await fill(user: 'beto', state: 'rejected');

    expect(await handover.prepare(_ana), isA<HandoverReady>());
    expect(await db.select(db.fuelFillOutbox).get(), hasLength(2));
  });

  test('al cambiar de organización se borran la cola y el catálogo de combustible', () async {
    await db
        .into(db.equipmentCache)
        .insert(EquipmentCacheCompanion.insert(id: 'e-1', orgId: 'org-1', code: 'EQ-1', qrIdentifier: 'q', dataJson: '{}'));
    await db.into(db.fuelCatalogCache).insert(FuelCatalogCacheCompanion.insert(orgId: 'org-1', version: 'c1', dataJson: '{}'));
    await fill(user: 'carla', org: 'org-2', state: 'rejected');

    final result = await handover.prepare(_carla);

    expect(result, isA<HandoverReady>().having((r) => r.wiped, 'wiped', true));
    expect(await db.select(db.fuelFillOutbox).get(), isEmpty);
    expect(await db.select(db.fuelCatalogCache).get(), isEmpty);
  });
}
