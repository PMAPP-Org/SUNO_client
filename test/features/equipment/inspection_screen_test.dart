// Preoperacional en el teléfono: el flujo completo desde la ficha del equipo.
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

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/equipment/fake_equipment_transport.dart';
import '../../support/test_app.dart';

const _id = '11111111-1111-4111-8111-111111111111';
const _brakes = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _lights = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

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

  Map<String, dynamic> withChecklist({List<Map<String, dynamic>> recent = const []}) => equipmentJson(
    meters: [meterJson('hours', 339)],
    checklist: [checklistItemJson(_brakes, 'Frenos', critical: true), checklistItemJson(_lights, 'Luces')],
    recentInspections: recent,
  );

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

  Future<void> answer(WidgetTester tester, String itemId, String label) async {
    final segment = find.descendant(of: find.byKey(ValueKey('inspection-item-$itemId')), matching: find.text(label));
    await tester.ensureVisible(segment);
    await tester.tap(segment);
    await tester.pump();
  }

  testWidgets('un equipo sin lista de chequeo no ofrece preoperacional', (tester) async {
    await tester.runAsync(() => seed(equipmentJson()));
    await open(tester);

    expect(find.byKey(const Key('equipment_no_checklist')), findsOneWidget);
    expect(find.byKey(const Key('equipment_start_inspection')), findsNothing);
  });

  testWidgets('responder todo y enviar deja el preoperacional en cola', (tester) async {
    await tester.runAsync(() => seed(withChecklist()));
    await open(tester);

    await tester.tap(find.byKey(const Key('equipment_start_inspection')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('inspection_meter')), '345');
    await answer(tester, _brakes, 'Novedad');
    await tester.enterText(find.byKey(const ValueKey('inspection-note-$_brakes')), 'Pedal blando');
    await answer(tester, _lights, 'Cumple');
    await tester.ensureVisible(find.byKey(const Key('inspection_submit')));
    await tester.tap(find.byKey(const Key('inspection_submit')));
    await settle(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('Preoperacional guardado'), findsOneWidget);
    final pending = (await tester.runAsync(() => manager.pendingInspectionsFor(_id)))!;
    expect((pending.single.hasFaults, pending.single.rejected), (true, false));
    expect(find.textContaining('Pendiente de envío'), findsOneWidget);
  });

  testWidgets('faltan ítems: lo explica y no guarda nada', (tester) async {
    await tester.runAsync(() => seed(withChecklist()));
    await open(tester);

    await tester.tap(find.byKey(const Key('equipment_start_inspection')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('inspection_meter')), '345');
    await answer(tester, _brakes, 'Cumple');
    await tester.ensureVisible(find.byKey(const Key('inspection_submit')));
    await tester.tap(find.byKey(const Key('inspection_submit')));
    await settle(tester);

    expect(find.textContaining('Falta responder: Luces'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingInspectionCount()), 0);
  });

  testWidgets('una novedad sin descripción no se envía', (tester) async {
    await tester.runAsync(() => seed(withChecklist()));
    await open(tester);

    await tester.tap(find.byKey(const Key('equipment_start_inspection')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('inspection_meter')), '345');
    await answer(tester, _brakes, 'Novedad');
    await answer(tester, _lights, 'Cumple');
    await tester.ensureVisible(find.byKey(const Key('inspection_submit')));
    await tester.tap(find.byKey(const Key('inspection_submit')));
    await settle(tester);

    expect(find.textContaining('Describe la novedad de: Frenos'), findsOneWidget);
    expect(await tester.runAsync(() => manager.pendingInspectionCount()), 0);
  });

  testWidgets('la ficha muestra el estado de revisión y el motivo del rechazo', (tester) async {
    await tester.runAsync(
      () => seed(
        withChecklist(
          recent: [
            inspectionSummaryJson('r-1', status: 'rejected', hasFaults: true, comment: 'Foto ilegible'),
            inspectionSummaryJson('r-2', status: 'approved'),
          ],
        ),
      ),
    );
    await open(tester);

    await tester.scrollUntilVisible(find.text('Rechazado'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Foto ilegible'), findsOneWidget);
    expect(find.text('Aprobado'), findsOneWidget);
  });
}
