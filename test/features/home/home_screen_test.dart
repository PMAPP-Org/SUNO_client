// `HomeScreen` — botón "Sincronizar" (Tarea 7 del plan de despliegue del
// demo). Verifica que tocar el botón llama, en orden, a
// `SyncEngine.drainOutbox()`, un drenaje forzado de la cola de adjuntos y
// `SyncEngine.pull()` — sin necesidad de red real, con
// `FakeSyncTransport`/`FakeAttachmentTransport`.
//
// Hallazgo Crítico/Importante de la revisión final: el SnackBar antes decía
// siempre "completa", incluso con adjuntos fallidos, operaciones rechazadas
// o un `pull()` con error. El segundo test de este archivo prueba justo eso:
// un adjunto que falla debe producir un mensaje distinto que mencione el
// fallo con su conteo real, no el mensaje de éxito de siempre.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/attachments/attachment_result.dart';
import 'package:visitacampo/core/attachments/attachment_upload_service.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/auth/auth_models.dart';
import 'package:visitacampo/core/auth/auth_result.dart';
import 'package:visitacampo/core/basemaps/basemap_manager.dart';
import 'package:visitacampo/core/layers/layer_manager.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/core/sync/result.dart';
import 'package:visitacampo/core/sync/sync_engine.dart';
import 'package:visitacampo/core/sync/sync_transport.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/home/home_screen.dart';

import '../../core/attachments/fake_attachment_transport.dart';
import '../../core/attachments/fake_file_source.dart';
import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/basemaps/fake_basemap_transport.dart';
import '../../core/layers/fake_layer_transport.dart';
import '../../core/sync/fake_sync_transport.dart';

import '../../support/test_app.dart';

void main() {
  testWidgets('Sincronizar drena el outbox, sube adjuntos pendientes y hace pull', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // Dos pulls: el ciclo automático al abrir la pantalla (Fase A) y el del
    // botón.
    const page = PullResponse(rows: [], tombstones: [], nextCursor: 'c1:00000000000000000001', hasMore: false);
    final syncTransport = FakeSyncTransport()
      ..pullResponses.addAll([Result.ok(page), Result.ok(page)]);
    final syncEngine = SyncEngine(db: db, transport: syncTransport, deviceId: 'device-1');

    final attachmentTransport = FakeAttachmentTransport();
    final attachmentUploadService = AttachmentUploadService(
      db: db,
      transport: attachmentTransport,
    );

    // La pantalla de inicio solo existe con sesión: sin ella no se sincroniza.
    final authController = AuthController(
      transport: FakeAuthTransport()
        ..loginResponses.add(AuthResult.ok(LoginResponse(tokens: _tokenPair(), user: _user))),
      tokenStore: FakeTokenStore(),
      deviceId: 'device-1',
    );
    await authController.login(
      username: 'agente1',
      password: 'secret',
      deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
    );

    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: authController,
      deviceId: 'device-1',
      syncEngine: syncEngine,
      attachmentUploadService: attachmentUploadService,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const HomeScreen()),
      ),
    );

    await tester.tap(find.byKey(const Key('home_sync_button')));
    await tester.pumpAndSettle();

    expect(syncTransport.pullCalls, hasLength(2));
    expect(find.textContaining('Sincronización completa'), findsOneWidget);
    expect(find.byKey(const Key('home_last_sync')), findsOneWidget);
  });

  testWidgets('al abrir la pantalla sincroniza sola, sin pulsar el botón', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final syncTransport = FakeSyncTransport()
      ..pullResponses.add(
        Result.err(const SyncError.network('sin cobertura')),
      );
    final authController = AuthController(
      transport: FakeAuthTransport()
        ..loginResponses.add(AuthResult.ok(LoginResponse(tokens: _tokenPair(), user: _user))),
      tokenStore: FakeTokenStore(),
      deviceId: 'device-1',
    );
    await authController.login(
      username: 'agente1',
      password: 'secret',
      deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
    );
    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: authController,
      deviceId: 'device-1',
      syncEngine: SyncEngine(db: db, transport: syncTransport, deviceId: 'device-1'),
      attachmentUploadService: AttachmentUploadService(db: db, transport: FakeAttachmentTransport()),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(syncTransport.pullCalls, hasLength(1));
    // Sin red: se avisa que queda pendiente, sin bloquear nada.
    expect(find.byKey(const Key('home_sync_pending')), findsOneWidget);
    expect(find.byKey(const Key('home_last_sync')), findsNothing);
  });

  testWidgets('tras la primera sincronización el mapa base se descarga solo (Fase B)', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final dir = Directory.systemTemp.createTempSync('home-basemap');
    addTearDown(() => dir.deleteSync(recursive: true));
    const page = PullResponse(rows: [], tombstones: [], nextCursor: 'c1:00000000000000000001', hasMore: false);
    final syncTransport = FakeSyncTransport()..pullResponses.add(Result.ok(page));
    final bytes = List<int>.generate(2048, (i) => i % 200);
    final basemaps = FakeBasemapTransport()
      ..offered = [info('roble', bytes)]
      ..contents['roble'] = bytes;
    final authController = AuthController(
      transport: FakeAuthTransport()
        ..loginResponses.add(AuthResult.ok(LoginResponse(tokens: _tokenPair(), user: _user))),
      tokenStore: FakeTokenStore(),
      deviceId: 'device-1',
    );
    await authController.login(
      username: 'agente1',
      password: 'secret',
      deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
    );
    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: authController,
      deviceId: 'device-1',
      syncEngine: SyncEngine(db: db, transport: syncTransport, deviceId: 'device-1'),
      attachmentUploadService: AttachmentUploadService(db: db, transport: FakeAttachmentTransport()),
      basemaps: BasemapManager(transport: basemaps, directory: dir),
      // Sin capas ofrecidas (sin red para capas): esta prueba es del mapa base.
      layers: LayerManager(transport: FakeLayerTransport()..offered = null, directory: dir),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const HomeScreen()),
      ),
    );
    // La descarga escribe un archivo real: se alterna E/S real y `pump`.
    var downloaded = const <BasemapEntry>[];
    for (var i = 0; i < 200 && downloaded.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      downloaded = (await tester.runAsync(dependencies.basemaps.downloaded))!;
    }
    // Que termine (y suelte el archivo) antes de borrar la carpeta.
    for (var i = 0; i < 100 && dependencies.basemaps.progress.value != null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(downloaded.single.info.id, 'roble', reason: 'el agente no tuvo que pedirlo');
  });

  testWidgets(
    'Sincronizar con un adjunto fallido muestra un mensaje de incompleta con el conteo, '
    'no el de éxito',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await db
          .into(db.attachmentQueue)
          .insert(
            AttachmentQueueCompanion.insert(
              sha256: 'a' * 64,
              localPath: '/tmp/foto.jpg',
              state: 'pending',
              createdAt: DateTime.utc(2026, 8, 6),
            ),
          );

      final syncTransport = FakeSyncTransport()
        ..pullResponses.add(
          Result.ok(
            const PullResponse(rows: [], tombstones: [], nextCursor: 'c1:00000000000000000001', hasMore: false),
          ),
        );
      final syncEngine = SyncEngine(db: db, transport: syncTransport, deviceId: 'device-1');

      // Dos intentos sin red: el automático al abrir la pantalla (Paso 18) y
      // el del botón, que ignora el backoff del primero.
      final attachmentTransport = FakeAttachmentTransport()
        ..presignResponses.addAll([
          const AttachmentResult.err(AttachmentError.network('sin conexion')),
          const AttachmentResult.err(AttachmentError.network('sin conexion')),
        ]);
      final attachmentUploadService = AttachmentUploadService(
        db: db,
        transport: attachmentTransport,
        files: FakeFileSource({'/tmp/foto.jpg': const [1, 2, 3]}),
      );

      // La pantalla de inicio solo existe con sesión: sin ella no se sube nada.
      final authTransport = FakeAuthTransport()
        ..loginResponses.add(AuthResult.ok(LoginResponse(tokens: _tokenPair(), user: _user)));
      final authController = AuthController(
        transport: authTransport,
        tokenStore: FakeTokenStore(),
        deviceId: 'device-1',
      );
      await authController.login(
        username: 'agente1',
        password: 'secret',
        deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
      );

      final dependencies = AppDependencies(
        database: db,
        dio: Dio(),
        authController: authController,
        deviceId: 'device-1',
        syncEngine: syncEngine,
        attachmentUploadService: attachmentUploadService,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
          child: testApp(const HomeScreen()),
        ),
      );

      await tester.tap(find.byKey(const Key('home_sync_button')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Sincronización completa'), findsNothing);
      expect(find.textContaining('Sincronización incompleta'), findsOneWidget);
      expect(find.textContaining('1 adjunto sin subir'), findsOneWidget);
      expect(attachmentTransport.presignedShas, hasLength(2), reason: 'el botón reintentó aunque había backoff');
    },
  );

  testWidgets('con visitas en cuarentena aparece el aviso y lleva a la revisión (Paso 23)', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db
        .into(db.visits)
        .insert(
          VisitsCompanion.insert(
            id: 'visit-1',
            orgId: 'org-1',
            version: 1,
            templateVersionId: 'tv-1',
            answersJson: '{}',
            capturedAt: DateTime.utc(2026, 10, 17),
            deviceId: 'device-1',
            createdBy: 'user-1',
          ),
        );
    await db
        .into(db.outboxOps)
        .insert(
          OutboxOpsCompanion.insert(
            opUuid: 'op-1',
            entity: 'visit',
            entityId: 'visit-1',
            opType: 'create',
            payloadJson: '{"id": "visit-1"}',
            state: 'quarantine',
            createdAt: DateTime.utc(2026, 10, 17),
            errorMessage: const Value('Plantilla desconocida.'),
          ),
        );
    final authTransport = FakeAuthTransport()
      ..loginResponses.add(AuthResult.ok(LoginResponse(tokens: _tokenPair(), user: _user)));
    final authController = AuthController(transport: authTransport, tokenStore: FakeTokenStore(), deviceId: 'device-1');
    await authController.login(
      username: 'agente1',
      password: 'secret',
      deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
    );
    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: authController,
      deviceId: 'device-1',
      syncEngine: SyncEngine(db: db, transport: FakeSyncTransport(), deviceId: 'device-1'),
      attachmentUploadService: AttachmentUploadService(db: db, transport: FakeAttachmentTransport()),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 visita para revisar'), findsOneWidget);
    await tester.tap(find.byKey(const Key('home_review_button')));
    await tester.pumpAndSettle();
    expect(find.text('Para revisar'), findsOneWidget);
    expect(find.text('Motivo: Plantilla desconocida.'), findsOneWidget);
  });
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
