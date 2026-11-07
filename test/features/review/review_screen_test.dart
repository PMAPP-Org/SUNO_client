// Pantalla "Para revisar" (Paso 23). Criterio de salida del plan: ningún
// camino de la UI descarta trabajo del agente sin confirmación explícita.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/app_dependencies.dart';
import 'package:suno/core/auth/auth_controller.dart';
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

const _org = 'org-1';

Map<String, dynamic> _templateRow() => {
  'id': 'tv-1',
  'org_id': _org,
  'version': 1,
  'change_seq': 1,
  'deleted_at': null,
  'template_id': 'tpl-1',
  'name': 'Inspección',
  'version_number': 1,
  'published_at': '2026-10-01T00:00:00Z',
  'definition': {
    'fields': [
      {
        'key': 'altura_cm',
        'type': 'number',
        'label': {'es': 'Altura (cm)'},
        'max': 500,
      },
    ],
  },
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
      authController: AuthController(transport: FakeAuthTransport(), tokenStore: FakeTokenStore(), deviceId: 'device-1'),
      deviceId: 'device-1',
      syncEngine: engine,
    );
    await dependencies.formTemplates.upsertFromServerRow(_templateRow());
    await db
        .into(db.records)
        .insert(
          RecordsCompanion.insert(
            id: 'record-1',
            orgId: _org,
            version: 1,
            templateVersionId: 'tv-1',
            answersJson: jsonEncode({'altura_cm': 900}),
            lat: const Value(4.6),
            capturedAt: DateTime.utc(2026, 10, 17, 10),
            deviceId: 'device-1',
            createdBy: 'user-1',
          ),
        );
  });
  tearDown(() => db.close());

  Future<void> quarantineWith(PushOpOutcome Function(String opUuid) outcome, {String opType = 'create'}) async {
    await engine.enqueueRecordOp(
      entityId: 'record-1',
      opType: opType,
      baseVersion: opType == 'create' ? null : 1,
      payload: {
        'id': 'record-1',
        'answers': {'altura_cm': 900},
      },
    );
    final op = await db.select(db.outboxOps).getSingle();
    transport.pushResponses.add(Result.ok(PushResponse(schemaVersion: 2, results: [outcome(op.opUuid)])));
    await engine.drainOutbox();
  }

  Future<void> rejected() => quarantineWith(
    (opUuid) => PushOpOutcome(
      opUuid: opUuid,
      status: 'rejected',
      error: const PushOpError(
        code: 'validation_error',
        message: 'Answers do not match the form template version schema.',
        details: {
          'errors': [
            {'field': 'answers.altura_cm', 'reason': 'out_of_range'},
          ],
        },
      ),
    ),
  );

  Future<void> conflict() => quarantineWith(
    (opUuid) => PushOpOutcome(
      opUuid: opUuid,
      status: 'conflict',
      serverVersion: 3,
      serverRow: {
        'entity': 'record',
        'data': {
          'id': 'record-1',
          'org_id': _org,
          'version': 3,
          'change_seq': 9,
          'deleted_at': null,
          'assignment_id': null,
          'template_version_id': 'tv-1',
          'answers': {'altura_cm': 120},
          'lat': 4.6,
          'lon': null,
          'accuracy_m': null,
          'altitude_m': null,
          'captured_at': '2026-10-17T10:00:00.000Z',
          'device_id': 'device-1',
          'created_by': 'user-1',
        },
      },
    ),
    opType: 'update',
  );

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const ReviewScreen(orgId: _org)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('rechazo: motivo y campo con su etiqueta, y las tres acciones', (tester) async {
    await rejected();
    await pump(tester);

    expect(find.text('Rechazado por el servidor'), findsOneWidget);
    expect(find.text('Altura (cm): El valor está fuera del rango permitido.'), findsOneWidget);
    expect(find.byKey(const Key('review_correct')), findsOneWidget);
    expect(find.byKey(const Key('review_retry')), findsOneWidget);
    expect(find.byKey(const Key('review_discard')), findsOneWidget);
  });

  testWidgets('descartar exige confirmación: cancelar no borra nada', (tester) async {
    await rejected();
    await pump(tester);

    await tester.tap(find.byKey(const Key('review_discard')));
    await tester.pumpAndSettle();
    expect(find.text('¿Descartar este registro?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('review_confirm_cancel')));
    await tester.pumpAndSettle();

    expect(await db.select(db.records).get(), hasLength(1), reason: 'sin confirmar, el registro sigue');
    expect(await db.select(db.outboxOps).get(), hasLength(1));

    // Cerrar el diálogo tocando fuera tampoco descarta.
    await tester.tap(find.byKey(const Key('review_discard')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(await db.select(db.records).get(), hasLength(1));

    await tester.tap(find.byKey(const Key('review_discard')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('review_confirm_destructive')));
    await tester.pumpAndSettle();

    expect(await db.select(db.records).get(), isEmpty);
    expect(find.byKey(const Key('review_empty')), findsOneWidget);
  });

  testWidgets('corregir: el formulario marca el campo, se arregla y se reenvía', (tester) async {
    await rejected();
    await pump(tester);

    await tester.tap(find.byKey(const Key('review_correct')));
    await tester.pumpAndSettle();
    expect(find.text('El valor está fuera del rango permitido.'), findsOneWidget, reason: 'error del servidor ya visible');

    await tester.enterText(find.widgetWithText(TextField, 'Altura (cm)'), '120');
    await tester.pump();
    expect(find.text('El valor está fuera del rango permitido.'), findsNothing);
    await tester.tap(find.byKey(const Key('correction_save_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('review_empty')), findsOneWidget);
    final op = await db.select(db.outboxOps).getSingle();
    expect(op.state, 'pending');
    expect((jsonDecode(op.payloadJson) as Map)['answers'], {'altura_cm': 120});
  });

  testWidgets('conflicto: tabla de diferencias y "quedarme con la del servidor" confirmado', (tester) async {
    await conflict();
    await pump(tester);

    expect(find.text('Cambió en el servidor'), findsOneWidget);
    expect(find.byKey(const Key('review_diff_table')), findsOneWidget);
    expect(find.text('Altura (cm)'), findsOneWidget);
    expect(find.text('900'), findsOneWidget, reason: 'tu versión');
    expect(find.text('120'), findsOneWidget, reason: 'la del servidor');

    await tester.tap(find.byKey(const Key('review_accept_server')));
    await tester.pumpAndSettle();
    expect(find.text('¿Quedarte con la versión del servidor?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('review_confirm_destructive')));
    await tester.pumpAndSettle();

    final record = await db.select(db.records).getSingle();
    expect(record.version, 3);
    expect(jsonDecode(record.answersJson), {'altura_cm': 120});
  });

  testWidgets('conflicto: "enviar mi versión" no pide confirmación (no pierde nada)', (tester) async {
    await conflict();
    await pump(tester);

    await tester.tap(find.byKey(const Key('review_resend_mine')));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    final op = await db.select(db.outboxOps).getSingle();
    expect((op.opType, op.baseVersion, op.state), ('update', 3, 'pending'));
  });

  testWidgets('rechazo por la tarea: nombra el campo y ofrece quitarla', (tester) async {
    await quarantineWith(
      (opUuid) => PushOpOutcome(
        opUuid: opUuid,
        status: 'rejected',
        error: const PushOpError(
          code: 'forbidden',
          message: 'Only a responsible of the task can report its progress.',
          details: {'field': 'task_id', 'reason': 'not_responsible'},
        ),
      ),
    );
    await pump(tester);

    expect(find.text('Tarea del cronograma: Ya no eres responsable de esta tarea.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('review_unlink_task')));
    await tester.pumpAndSettle();

    expect((await db.select(db.outboxOps).getSingle()).state, 'pending');
    expect(find.text('Listo: se enviará en la próxima sincronización.'), findsOneWidget);
  });

  testWidgets('rechazo por registro validado: lo explica y no ofrece quitar la tarea', (tester) async {
    await quarantineWith(
      (opUuid) => PushOpOutcome(
        opUuid: opUuid,
        status: 'rejected',
        error: const PushOpError(
          code: 'validation_error',
          message: 'The record was already validated.',
          details: {'field': 'progress_pct', 'reason': 'record_validated'},
        ),
      ),
      opType: 'update',
    );
    await pump(tester);

    expect(
      find.text('El registro ya fue validado: su tarea y % no se pueden cambiar desde el teléfono.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('review_unlink_task')), findsNothing);
    expect(find.byKey(const Key('review_retry')), findsNothing);
    expect(find.byKey(const Key('review_discard')), findsOneWidget);
  });


  testWidgets('borrar un registro validado: lo explica y no ofrece reintentar', (tester) async {
    await quarantineWith(
      (opUuid) => PushOpOutcome(
        opUuid: opUuid,
        status: 'rejected',
        error: const PushOpError(
          code: 'validation_error',
          message: 'The record was already validated.',
          details: {'field': 'id', 'reason': 'record_validated'},
        ),
      ),
      opType: 'delete',
    );
    await pump(tester);

    expect(find.text('El registro ya fue validado: no se puede borrar desde el teléfono.'), findsOneWidget);
    expect(find.byKey(const Key('review_retry')), findsNothing);
  });

  testWidgets('tarea inexistente: "La tarea ya no existe en el cronograma."', (tester) async {
    await quarantineWith(
      (opUuid) => PushOpOutcome(
        opUuid: opUuid,
        status: 'rejected',
        error: const PushOpError(
          code: 'not_found',
          message: 'Unknown task.',
          details: {'field': 'task_id', 'reason': 'unknown_reference'},
        ),
      ),
    );
    await pump(tester);

    expect(find.text('Tarea del cronograma: La tarea ya no existe en el cronograma.'), findsOneWidget);
    expect(find.byKey(const Key('review_unlink_task')), findsOneWidget);
  });
}
