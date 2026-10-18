// Ajustes (Fase A): cambiar el GPS y cerrar sesión avisando de lo pendiente.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/auth/auth_models.dart';
import 'package:visitacampo/core/auth/auth_result.dart';
import 'package:visitacampo/core/auth/auth_state.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/location/gps_settings.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/auth/login_screen.dart';
import 'package:visitacampo/features/settings/settings_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../support/test_app.dart';

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => db.close());

  Future<AppDependencies> loggedIn() async {
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
              serverTime: DateTime.utc(2026, 10, 18),
            ),
            user: const UserProfile(id: 'user-1', username: 'agente1', orgId: 'org-1', roles: ['agent']),
          ),
        ),
      );
    final auth = AuthController(transport: transport, tokenStore: FakeTokenStore(), deviceId: 'device-1');
    await auth.login(
      username: 'agente1',
      password: 'x',
      deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
    );
    return AppDependencies(
      database: db,
      dio: Dio(),
      authController: auth,
      deviceId: 'device-1',
      gpsSettings: GpsSettings(const FlutterSecureStorage()),
    );
  }

  Future<void> pump(WidgetTester tester, AppDependencies dependencies) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('muestra la cuenta y cambia la precisión del GPS', (tester) async {
    final dependencies = await loggedIn();
    await pump(tester, dependencies);
    expect(find.text('agente1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_gps_accuracy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('±20 m').last);
    await tester.pumpAndSettle();

    expect(dependencies.gpsPolicy.targetAccuracyM, 20);
  });

  testWidgets('cerrar sesión avisa de las visitas sin enviar y vuelve al login', (tester) async {
    final dependencies = await loggedIn();
    await VisitCapture(db: db).save(
      identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: (parseFormDefinition({'fields': <Object>[]}) as DefinitionOk).definition,
      answers: const {},
      captured: const {},
    );
    await pump(tester, dependencies);

    await tester.tap(find.byKey(const Key('settings_logout')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tienes 1 visita sin enviar'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings_logout_confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(dependencies.authController.state, isA<Unauthenticated>());
    expect(await db.select(db.outboxOps).get(), hasLength(1), reason: 'lo pendiente se queda');
  });
}
