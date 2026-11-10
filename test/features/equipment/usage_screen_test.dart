// Registro de uso en el teléfono: el flujo completo desde la ficha del equipo.
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
import 'package:suno/features/equipment/usage_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/equipment/fake_equipment_transport.dart';
import '../../support/test_app.dart';

const _id = '11111111-1111-4111-8111-111111111111';
const _north = 'pppppppp-0000-4000-8000-000000000001';
const _south = 'pppppppp-0000-4000-8000-000000000002';

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

  Future<void> seed({
    List<Map<String, dynamic>>? projects,
    List<Map<String, dynamic>> recent = const [],
    bool meter = true,
  }) async {
    transport.fetches.add(
      EquipmentFetched(
        version: 'v1',
        items: [
          equipment(
            equipmentJson(
              controlScheme: meter ? 'meter' : 'date',
              meterUnits: meter ? const ['hours'] : const [],
              meters: meter ? [meterJson('hours', 500)] : const [],
              usageProjects: projects ?? [usageProjectJson(_north, 'Norte')],
              recentUsage: recent,
            ),
          ),
        ],
      ),
    );
    await manager.refresh();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Widget app(Widget home) => ProviderScope(
    overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
    child: testApp(home),
  );

  /// Abre el formulario en un día pasado, con las horas por defecto 08:00–12:00.
  Future<void> openForm(WidgetTester tester) async {
    final item = (await tester.runAsync(() => manager.byId(_id)))!;
    await tester.pumpWidget(app(UsageScreen(equipment: item, initialDate: DateTime(2026, 11, 7))));
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('usage_submit')));
    await tester.tap(find.byKey(const Key('usage_submit')));
    await settle(tester);
  }

  testWidgets('con un solo proyecto ya viene elegido y el reporte queda en cola', (tester) async {
    await tester.runAsync(seed);
    await openForm(tester);

    expect(find.text('Hora de inicio: 8:00'), findsOneWidget);
    expect(find.text('Hora de fin: 12:00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('usage_activity')), 'Excavación de zanja');
    await tester.enterText(find.byKey(const Key('usage_location')), 'Frente 2');
    await tester.enterText(find.byKey(const Key('usage_end_meter')), '504,5');
    await submit(tester);
    await tester.pumpAndSettle();

    final pending = (await tester.runAsync(() => manager.pendingUsageFor(_id)))!;
    expect((pending.single.activity, pending.single.startMinutes, pending.single.endMinutes), ('Excavación de zanja', 480, 720));
  });

  testWidgets('la lectura inicial viene con la última conocida', (tester) async {
    await tester.runAsync(seed);
    await openForm(tester);

    final field = tester.widget<TextField>(find.byKey(const Key('usage_start_meter')));
    expect(field.controller!.text, '500');
  });

  testWidgets('sin proyecto asignado lo dice y no ofrece el formulario', (tester) async {
    await tester.runAsync(() => seed(projects: const []));
    await openForm(tester);

    expect(find.byKey(const Key('usage_no_project')), findsOneWidget);
    expect(find.byKey(const Key('usage_submit')), findsNothing);
  });

  testWidgets('con varios proyectos hay que elegir uno; faltar la actividad y las lecturas se explica', (tester) async {
    await tester.runAsync(() => seed(projects: [usageProjectJson(_north, 'Norte'), usageProjectJson(_south, 'Sur')]));
    await openForm(tester);

    await tester.enterText(find.byKey(const Key('usage_end_meter')), '504');
    await submit(tester);
    expect(find.text('Elige el proyecto.'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('usage_project')));
    await tester.tap(find.byKey(const Key('usage_project')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sur').last);
    await tester.pumpAndSettle();
    await submit(tester);
    expect(find.text('Describe la actividad realizada.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('usage_activity')), 'Nivelación');
    await tester.enterText(find.byKey(const Key('usage_end_meter')), '');
    await submit(tester);
    expect(find.text('Escribe las lecturas inicial y final del medidor.'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingUsageCount()), 0);
  });

  testWidgets('un cruce con un uso ya reportado se explica y no se guarda', (tester) async {
    await tester.runAsync(() => seed(recent: [usageJson('u-1', date: '2026-11-07', start: '09:00', end: '11:00', activity: 'Zanja')]));
    await openForm(tester);

    await tester.enterText(find.byKey(const Key('usage_activity')), 'Nivelación');
    await tester.enterText(find.byKey(const Key('usage_end_meter')), '504');
    await submit(tester);

    expect(find.text('Se cruza con otro uso del equipo (Zanja).'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingUsageCount()), 0);
  });

  testWidgets('la lectura final menor que la inicial se explica', (tester) async {
    await tester.runAsync(seed);
    await openForm(tester);

    await tester.enterText(find.byKey(const Key('usage_activity')), 'Zanja');
    await tester.enterText(find.byKey(const Key('usage_end_meter')), '499');
    await submit(tester);

    expect(find.text('La lectura final no puede ser menor que la inicial.'), findsOneWidget);
  });

  testWidgets('un equipo sin medidor no pide lecturas', (tester) async {
    await tester.runAsync(() => seed(meter: false));
    await openForm(tester);

    expect(find.byKey(const Key('usage_start_meter')), findsNothing);
    await tester.enterText(find.byKey(const Key('usage_activity')), 'Zanja');
    await submit(tester);
    await tester.pumpAndSettle();

    expect(await tester.runAsync(() => manager.pendingUsageCount()), 1);
  });

  testWidgets('la ficha ofrece registrar uso y muestra los usos propios y los pendientes', (tester) async {
    await tester.runAsync(
      () => seed(
        recent: [usageJson('u-1', date: '2026-11-06', start: '08:00', end: '12:30', hours: 4.5, activity: 'Zanja', project: 'Norte')],
      ),
    );
    await tester.runAsync(
      () => manager.submitUsageReport(
        equipmentId: _id,
        projectId: _north,
        usageDate: DateTime(2026, 11, 5),
        startMinutes: 480,
        endMinutes: 600,
        activity: 'Relleno',
        startMeter: 500,
        endMeter: 502,
      ),
    );
    await tester.pumpWidget(app(const EquipmentDetailScreen(equipmentId: _id)));
    await settle(tester);

    expect(find.byKey(const Key('equipment_register_usage')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('usage-u-1')), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('Zanja'), findsOneWidget);
    expect(find.textContaining('Norte · 4.5 h'), findsOneWidget);
    expect(find.text('Relleno'), findsOneWidget);
    expect(find.textContaining('Pendiente de envío'), findsWidgets);
  });
}
