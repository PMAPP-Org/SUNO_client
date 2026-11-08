// Viaje en el teléfono: el flujo completo desde la lista de equipos.
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
import 'package:visitacampo/features/equipment/equipment_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/equipment/fake_equipment_transport.dart';
import '../../support/test_app.dart';

const _route = 'rrrrrrrr-0000-4000-8000-000000000001';
const _material = 'mmmmmmmm-0000-4000-8000-000000000001';
const _truck = 'vvvvvvvv-0000-4000-8000-000000000001';
const _ana = 'pppppppp-0000-4000-8000-00000000000a';
const _beto = 'pppppppp-0000-4000-8000-00000000000b';
const _carla = 'pppppppp-0000-4000-8000-00000000000c';

void main() {
  late AppDatabase db;
  late FakeEquipmentTransport transport;
  late EquipmentManager manager;
  late AppDependencies dependencies;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeEquipmentTransport();
    manager = EquipmentManager(db: db, transport: transport, session: () => (orgId: 'org-1', userId: _ana));
    dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: AuthController(transport: FakeAuthTransport(), tokenStore: FakeTokenStore(), deviceId: 'd'),
      deviceId: 'd',
      equipment: manager,
    );
  });
  tearDown(() => db.close());

  Future<void> seed({bool withCatalog = true}) async {
    transport.fetches.add(EquipmentFetched(version: 'v1', items: [equipment(equipmentJson())]));
    await manager.refresh();
    if (!withCatalog) return;
    transport.transportFetches.add(
      TransportCatalogFetched(
        version: 't1',
        catalog: TransportCatalogInfo.fromJson({
          'routes': [
            {'id': _route, 'origin': 'Cantera', 'destination': 'Km 12', 'zone': 'Oriente', 'distance_km': 8.5},
          ],
          'materials': [
            {'id': _material, 'name': 'Gravas'},
          ],
          'vehicles': [
            {'id': _truck, 'plate': 'EXG871', 'contractor': 'Transportes TDR', 'capacity_m3': 14},
          ],
          'people': [
            {'id': _ana, 'name': 'Ana'},
            {'id': _beto, 'name': 'Beto'},
            {'id': _carla, 'name': 'Carla'},
          ],
        }),
      ),
    );
    await manager.refreshTransportCatalog();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> openTripForm(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const EquipmentScreen()),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const Key('equipment_register_trip')));
    await tester.pumpAndSettle();
    await settle(tester);
  }

  Future<void> pick(WidgetTester tester, String key, String label) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('sin catálogo avisa que hay que sincronizar y no ofrece el formulario', (tester) async {
    await tester.runAsync(() => seed(withCatalog: false));
    await openTripForm(tester);

    expect(find.byKey(const Key('trip_no_catalog')), findsOneWidget);
    expect(find.byKey(const Key('trip_submit')), findsNothing);
  });

  testWidgets('un viaje de terceros completo queda en cola y aparece en la lista', (tester) async {
    await tester.runAsync(() => seed());
    await openTripForm(tester);

    await pick(tester, 'trip_vehicle', 'EXG871 · Transportes TDR');
    await tester.enterText(find.byKey(const Key('trip_volume')), '12,5');
    await pick(tester, 'trip_requested', 'Carla');
    await pick(tester, 'trip_dispatched', 'Ana');
    await pick(tester, 'trip_received', 'Beto');
    await tester.ensureVisible(find.byKey(const Key('trip_submit')));
    await tester.tap(find.byKey(const Key('trip_submit')));
    await settle(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('Viaje guardado'), findsOneWidget);
    final pending = (await tester.runAsync(() => manager.pendingTrips()))!;
    expect((pending.single.vehicleLabel, pending.single.volumeM3), ('EXG871', 12.5));
    expect(find.text('EXG871 · 12.5 m³'), findsOneWidget);
  });

  testWidgets('despachar y recibir con la misma persona se explica y no se guarda', (tester) async {
    await tester.runAsync(() => seed());
    await openTripForm(tester);
    await pick(tester, 'trip_vehicle', 'EXG871 · Transportes TDR');
    await tester.enterText(find.byKey(const Key('trip_volume')), '10');
    await pick(tester, 'trip_requested', 'Carla');
    await pick(tester, 'trip_dispatched', 'Beto');
    await pick(tester, 'trip_received', 'Beto');
    await tester.ensureVisible(find.byKey(const Key('trip_submit')));
    await tester.tap(find.byKey(const Key('trip_submit')));
    await settle(tester);

    expect(find.text('Quien despacha no puede ser quien recibe.'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingTripCount()), 0);
  });

  testWidgets('faltan datos: elegir vehículo, tramo y material con un solo registro, y el volumen sobre la capacidad', (tester) async {
    await tester.runAsync(() => seed());
    await openTripForm(tester);

    await tester.ensureVisible(find.byKey(const Key('trip_submit')));
    await tester.tap(find.byKey(const Key('trip_submit')));
    await settle(tester);
    expect(find.text('Elige el vehículo del viaje.'), findsOneWidget);

    await pick(tester, 'trip_vehicle', 'EXG871 · Transportes TDR');
    await tester.enterText(find.byKey(const Key('trip_volume')), '20');
    await pick(tester, 'trip_requested', 'Carla');
    await pick(tester, 'trip_dispatched', 'Ana');
    await pick(tester, 'trip_received', 'Beto');
    await tester.ensureVisible(find.byKey(const Key('trip_submit')));
    await tester.tap(find.byKey(const Key('trip_submit')));
    await settle(tester);

    expect(find.textContaining('supera la capacidad del vehículo (14 m³)'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingTripCount()), 0);
  });
}
