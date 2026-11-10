// Teléfono compartido: los reportes de uso sin enviar de otro usuario bloquean
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

  Future<void> usage({required String user, String org = 'org-1', String state = 'pending'}) => db
      .into(db.usageReportOutbox)
      .insert(
        UsageReportOutboxCompanion.insert(
          id: 'u-$user-$state',
          orgId: org,
          userId: user,
          equipmentId: 'e-1',
          projectId: 'p-1',
          usageDate: '2026-11-07',
          startMinutes: 480,
          endMinutes: 720,
          activity: 'Zanja',
          state: Value(state),
        ),
      );

  test('un reporte de uso sin enviar de otro usuario bloquea la entrada', () async {
    await usage(user: 'ana');

    final result = await handover.prepare(_beto);

    expect(
      result,
      isA<HandoverBlocked>()
          .having((r) => r.usageReports, 'usageReports', 1)
          .having((r) => r.records, 'records', 0)
          .having((r) => r.trips, 'trips', 0),
    );
  });

  test('el mismo usuario entra con su cola; uno rechazado ajeno no bloquea', () async {
    await usage(user: 'ana');
    await usage(user: 'beto', state: 'rejected');

    expect(await handover.prepare(_ana), isA<HandoverReady>());
    expect(await db.select(db.usageReportOutbox).get(), hasLength(2));
  });

  test('al cambiar de organización se borra la cola de reportes de uso', () async {
    await db
        .into(db.equipmentCache)
        .insert(EquipmentCacheCompanion.insert(id: 'e-1', orgId: 'org-1', code: 'EQ-1', qrIdentifier: 'q', dataJson: '{}'));
    await usage(user: 'carla', org: 'org-2', state: 'rejected');

    final result = await handover.prepare(_carla);

    expect(result, isA<HandoverReady>().having((r) => r.wiped, 'wiped', true));
    expect(await db.select(db.usageReportOutbox).get(), isEmpty);
  });
}
