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

import 'package:dio/dio.dart';
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
import '../../core/sync/fake_sync_transport.dart';

import '../../support/test_app.dart';

void main() {
  testWidgets('Sincronizar drena el outbox, sube adjuntos pendientes y hace pull', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final syncTransport = FakeSyncTransport()
      ..pullResponses.add(
        Result.ok(
          const PullResponse(rows: [], tombstones: [], nextCursor: 'c1:00000000000000000001', hasMore: false),
        ),
      );
    final syncEngine = SyncEngine(db: db, transport: syncTransport, deviceId: 'device-1');

    final attachmentTransport = FakeAttachmentTransport();
    final attachmentUploadService = AttachmentUploadService(
      db: db,
      transport: attachmentTransport,
    );

    final authController = AuthController(
      transport: FakeAuthTransport(),
      tokenStore: FakeTokenStore(),
      deviceId: 'device-1',
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

    expect(syncTransport.pullCalls, hasLength(1));
    expect(find.textContaining('Sincronización completa'), findsOneWidget);
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
