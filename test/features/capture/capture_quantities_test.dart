// Costos, pieza 4b: en una tarea medida por cantidades la captura pide "Cantidad hoy"
// por ítem en lugar del %, exige nota donde corresponde, confirma antes de descartar lo
// escrito al cambiar de tarea, y deja de solo lectura un registro ya validado.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/app_dependencies.dart';
import 'package:suno/core/auth/auth_controller.dart';
import 'package:suno/core/auth/auth_models.dart';
import 'package:suno/core/auth/auth_result.dart';
import 'package:suno/core/location/location_source.dart';
import 'package:suno/core/location/spot_location.dart';
import 'package:suno/core/providers.dart';
import 'package:suno/data/local/database.dart';
import 'package:suno/features/capture/capture_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../support/test_app.dart';

class _FakeSpot implements SpotLocation {
  @override
  Future<LocationFix?> read() async => const LocationFix(lat: 4.6, lon: -74.08, accuracyM: 7);
}

Finder _byKeyPrefix(String prefix) => find.byWidgetPredicate(
  (widget) => widget.key is ValueKey<String> && (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<AppDependencies> buildDependencies() async {
    final transport = FakeAuthTransport()
      ..loginResponses.add(
        AuthResult.ok(
          LoginResponse(
            tokens: TokenPair(
              accessToken: 'access-1',
              tokenType: 'Bearer',
              expiresIn: 900,
              refreshToken: 'refresh-1',
              refreshExpiresIn: 5184000,
              serverTime: DateTime.utc(2026, 11, 9, 12),
            ),
            user: const UserProfile(id: 'user-1', username: 'agente1', orgId: 'org-1', roles: ['agent']),
          ),
        ),
      );
    final auth = AuthController(transport: transport, tokenStore: FakeTokenStore(), deviceId: 'device-1');
    await auth.login(
      username: 'agente1',
      password: 'secret',
      deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
    );
    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: auth,
      deviceId: 'device-1',
      spotLocation: _FakeSpot(),
    );
    await dependencies.formTemplates.upsertFromServerRow({
      'id': 'tv-1',
      'org_id': 'org-1',
      'version': 1,
      'change_seq': 1,
      'deleted_at': null,
      'template_id': 'tpl-1',
      'name': 'Avance',
      'version_number': 1,
      'published_at': '2026-10-01T00:00:00Z',
      'definition': {
        'fields': [
          {
            'key': 'notas',
            'type': 'text',
            'label': {'es': 'Notas'},
          },
        ],
      },
    });
    await db.replaceScheduleTasks(
      orgId: 'org-1',
      userId: 'user-1',
      version: 'v1',
      now: DateTime.utc(2026, 11, 9),
      rows: [
        ScheduleTasksCompanion.insert(
          id: 'task-q',
          orgId: 'org-1',
          userId: 'user-1',
          projectId: 'p-1',
          projectName: 'Obra Norte',
          wbs: '1.3',
          outlineNumber: '1.3',
          name: 'Excavación',
          position: 0,
          measuredBy: const Value('quantities'),
        ),
        ScheduleTasksCompanion.insert(
          id: 'task-1',
          orgId: 'org-1',
          userId: 'user-1',
          projectId: 'p-1',
          projectName: 'Obra Norte',
          wbs: '1.2',
          outlineNumber: '1.2',
          name: 'Descapote',
          position: 1,
        ),
      ],
      planned: [
        TaskPlannedItemsCompanion.insert(
          taskId: 'task-q',
          itemId: 'item-1',
          code: '1.1',
          description: 'Excavación mecánica',
          unit: 'm3',
          plannedQuantity: 100,
          validatedQuantity: 95,
          position: 0,
        ),
      ],
      locations: [
        TaskLocationOptionsCompanion.insert(
          taskId: 'task-q',
          locationId: 'loc-1',
          label: 'Tramo 2',
          isTaskLocation: true,
          position: 0,
        ),
      ],
      catalog: [
        ProjectItemsCompanion.insert(
          projectId: 'p-1',
          itemId: 'item-1',
          code: '1.1',
          description: 'Excavación mecánica',
          unit: 'm3',
          position: 0,
        ),
        ProjectItemsCompanion.insert(
          projectId: 'p-1',
          itemId: 'item-2',
          code: '1.2',
          description: 'Retiro de sobrantes',
          unit: 'm3',
          position: 1,
        ),
      ],
    );
    return dependencies;
  }

  Future<void> pumpCapture(
    WidgetTester tester,
    AppDependencies dependencies, {
    CaptureScreen screen = const CaptureScreen(),
  }) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(overrides: [appDependenciesProvider.overrideWithValue(dependencies)], child: testApp(screen)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pickTask(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(const Key('capture_task_picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('task_picker_item-$id')));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('capture_save_button')));
    await tester.pumpAndSettle();
  }

  Future<void> insertRecord(List<Map<String, Object?>> quantities, {bool validated = false}) => db
      .into(db.records)
      .insert(
        RecordsCompanion.insert(
          id: 'record-1',
          orgId: 'org-1',
          version: 2,
          templateVersionId: 'tv-1',
          answersJson: jsonEncode({'notas': 'x'}),
          capturedAt: DateTime.utc(2026, 11, 8, 15),
          deviceId: 'device-1',
          createdBy: 'user-1',
          serverDataJson: const Value('{}'),
          taskId: const Value('task-q'),
          quantitiesJson: Value(jsonEncode(quantities)),
          knownValidated: Value(validated),
        ),
      );

  testWidgets('se guardan las cantidades con sus datos automáticos y progress_pct null', (tester) async {
    final dependencies = await buildDependencies();
    await pumpCapture(tester, dependencies);
    await pickTask(tester, 'task-q');
    expect(find.byKey(const Key('capture_progress_field')), findsNothing);
    expect(find.text('Planeado 100 m3 · validado 95 m3'), findsOneWidget);

    await tester.enterText(_byKeyPrefix('quantity_field-').first, '10');
    await tester.pumpAndSettle();
    expect(_byKeyPrefix('quantity_overrun-'), findsOneWidget);
    await save(tester);

    final record = await db.select(db.records).getSingle();
    expect((record.taskId, record.progressPct), ('task-q', null));
    final payload = jsonDecode((await db.select(db.outboxOps).getSingle()).payloadJson) as Map<String, dynamic>;
    expect(payload['progress_pct'], isNull);
    final row = (payload['quantities'] as List).single as Map<String, dynamic>;
    expect((row['item_id'], row['quantity'], row['location_id'], row['location_mode']), ('item-1', 10.0, null, 'task'));
    expect(row['client_id'], isA<String>());
    expect(row['captured_at'], isA<String>());
    expect(row['gps'], {'lat': 4.6, 'lon': -74.08, 'accuracy_m': 7.0});
    expect(row['seen'], {'planned': 100.0, 'validated': 95.0, 'location_id': 'loc-1'});
    expect(jsonDecode(record.quantitiesJson), payload['quantities']);
  });

  testWidgets('un ítem no planeado sin nota no se guarda', (tester) async {
    final dependencies = await buildDependencies();
    await pumpCapture(tester, dependencies);
    await pickTask(tester, 'task-q');
    await tester.tap(find.byKey(const Key('quantity_add_unplanned')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_item-item-2')));
    await tester.pumpAndSettle();
    await tester.enterText(_byKeyPrefix('quantity_field-').last, '3');
    await save(tester);
    expect(find.text('Escribe una nota: el ítem no está planeado o la cantidad es negativa.'), findsOneWidget);
    expect(await db.select(db.records).get(), isEmpty);

    await tester.enterText(_byKeyPrefix('quantity_note-').last, 'sobrante');
    await save(tester);
    final record = await db.select(db.records).getSingle();
    expect([for (final row in jsonDecode(record.quantitiesJson) as List) (row as Map)['item_id']], ['item-2']);
  });

  testWidgets('sin ninguna cantidad no se guarda', (tester) async {
    final dependencies = await buildDependencies();
    await pumpCapture(tester, dependencies);
    await pickTask(tester, 'task-q');
    await save(tester);
    expect(find.text('Escribe al menos una cantidad distinta de 0.'), findsOneWidget);
    expect(await db.select(db.records).get(), isEmpty);
  });

  testWidgets('cambiar de tarea con cantidades escritas pide confirmar', (tester) async {
    final dependencies = await buildDependencies();
    await pumpCapture(tester, dependencies);
    await pickTask(tester, 'task-q');
    await tester.enterText(_byKeyPrefix('quantity_field-').first, '5');
    await tester.pumpAndSettle();

    await pickTask(tester, 'task-1');
    expect(find.text('¿Cambiar de tarea?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('quantity_discard_cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity_section')), findsOneWidget);

    await pickTask(tester, 'task-1');
    await tester.tap(find.byKey(const Key('quantity_discard_confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quantity_section')), findsNothing);
    expect(find.byKey(const Key('capture_progress_field')), findsOneWidget);
  });

  testWidgets('registro ya validado: cantidades de solo lectura y no se envía nada', (tester) async {
    final dependencies = await buildDependencies();
    await insertRecord([
      {'item_id': 'item-1', 'location_id': null, 'quantity': 4, 'note': '', 'client_id': 'g-1'},
    ], validated: true);
    await pumpCapture(tester, dependencies, screen: const CaptureScreen(editRecordId: 'record-1'));
    expect(find.byKey(const Key('quantity_read_only')), findsOneWidget);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('quantity_field-g-1'))).enabled, isFalse);
    expect(tester.widget<ListTile>(find.byKey(const Key('capture_task_picker'))).enabled, isFalse);
    await save(tester);
    expect(await db.select(db.outboxOps).get(), isEmpty);
  });

  testWidgets('editar un registro bajado sin datos automáticos no se los agrega a sus filas', (tester) async {
    // Revisión del servidor: una fila sin `client_id` (captura anterior o del pull) se
    // reenvía sin datos automáticos nuevos; solo la fila nueva los lleva.
    final dependencies = await buildDependencies();
    await insertRecord([
      {
        'item_id': 'item-1',
        'location_id': null,
        'quantity': 4,
        'note': '',
        'client_id': null,
        'captured_at': null,
        'gps': null,
        'seen': null,
        'location_mode': null,
      },
    ]);
    await pumpCapture(tester, dependencies, screen: const CaptureScreen(editRecordId: 'record-1'));
    await tester.enterText(_byKeyPrefix('quantity_field-').first, '6');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('quantity_add_unplanned')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_item-item-2')));
    await tester.pumpAndSettle();
    await tester.enterText(_byKeyPrefix('quantity_field-').last, '1');
    await tester.enterText(_byKeyPrefix('quantity_note-').last, 'sobrante');
    await tester.pumpAndSettle();
    await save(tester);

    final payload = jsonDecode((await db.select(db.outboxOps).getSingle()).payloadJson) as Map<String, dynamic>;
    final rows = (payload['quantities'] as List).cast<Map<String, dynamic>>();
    expect(rows.first, {'item_id': 'item-1', 'location_id': null, 'quantity': 6.0, 'note': ''});
    expect(rows.last['item_id'], 'item-2');
    expect(rows.last['client_id'], isA<String>());
  });
}
