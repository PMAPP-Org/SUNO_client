// Tanqueo en el teléfono: el flujo completo desde la ficha del equipo.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/equipment/equipment_manager.dart';
import 'package:visitacampo/core/equipment/equipment_models.dart';
import 'package:visitacampo/core/equipment/equipment_transport.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/equipment/equipment_detail_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/equipment/fake_equipment_transport.dart';
import '../../support/test_app.dart';

const _id = '11111111-1111-4111-8111-111111111111';
const _north = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _south = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _tank = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

void main() {
  late AppDatabase db;
  late FakeEquipmentTransport transport;
  late EquipmentManager manager;
  late AppDependencies dependencies;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeEquipmentTransport();
    manager = EquipmentManager(db: db, transport: transport, session: () => (orgId: 'org-1', userId: 'ana'));
    dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: AuthController(transport: FakeAuthTransport(), tokenStore: FakeTokenStore(), deviceId: 'd'),
      deviceId: 'd',
      equipment: manager,
    );
  });
  tearDown(() => db.close());

  Future<void> seed({List<Map<String, dynamic>> stations = const [], List<Map<String, dynamic>> stores = const []}) async {
    transport.fetches.add(
      EquipmentFetched(
        version: 'v1',
        items: [equipment(equipmentJson(meterUnits: const ['kilometers'], meters: [meterJson('kilometers', 1000)]))],
      ),
    );
    await manager.refresh();
    transport.catalogFetches.add(
      FuelCatalogFetched(
        version: 'c1',
        catalog: FuelCatalogInfo.fromJson({'stations': stations, 'stores': stores}),
      ),
    );
    await manager.refreshFuelCatalog();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> openFuelForm(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const EquipmentDetailScreen(equipmentId: _id)),
      ),
    );
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('equipment_register_fuel')));
    await tester.tap(find.byKey(const Key('equipment_register_fuel')));
    await tester.pumpAndSettle();
    await settle(tester);
  }

  testWidgets('con una sola estación ya viene elegida: vale, galones y lectura la dejan en cola', (tester) async {
    await tester.runAsync(
      () => seed(
        stations: [
          {'id': _north, 'name': 'Norte', 'supplier': 'Terpel'},
        ],
      ),
    );
    await openFuelForm(tester);

    await tester.enterText(find.byKey(const Key('fuel_voucher')), 'V-100');
    await tester.enterText(find.byKey(const Key('fuel_gallons')), '25,5');
    await tester.enterText(find.byKey(const Key('fuel_meter')), '1100');
    await tester.enterText(find.byKey(const Key('fuel_driver')), 'Pedro');
    await tester.ensureVisible(find.byKey(const Key('fuel_submit')));
    await tester.tap(find.byKey(const Key('fuel_submit')));
    await settle(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('Tanqueo guardado'), findsOneWidget);
    final pending = (await tester.runAsync(() => manager.pendingFuelFillsFor(_id)))!;
    expect((pending.single.voucherNumber, pending.single.gallons), ('V-100', 25.5));
    expect(find.textContaining('Vale V-100'), findsOneWidget);
  });

  testWidgets('sin catálogo avisa que hay que sincronizar y no ofrece el formulario', (tester) async {
    await tester.runAsync(() => seed());
    await openFuelForm(tester);

    expect(find.byKey(const Key('fuel_no_catalog')), findsOneWidget);
    expect(find.byKey(const Key('fuel_submit')), findsNothing);
  });

  testWidgets('con varias estaciones hay que elegir una; faltar el vale se explica', (tester) async {
    await tester.runAsync(
      () => seed(
        stations: [
          {'id': _north, 'name': 'Norte', 'supplier': 'Terpel'},
          {'id': _south, 'name': 'Sur', 'supplier': 'Terpel'},
        ],
      ),
    );
    await openFuelForm(tester);

    await tester.enterText(find.byKey(const Key('fuel_voucher')), 'V-1');
    await tester.enterText(find.byKey(const Key('fuel_gallons')), '10');
    await tester.enterText(find.byKey(const Key('fuel_meter')), '1100');
    await tester.ensureVisible(find.byKey(const Key('fuel_submit')));
    await tester.tap(find.byKey(const Key('fuel_submit')));
    await settle(tester);
    expect(find.text('Elige la estación o el tanque.'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('fuel_station')));
    await tester.tap(find.byKey(const Key('fuel_station')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terpel · Sur').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('fuel_voucher')), ' ');
    await tester.ensureVisible(find.byKey(const Key('fuel_submit')));
    await tester.tap(find.byKey(const Key('fuel_submit')));
    await settle(tester);
    expect(find.text('Escribe el número de vale.'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingFuelFillCount()), 0);
  });

  testWidgets('con solo un tanque propio arranca en "Tanque propio" y la lectura baja se explica', (tester) async {
    await tester.runAsync(
      () => seed(
        stores: [
          {'id': _tank, 'name': 'Tanque 1'},
        ],
      ),
    );
    await openFuelForm(tester);

    expect(find.byKey(const Key('fuel_store')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('fuel_voucher')), 'S-1');
    await tester.enterText(find.byKey(const Key('fuel_gallons')), '40');
    await tester.enterText(find.byKey(const Key('fuel_meter')), '900');
    await tester.ensureVisible(find.byKey(const Key('fuel_submit')));
    await tester.tap(find.byKey(const Key('fuel_submit')));
    await settle(tester);

    expect(find.textContaining('menor que la anterior (1000)'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingFuelFillCount()), 0);
  });
}
