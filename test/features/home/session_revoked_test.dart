// Paso 16, tarea 7: si el servidor revoca la sesión (refresh caducado,
// revocado o reutilizado → 401), la app vuelve al login con un aviso. La
// outbox no se toca: `AuthController` no tiene ninguna referencia a ella.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/attachments/attachment_upload_service.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/auth/auth_models.dart';
import 'package:visitacampo/core/auth/auth_result.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/auth/login_screen.dart';
import 'package:visitacampo/features/home/home_screen.dart';

import '../../core/attachments/fake_attachment_transport.dart';
import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../support/test_app.dart';

void main() {
  testWidgets('refresh rechazado con 401 → aviso y vuelta al login', (
    tester,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final transport = FakeAuthTransport()
      ..loginResponses.add(
        AuthResult.ok(
          LoginResponse(
            tokens: TokenPair(
              accessToken: 'a',
              tokenType: 'Bearer',
              expiresIn: 900,
              refreshToken: 'r',
              refreshExpiresIn: 3600,
              serverTime: DateTime.utc(2026, 10, 17),
            ),
            user: const UserProfile(
              id: 'u1',
              username: 'agente1',
              orgId: 'org1',
              roles: ['agent'],
            ),
          ),
        ),
      )
      ..refreshResponses.add(const AuthResult.err(AuthError.unauthorized()));
    final controller = AuthController(
      transport: transport,
      tokenStore: FakeTokenStore(),
      deviceId: 'device-1',
    );
    await controller.login(
      username: 'agente1',
      password: 'secret',
      deviceInfo: const DeviceInfo(
        deviceId: 'device-1',
        platform: 'android',
        appVersion: '0.3.0',
      ),
    );
    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: controller,
      deviceId: 'device-1',
      attachmentUploadService: AttachmentUploadService(
        db: db,
        transport: FakeAttachmentTransport(),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.runAsync(controller.refreshOnce);
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.textContaining('Tu sesión terminó'), findsOneWidget);
  });

  testWidgets(
    'Fase A: si la revocación llega antes de abrir el inicio, también vuelve al login',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final transport = FakeAuthTransport()
        ..refreshResponses.add(const AuthResult.err(AuthError.unauthorized()));
      final tokenStore = FakeTokenStore();
      await tokenStore.saveRefreshToken('device-1', 'r');
      final controller = AuthController(
        transport: transport,
        tokenStore: tokenStore,
        deviceId: 'device-1',
      );
      // Arranque con sesión restaurada cuyo refresh en segundo plano termina
      // con 401 antes de que la pantalla de inicio se suscriba a `changes`.
      await controller.refreshOnce();
      final dependencies = AppDependencies(
        database: db,
        dio: Dio(),
        authController: controller,
        deviceId: 'device-1',
        attachmentUploadService: AttachmentUploadService(
          db: db,
          transport: FakeAttachmentTransport(),
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
          child: testApp(const HomeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(LoginScreen), findsOneWidget);
    },
  );
}
