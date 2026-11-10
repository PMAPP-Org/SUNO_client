// `CaptureScreen` (Paso 22): plantilla de la caché local → formulario dinámico
// → foto, GPS → guardado offline en una sola transacción. Sin red y sin
// hardware: GPS y cámara son dobles (`MockGnss` del plan).
import 'dart:convert';
import 'dart:io';

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
import 'package:suno/core/capture/photo_capture.dart';
import 'package:suno/core/capture/record_capture.dart';
import 'package:suno/core/location/gps_sampler.dart';
import 'package:suno/core/location/location_source.dart';
import 'package:suno/core/providers.dart';
import 'package:suno/data/local/database.dart';
import 'package:suno/data/local/form_template_repository.dart';
import 'package:suno/features/capture/capture_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../support/test_app.dart';

/// Sin [fix], el GPS del teléfono está apagado. Con él, entrega las lecturas
/// buenas que pide la política por defecto: la hoja se cierra sola.
class MockGnss implements LocationSource {
  const MockGnss(this.fix);
  final LocationFix? fix;

  @override
  Future<LocationStatus> ensureReady() async => fix == null ? LocationStatus.serviceDisabled : LocationStatus.ready;

  @override
  Stream<LocationFix> watch() => Stream.fromIterable(List.filled(const GpsPolicy().samples, fix!));

  @override
  Future<void> openSettings(LocationStatus status) async {}
}

class FakeCamera implements PhotoCapture {
  var _taken = 0;

  @override
  Future<CapturedPhoto?> takePhoto() async {
    final n = _taken++;
    return CapturedPhoto(
      file: File.fromUri(Uri.file('/tmp/foto-$n.jpg')),
      sha256: n.toRadixString(16).padLeft(64, '0'),
      sizeBytes: 1024,
      mime: 'image/jpeg',
    );
  }
}

TokenPair _tokenPair() => TokenPair(
  accessToken: 'access-1',
  tokenType: 'Bearer',
  expiresIn: 900,
  refreshToken: 'refresh-1',
  refreshExpiresIn: 5184000,
  serverTime: DateTime.utc(2026, 10, 17, 12),
);

const _user = UserProfile(id: 'user-1', username: 'agente1', orgId: 'org-1', roles: ['agent']);

Map<String, dynamic> templateRow() => {
  'id': 'tv-1',
  'org_id': 'org-1',
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
        'key': 'tiene_planta',
        'type': 'boolean',
        'label': {'es': '¿Hay planta?'},
        'required': true,
      },
      {
        'key': 'altura_cm',
        'type': 'number',
        'label': {'es': 'Altura (cm)'},
        'visible_if': {'op': 'eq', 'field': 'tiene_planta', 'value': true},
      },
      {
        'key': 'foto_planta',
        'type': 'photo',
        'label': {'es': 'Foto de la planta'},
        'required': true,
        'visible_if': {'op': 'eq', 'field': 'tiene_planta', 'value': true},
      },
    ],
  },
};

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<AppDependencies> buildDependencies({bool withTemplate = true, LocationFix? fix}) async {
    final transport = FakeAuthTransport()
      ..loginResponses.add(AuthResult.ok(LoginResponse(tokens: _tokenPair(), user: _user)));
    final controller = AuthController(transport: transport, tokenStore: FakeTokenStore(), deviceId: 'device-1');
    await controller.login(
      username: 'agente1',
      password: 'secret',
      deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
    );
    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: controller,
      deviceId: 'device-1',
      locationSource: MockGnss(fix),
      photoCapture: FakeCamera(),
    );
    if (withTemplate) await dependencies.formTemplates.upsertFromServerRow(templateRow());
    return dependencies;
  }

  Future<void> pumpCapture(WidgetTester tester, AppDependencies dependencies, {CaptureScreen screen = const CaptureScreen()}) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(screen),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('desde una asignación: muestra su punto, la distancia y la guarda con su id (Fase B)', (tester) async {
    // ~111 m al norte del punto asignado.
    final dependencies = await buildDependencies(fix: const LocationFix(lat: 4.601, lon: -74, accuracyM: 3));
    await db
        .into(db.assignments)
        .insert(
          AssignmentsCompanion.insert(
            id: 'asg-1',
            orgId: 'org-1',
            version: 1,
            templateVersionId: 'tv-1',
            assignedTo: 'user-1',
            title: const Value('Finca El Roble'),
            lat: const Value(4.6),
            lon: const Value(-74),
          ),
        );
    await pumpCapture(tester, dependencies, screen: const CaptureScreen(assignmentId: 'asg-1'));

    expect(find.text('Asignación: Finca El Roble'), findsOneWidget);
    expect(find.textContaining('Punto asignado'), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture_get_location_button')));
    await tester.pumpAndSettle();
    expect(find.text('Estás a 111 m del punto asignado.'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'No'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('capture_save_button')));
    await tester.pumpAndSettle();
    final record = await db.select(db.records).getSingle();
    expect(record.assignmentId, 'asg-1');
  });

  testWidgets('captura completa offline: formulario, foto del campo, GPS y foto adicional', (tester) async {
    final dependencies = await buildDependencies(fix: const LocationFix(lat: 4.6, lon: -74.08, accuracyM: 4.2));
    await pumpCapture(tester, dependencies);

    // Una sola plantilla: se abre sola, con el formulario dinámico.
    expect(find.text('¿Hay planta? *'), findsOneWidget);
    expect(find.text('Altura (cm)'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Sí'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Altura (cm)'), '35');
    await tester.tap(find.text('Tomar foto'));
    await tester.pumpAndSettle();
    expect(find.text('Foto adjunta.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture_get_location_button')));
    await tester.pumpAndSettle();
    expect(find.text('lat 4.600000, lon -74.080000 (±4 m)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture_add_photo_button')));
    await tester.pumpAndSettle();
    expect(find.text('1 foto adicional'), findsOneWidget);

    await tester.tap(find.byKey(const Key('capture_save_button')));
    await tester.pumpAndSettle();

    // Todo quedó en la BD local, sin red: la UI puede mostrarlo ya.
    final record = await db.select(db.records).getSingle();
    expect(record.templateVersionId, 'tv-1');
    expect(record.lat, 4.6);
    final answers = jsonDecode(record.answersJson) as Map<String, dynamic>;
    expect(answers['tiene_planta'], true);
    expect(answers['altura_cm'], 35);
    final attachments = await db.select(db.recordAttachments).get();
    expect(attachments.map((a) => a.id), contains(answers['foto_planta']));
    expect(attachments, hasLength(2), reason: 'la del campo y la adicional');
    expect(await db.select(db.attachmentQueue).get(), hasLength(2));
    expect((await db.select(db.outboxOps).get()).map((o) => o.entity), [
      'record',
      'record_attachment',
      'record_attachment',
    ]);
  });

  testWidgets('con campos obligatorios sin responder no guarda nada', (tester) async {
    final dependencies = await buildDependencies();
    await pumpCapture(tester, dependencies);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Sí'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('capture_save_button')));
    await tester.pumpAndSettle();

    expect(find.text('Revisa los campos marcados antes de guardar.'), findsOneWidget);
    expect(find.text('Este campo es obligatorio.'), findsOneWidget, reason: 'la foto obligatoria');
    expect(await db.select(db.records).get(), isEmpty);
    expect(await db.select(db.outboxOps).get(), isEmpty);
  });

  testWidgets('sin plantillas en el dispositivo pide sincronizar', (tester) async {
    final dependencies = await buildDependencies(withTemplate: false);
    await pumpCapture(tester, dependencies);

    expect(find.byKey(const Key('capture_no_templates')), findsOneWidget);
    expect(find.byKey(const Key('capture_save_button')), findsNothing);
  });

  testWidgets('sin GPS se avisa y se puede guardar igual', (tester) async {
    final dependencies = await buildDependencies();
    await pumpCapture(tester, dependencies);

    await tester.tap(find.byKey(const Key('capture_get_location_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gps_not_ready')), findsOneWidget, reason: 'dice que el GPS está apagado');
    await tester.tap(find.byKey(const Key('gps_cancel')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No se pudo obtener la ubicación'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'No'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('capture_save_button')));
    await tester.pumpAndSettle();
    final record = await db.select(db.records).getSingle();
    expect(record.lat, isNull);
  });

  Future<void> addTask({double? lastValidated}) => db.replaceScheduleTasks(
    orgId: 'org-1',
    userId: 'user-1',
    version: 'v1',
    now: DateTime.utc(2026, 11, 2),
    rows: [
      ScheduleTasksCompanion.insert(
        id: 'task-1',
        orgId: 'org-1',
        userId: 'user-1',
        projectId: 'p-1',
        projectName: 'Obra Norte',
        wbs: '1.2',
        outlineNumber: '1.2',
        name: 'Descapote',
        lastValidatedPct: Value(lastValidated),
        position: 0,
      ),
    ],
  );

  Future<void> pickTask(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('capture_task_picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task_picker_item-task-1')));
    await tester.pumpAndSettle();
  }

  testWidgets('avance de campo: vincula el registro a una tarea con su % (costos, etapa 1)', (tester) async {
    final dependencies = await buildDependencies();
    await addTask(lastValidated: 40);
    await pumpCapture(tester, dependencies);

    await pickTask(tester);
    await tester.enterText(find.byKey(const Key('capture_progress_field')), '35,5');
    await tester.pump();
    expect(find.byKey(const Key('capture_progress_below')), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'No'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('capture_save_button')));
    await tester.pumpAndSettle();

    final record = await db.select(db.records).getSingle();
    expect((record.taskId, record.progressPct), ('task-1', 35.5));
    final payload = jsonDecode((await db.select(db.outboxOps).getSingle()).payloadJson) as Map<String, dynamic>;
    expect((payload['task_id'], payload['progress_pct']), ('task-1', 35.5));
  });

  testWidgets('con tarea elegida, sin un % válido no guarda', (tester) async {
    final dependencies = await buildDependencies();
    await addTask();
    await pumpCapture(tester, dependencies);

    await pickTask(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'No'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('capture_save_button')));
    await tester.pumpAndSettle();
    expect(find.text('Indica el % de avance acumulado.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('capture_progress_field')), '120');
    await tester.tap(find.byKey(const Key('capture_save_button')));
    await tester.pumpAndSettle();
    expect(find.text('Escribe un número entre 0 y 100, con hasta dos decimales.'), findsOneWidget);
    expect(await db.select(db.records).get(), isEmpty);
  });

  testWidgets('sin tareas asignadas no aparece la sección', (tester) async {
    final dependencies = await buildDependencies();
    await pumpCapture(tester, dependencies);
    expect(find.byKey(const Key('capture_task_picker')), findsNothing);
  });


  testWidgets('elegir otra tarea borra el % de la anterior', (tester) async {
    final dependencies = await buildDependencies();
    await addTask(lastValidated: 40);
    await db.batch(
      (b) => b.insert(
        db.scheduleTasks,
        ScheduleTasksCompanion.insert(
          id: 'task-2',
          orgId: 'org-1',
          userId: 'user-1',
          projectId: 'p-1',
          projectName: 'Obra Norte',
          wbs: '1.3',
          outlineNumber: '1.3',
          name: 'Cerramiento',
          position: 1,
        ),
      ),
    );
    await pumpCapture(tester, dependencies);
    await pickTask(tester);
    await tester.enterText(find.byKey(const Key('capture_progress_field')), '55');
    await tester.pump();

    await tester.tap(find.byKey(const Key('capture_task_picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task_picker_item-task-2')));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byKey(const Key('capture_progress_field'))).controller!.text, isEmpty);
  });

  group('editar un registro ya vinculado', () {
    Future<String> linkedRecord(AppDependencies dependencies) async {
      await addTask(lastValidated: 40);
      final lookup = await dependencies.formTemplates.forRecord(orgId: 'org-1', templateVersionId: 'tv-1');
      return dependencies.recordCapture.save(
        identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1', roles: ['agent']),
        templateVersionId: 'tv-1',
        definition: (lookup as TemplateReady).definition,
        answers: {'tiene_planta': false},
        captured: const {},
        progress: const TaskProgress(taskId: 'task-1', pct: 35.5),
      );
    }

    testWidgets('carga la tarea y el %; guardar sin tocar nada no envía el par', (tester) async {
      final dependencies = await buildDependencies();
      final recordId = await linkedRecord(dependencies);
      await pumpCapture(tester, dependencies, screen: CaptureScreen(editRecordId: recordId));

      expect(find.text('1.2 Descapote'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(const Key('capture_progress_field'))).controller!.text, '35,5');
      await tester.tap(find.byKey(const Key('capture_save_button')));
      await tester.pumpAndSettle();

      expect(await db.select(db.outboxOps).get(), hasLength(1)); // solo el alta
    });

    testWidgets('"Sin tarea" desvincula: viaja el par en null', (tester) async {
      final dependencies = await buildDependencies();
      final recordId = await linkedRecord(dependencies);
      await pumpCapture(tester, dependencies, screen: CaptureScreen(editRecordId: recordId));

      await tester.tap(find.byKey(const Key('capture_task_picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task_picker_none')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('capture_save_button')));
      await tester.pumpAndSettle();

      final ops = await db.select(db.outboxOps).get();
      expect(ops, hasLength(2));
      expect(jsonDecode(ops.last.payloadJson), {'id': recordId, 'task_id': null, 'progress_pct': null});
      final record = await db.select(db.records).getSingle();
      expect((record.taskId, record.progressPct), (null, null));
    });
  });
}
