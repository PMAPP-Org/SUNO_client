// Mantenimiento en la ficha del equipo (M&E fase 3): planes con su estado,
// órdenes abiertas y la descarga de la Hoja de Vida.
import 'dart:typed_data';

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

  Future<void> seed(Map<String, dynamic> json) async {
    transport.fetches.add(EquipmentFetched(version: 'v1', items: [equipment(json)]));
    await manager.refresh();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const EquipmentDetailScreen(equipmentId: _id)),
      ),
    );
    await settle(tester);
  }

  group('modelos', () {
    test('un plan por medidor y uno por fecha se leen con su estado', () {
      final meter = MaintenancePlanInfo.fromJson(planJson('p-1', 'Aceite', state: 'due_soon', remaining: 30));
      expect((meter.byMeter, meter.state, meter.remaining, meter.meterUnit), (true, PlanState.dueSoon, 30, MeterUnit.hours));

      final byDate = MaintenancePlanInfo.fromJson({
        ...planJson('p-2', 'Anual', state: 'overdue', remaining: -4),
        'kind': 'date',
        'meter_unit': null,
        'due_on': '2026-11-04',
      });
      expect((byDate.byMeter, byDate.meterUnit, byDate.dueOn, byDate.state), (false, null, DateTime(2026, 11, 4), PlanState.overdue));
    });

    test('un estado desconocido del servidor no rompe la lectura', () {
      expect(PlanState.parse('algo-nuevo'), PlanState.ok);
      expect(InspectionStatus.parse('algo-nuevo'), InspectionStatus.submitted);
    });

    test('la ficha trae planes y órdenes abiertas', () {
      final item = equipment(
        equipmentJson(
          maintenancePlans: [planJson('p-1', 'Aceite', state: 'ok', remaining: 200)],
          openWorkOrders: [orderJson('o-1', 'OT-0007', status: 'approved')],
        ),
      );

      expect([for (final p in item.maintenancePlans) p.name], ['Aceite']);
      expect([for (final o in item.openWorkOrders) (o.code, o.status)], [('OT-0007', 'approved')]);
    });
  });

  group('pantalla', () {
    testWidgets('muestra cada plan con lo que falta y marca el vencido y el que ya tiene orden', (tester) async {
      await tester.runAsync(
        () => seed(
          equipmentJson(
            maintenancePlans: [
              planJson('p-1', 'Aceite', state: 'due_soon', remaining: 30, hasOpenOrder: true),
              planJson('p-2', 'Filtros', state: 'overdue', remaining: -150, unit: 'kilometers'),
              planJson('p-3', 'Lejano', state: 'ok', remaining: 200.5),
            ],
            openWorkOrders: [orderJson('o-1', 'OT-0007', status: 'in_execution', kind: 'corrective')],
          ),
        ),
      );
      await open(tester);

      await tester.scrollUntilVisible(find.byKey(const ValueKey('plan-p-1')), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Faltan 30 h · con orden abierta'), findsOneWidget);
      expect(find.text('Vencido hace 150 km'), findsOneWidget);
      expect(find.text('Faltan 200.5 h'), findsOneWidget);
      expect(find.text('OT-0007 · Correctiva'), findsOneWidget);
      expect(find.textContaining('En ejecución'), findsOneWidget);
    });

    testWidgets('sin plan lo dice, y un plan por fecha cuenta días', (tester) async {
      await tester.runAsync(() => seed(equipmentJson()));
      await open(tester);
      await tester.scrollUntilVisible(find.byKey(const Key('equipment_no_plans')), 300, scrollable: find.byType(Scrollable).first);
      expect(find.byKey(const Key('equipment_no_plans')), findsOneWidget);
    });

    testWidgets('un plan por fecha muestra los días que faltan', (tester) async {
      await tester.runAsync(
        () => seed(
          equipmentJson(
            maintenancePlans: [
              {...planJson('p-9', 'Revisión anual', state: 'due_soon', remaining: 25), 'kind': 'date', 'meter_unit': null},
              {...planJson('p-8', 'Seguro', state: 'overdue', remaining: -3), 'kind': 'date', 'meter_unit': null},
            ],
          ),
        ),
      );
      await open(tester);

      await tester.scrollUntilVisible(find.byKey(const ValueKey('plan-p-9')), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Faltan 25 días'), findsOneWidget);
      expect(find.text('Vencido hace 3 días'), findsOneWidget);
    });

    testWidgets('si la Hoja de Vida no se puede descargar lo avisa', (tester) async {
      await tester.runAsync(() => seed(equipmentJson()));
      transport.lifeSheet = null;
      await open(tester);

      await tester.ensureVisible(find.byKey(const Key('equipment_life_sheet')));
      await tester.tap(find.byKey(const Key('equipment_life_sheet')));
      await settle(tester);

      expect(transport.lifeSheetsAsked, [_id]);
      expect(find.textContaining('No se pudo descargar la Hoja de Vida'), findsOneWidget);
    });
  });

  group('descarga', () {
    test('el gestor entrega los bytes del servidor y sin sesión no pide nada', () async {
      expect(await manager.lifeSheet(_id), Uint8List.fromList([0x25, 0x50, 0x44, 0x46]));

      final anonymous = EquipmentManager(db: db, transport: transport, session: () => null);
      transport.lifeSheetsAsked.clear();
      expect(await anonymous.lifeSheet(_id), isNull);
      expect(transport.lifeSheetsAsked, isEmpty);
    });
  });
}
