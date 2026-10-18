// `LoginScreen` — Tarea 5 del plan de despliegue del demo. Reutiliza
// `FakeAuthTransport`/`FakeTokenStore` ya construidos para `AuthController`
// (Paso 13) en vez de levantar red real, mismo criterio que
// `test/core/auth/auth_controller_test.dart`.
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
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/core/security/certificate_info.dart';
import 'package:visitacampo/core/security/pin_store.dart';
import 'package:visitacampo/core/security/trust_store.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/auth/login_screen.dart';
import 'package:visitacampo/features/auth/trust_certificate_screen.dart';
import 'package:visitacampo/features/home/home_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';

import '../../support/test_app.dart';

TokenPair _tokenPair() => TokenPair(
  accessToken: 'access-1',
  tokenType: 'Bearer',
  expiresIn: 900,
  refreshToken: 'refresh-1',
  refreshExpiresIn: 5184000,
  serverTime: DateTime.utc(2026, 8, 6, 12),
);

const _user = UserProfile(id: 'u1', username: 'agente1', orgId: 'org1', roles: ['agent']);

AppDependencies _buildDependencies(FakeAuthTransport transport, {TrustStore? trustStore}) {
  final controller = AuthController(
    transport: transport,
    tokenStore: FakeTokenStore(),
    deviceId: 'device-1',
  );
  return AppDependencies(
    database: AppDatabase.forTesting(NativeDatabase.memory()),
    dio: Dio(),
    authController: controller,
    deviceId: 'device-1',
    trustStore: trustStore,
  );
}

final _selfHostedCertificate = CertificateInfo(
  spkiSha256: 'pin-del-servidor',
  sha256Fingerprint: 'AA:BB',
  subject: '/CN=campo.example',
  issuer: '/CN=campo.example',
  subjectAltNames: const ['campo.example'],
  notBefore: DateTime.utc(2026),
  notAfter: DateTime.utc(2099),
);

void main() {
  testWidgets('login exitoso navega a HomeScreen', (tester) async {
    final transport = FakeAuthTransport()
      ..loginResponses.add(AuthResult.ok(LoginResponse(tokens: _tokenPair(), user: _user)));
    final dependencies = _buildDependencies(transport);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const LoginScreen()),
      ),
    );

    await tester.enterText(find.byKey(const Key('login_username_field')), 'agente1');
    await tester.enterText(find.byKey(const Key('login_password_field')), 'secret');
    await tester.tap(find.byKey(const Key('login_submit_button')));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('login fallido muestra un mensaje y se queda en LoginScreen', (tester) async {
    final transport = FakeAuthTransport()
      ..loginResponses.add(const AuthResult.err(AuthError.invalidCredentials()));
    final dependencies = _buildDependencies(transport);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const LoginScreen()),
      ),
    );

    await tester.enterText(find.byKey(const Key('login_username_field')), 'agente1');
    await tester.enterText(find.byKey(const Key('login_password_field')), 'mal');
    await tester.tap(find.byKey(const Key('login_submit_button')));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('Usuario o contraseña incorrectos.'), findsOneWidget);
  });

  testWidgets('Paso 16: servidor autohospedado → diálogo TOFU, se guarda el pin y se reintenta', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final trustStore = TrustStore(pinStore: const PinStore(FlutterSecureStorage()));
    final transport = FakeAuthTransport()
      ..loginResponses.add(
        AuthResult.err(AuthError.certificate(UntrustedCertificate('campo.example', 443, _selfHostedCertificate))),
      )
      ..loginResponses.add(AuthResult.ok(LoginResponse(tokens: _tokenPair(), user: _user)));
    final dependencies = _buildDependencies(transport, trustStore: trustStore);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const LoginScreen()),
      ),
    );
    await tester.enterText(find.byKey(const Key('login_username_field')), 'agente1');
    await tester.enterText(find.byKey(const Key('login_password_field')), 'secret');
    await tester.tap(find.byKey(const Key('login_submit_button')));
    await tester.pumpAndSettle();

    expect(find.byType(TrustCertificateScreen), findsOneWidget);
    final trust = find.byKey(const Key('tofu_trust_button'));
    await tester.scrollUntilVisible(trust, 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('tofu_compared_check')));
    await tester.pumpAndSettle();
    await tester.tap(trust);
    await tester.pumpAndSettle();

    expect(trustStore.approvedPins['campo.example:443']?.spkiSha256, 'pin-del-servidor');
    expect(transport.loginCallCount, 2, reason: 'se reintenta el login tras aprobar');
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('Paso 16: si no se confía, no se guarda nada ni se reintenta', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final trustStore = TrustStore(pinStore: const PinStore(FlutterSecureStorage()));
    final transport = FakeAuthTransport()
      ..loginResponses.add(
        AuthResult.err(AuthError.certificate(UntrustedCertificate('campo.example', 443, _selfHostedCertificate))),
      );
    final dependencies = _buildDependencies(transport, trustStore: trustStore);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const LoginScreen()),
      ),
    );
    await tester.tap(find.byKey(const Key('login_submit_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    expect(trustStore.approvedPins, isEmpty);
    expect(transport.loginCallCount, 1);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('Paso 16: pin incorrecto del servidor oficial → mensaje, sin diálogo', (tester) async {
    final transport = FakeAuthTransport()
      ..loginResponses.add(
        AuthResult.err(AuthError.certificate(PinMismatch('api.example', 443, _selfHostedCertificate))),
      );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(_buildDependencies(transport))],
        child: testApp(const LoginScreen()),
      ),
    );
    await tester.tap(find.byKey(const Key('login_submit_button')));
    await tester.pumpAndSettle();

    expect(find.byType(TrustCertificateScreen), findsNothing);
    expect(find.textContaining('identidad del servidor no coincide'), findsOneWidget);
  });
}
