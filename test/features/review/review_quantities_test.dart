// Costos, pieza 4b: un rechazo de cantidades se ve en "Para revisar" nombrando la fila
// (código del ítem) y se corrige reasignando el ítem; al guardar se reenvía.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/app_dependencies.dart';
import 'package:suno/core/auth/auth_controller.dart';
import 'package:suno/core/capture/record_capture.dart';
import 'package:suno/core/forms/form_definition.dart';
import 'package:suno/core/providers.dart';
import 'package:suno/core/sync/result.dart';
import 'package:suno/core/sync/sync_engine.dart';
import 'package:suno/core/sync/sync_transport.dart';
import 'package:suno/data/local/database.dart';
import 'package:suno/features/review/review_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/sync/fake_sync_transport.dart';
import '../../support/test_app.dart';

const _definitionJson = {
  'fields': [
    {
      'key': 'notas',
      'type': 'text',
      'label': {'es': 'Notas'},
    },
  ],
};

Map<String, Object?> _row(String clientId, String itemId) => {
  'item_id': itemId,
  'location_id': null,
  'quantity': 2.0,
  'note': itemId == 'item-9' ? 'viejo' : '',
  'client_id': clientId,
  'captured_at': '2026-11-09T14:00:00.000Z',
  'gps': null,
  'seen': null,
  'location_mode': 'task',
};

void main() {
  late AppDatabase db;
  late FakeSyncTransport transport;
  late SyncEngine engine;
  late AppDependencies dependencies;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeSyncTransport();
    var ids = 0;
    engine = SyncEngine(db: db, transport: transport, deviceId: 'device-1', idGenerator: () => 'op-${ids++}');
    dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: AuthController(
        transport: FakeAuthTransport(),
        tokenStore: FakeTokenStore(),
        deviceId: 'device-1',
      ),
      deviceId: 'device-1',
      syncEngine: engine,
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
      'definition': _definitionJson,
    });
    await db.replaceScheduleTasks(
      orgId: 'org-1',
      userId: 'user-1',
      version: 'v1',
      now: DateTime.utc(2026, 11, 9),
      rows: [
        ScheduleTasksCompanion.insert(
          id: 'task-1',
          orgId: 'org-1',
          userId: 'user-1',
          projectId: 'p-1',
          projectName: 'Obra',
          wbs: '1.2',
          outlineNumber: '1.2',
          name: 'Descapote',
          position: 0,
          measuredBy: const Value('quantities'),
        ),
      ],
      planned: [
        TaskPlannedItemsCompanion.insert(
          taskId: 'task-1',
          itemId: 'item-1',
          code: '2.1',
          description: 'Concreto zapatas',
          unit: 'm3',
          plannedQuantity: 10,
          validatedQuantity: 0,
          position: 0,
        ),
      ],
      catalog: [
        ProjectItemsCompanion.insert(
          projectId: 'p-1',
          itemId: 'item-1',
          code: '2.1',
          description: 'Concreto zapatas',
          unit: 'm3',
          position: 0,
        ),
        ProjectItemsCompanion.insert(
          projectId: 'p-1',
          itemId: 'item-2',
          code: '2.2',
          description: 'Acero de refuerzo',
          unit: 'kg',
          position: 1,
        ),
      ],
    );
    await db
        .into(db.knownItems)
        .insert(KnownItemsCompanion.insert(itemId: 'item-9', code: '9.9', description: 'Retirado', unit: 'un'));
    await RecordCapture(db: db, idGenerator: () => 'cap-${ids++}').save(
      identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: (parseFormDefinition(_definitionJson) as DefinitionOk).definition,
      answers: {'notas': 'x'},
      captured: const {},
      progress: TaskProgress(taskId: 'task-1', quantities: [_row('q-1', 'item-1'), _row('q-2', 'item-9')]),
    );
    final op = await db.select(db.outboxOps).getSingle();
    transport.pushResponses.add(
      Result.ok(
        PushResponse(
          schemaVersion: 2,
          results: [
            PushOpOutcome(
              opUuid: op.opUuid,
              status: 'rejected',
              error: const PushOpError(
                code: 'validation_error',
                message: 'The item is not a measurable item of a budget of the task\'s project.',
                details: {'field': 'quantities', 'reason': 'item_not_in_project'},
              ),
            ),
          ],
        ),
      ),
    );
    await engine.drainOutbox();
  });
  tearDown(() => db.close());

  Future<void> pumpReview(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const ReviewScreen(orgId: 'org-1')),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('nombra la fila rechazada y la corrige reasignando el ítem', (tester) async {
    await pumpReview(tester);
    expect(find.text('Fila del ítem 9.9: el ítem no es del presupuesto del proyecto.'), findsOneWidget);
    expect(find.text('Cantidades: El ítem no es del presupuesto del proyecto de la tarea.'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('review_correct_quantities')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quantity_flagged-q-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('quantity_flagged-q-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('quantity_reassign-q-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_item-item-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quantity_flagged-q-2')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('quantity_correction_save')));
    await tester.tap(find.byKey(const Key('quantity_correction_save')));
    await tester.pumpAndSettle();

    final op = await db.select(db.outboxOps).getSingle();
    expect(op.state, 'pending');
    final quantities = (jsonDecode(op.payloadJson) as Map)['quantities'] as List;
    expect([for (final row in quantities) (row as Map)['item_id']], ['item-1', 'item-2']);
    expect(find.text('No hay registros para revisar.'), findsOneWidget);
  });
}
