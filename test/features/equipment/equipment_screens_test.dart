// "Equipos" (fase 1): la lista desde la caché con búsqueda, la ficha con
// medidores y alertas, y el registro de una lectura que queda en cola.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/app_dependencies.dart';
import 'package:suno/core/auth/auth_controller.dart';
import 'package:suno/core/equipment/equipment_manager.dart';
import 'package:suno/core/equipment/equipment_transport.dart';
import 'package:suno/core/providers.dart';
import 'package:suno/data/local/database.dart';
import 'package:suno/features/equipment/equipment_detail_screen.dart';
import 'package:suno/features/equipment/equipment_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/equipment/fake_equipment_transport.dart';
import '../../support/test_app.dart';

const _volqueta = '11111111-1111-4111-8111-111111111111';
const _cargador = '33333333-3333-4333-8333-333333333333';

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

  Future<void> seed(List<Map<String, dynamic>> items) async {
    transport.fetches.add(EquipmentFetched(version: 'v1', items: [for (final i in items) equipment(i)]));
    await manager.refresh();
  }

  Widget app(Widget home) => ProviderScope(
    overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
    child: testApp(home),
  );

  // La E/S de Drift es real: el reloj simulado de los tests de widgets no la avanza.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  testWidgets('la lista muestra la caché, avisa de vencimientos y filtra por placa', (tester) async {
    await tester.runAsync(
      () => seed([
        equipmentJson(
          alerts: [
            {'source': 'document', 'name': 'SOAT', 'expires_on': '2026-11-01', 'days_left': -7},
          ],
        ),
        equipmentJson(id: _cargador, code: 'EQ-2', name: 'Cargador', plate: 'ABC123'),
      ]),
    );

    await tester.pumpWidget(app(const EquipmentScreen()));
    await settle(tester);

    expect(find.text('EQ-1 · Volqueta 1'), findsOneWidget);
    expect(find.text('EQ-2 · Cargador'), findsOneWidget);
    expect(find.textContaining('1 alerta'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('equipment_search')), 'abc');
    await tester.pump();
    expect(find.text('EQ-1 · Volqueta 1'), findsNothing);
    expect(find.text('EQ-2 · Cargador'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('equipment_search')), 'zzz');
    await tester.pump();
    expect(find.byKey(const Key('equipment_no_matches')), findsOneWidget);
  });

  testWidgets('sin equipos y sin red muestra el estado vacío y avisa que no pudo actualizar', (tester) async {
    await tester.pumpWidget(app(const EquipmentScreen()));
    await settle(tester);

    expect(find.byKey(const Key('equipment_empty')), findsOneWidget);
    expect(find.textContaining('No se pudo actualizar'), findsOneWidget);
  });

  testWidgets('la ficha muestra medidores, alertas vencidas y documentos', (tester) async {
    await tester.runAsync(
      () => seed([
        equipmentJson(
          meters: [meterJson('hours', 339), meterJson('kilometers', 12000.5)],
          alerts: [
            {'source': 'document', 'name': 'Póliza', 'expires_on': '2026-11-01', 'days_left': -7},
            {'source': 'field', 'name': 'SOAT', 'expires_on': '2026-11-20', 'days_left': 12},
          ],
          documents: [
            {'id': 'd-1', 'type': 'insurance', 'name': 'Póliza', 'number': 'P-1', 'expires_on': '2026-11-01'},
          ],
          fields: [
            {'name': 'Capacidad m3', 'type': 'number', 'value': 14.5},
          ],
        ),
      ]),
    );

    await tester.pumpWidget(app(const EquipmentDetailScreen(equipmentId: _volqueta)));
    await settle(tester);

    expect(find.text('339'), findsOneWidget);
    expect(find.text('12000.5'), findsOneWidget);
    expect(find.textContaining('Póliza: venció el'), findsOneWidget);
    expect(find.textContaining('SOAT: vence el'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Capacidad m3'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('14.5'), findsOneWidget);
  });

  testWidgets('registrar una lectura la deja pendiente de envío', (tester) async {
    await tester.runAsync(() => seed([equipmentJson(meters: [meterJson('hours', 339)])]));

    await tester.pumpWidget(app(const EquipmentDetailScreen(equipmentId: _volqueta)));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('equipment_record_reading')));
    await tester.tap(find.byKey(const Key('equipment_record_reading')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reading_value')), '345,5');
    await tester.tap(find.byKey(const Key('reading_save')));
    await settle(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('Lectura guardada'), findsOneWidget);
    final pending = (await tester.runAsync(() => manager.pendingFor(_volqueta)))!;
    expect(pending.single.value, 345.5);
    expect(find.textContaining('Pendiente de envío'), findsOneWidget);
  });

  testWidgets('una lectura menor que la anterior se explica y no se guarda', (tester) async {
    await tester.runAsync(() => seed([equipmentJson(meters: [meterJson('hours', 339)])]));

    await tester.pumpWidget(app(const EquipmentDetailScreen(equipmentId: _volqueta)));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('equipment_record_reading')));
    await tester.tap(find.byKey(const Key('equipment_record_reading')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reading_value')), '100');
    await tester.tap(find.byKey(const Key('reading_save')));
    await settle(tester);
    await tester.pump();

    expect(find.textContaining('menor que la anterior (339)'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingCount()), 0);
  });

  testWidgets('un valor que no es número no llega al gestor', (tester) async {
    await tester.runAsync(() => seed([equipmentJson()]));

    await tester.pumpWidget(app(const EquipmentDetailScreen(equipmentId: _volqueta)));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const Key('equipment_record_reading')));
    await tester.tap(find.byKey(const Key('equipment_record_reading')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('reading_value')), 'abc');
    await tester.tap(find.byKey(const Key('reading_save')));
    await tester.pump();

    expect(find.textContaining('Escribe una lectura válida'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingCount()), 0);
  });
}
