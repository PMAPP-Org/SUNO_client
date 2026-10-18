// Aviso de privacidad (Ley 1581): autorización expresa por finalidad antes del
// login. "Acepto y continúo" no se puede pulsar hasta marcar las tres.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/privacy/consent.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/auth/login_screen.dart';
import 'package:visitacampo/features/privacy/privacy_notice_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/privacy/consent_service_test.dart' show FakeConsentTransport;
import '../../support/test_app.dart';

ConsentService _consent() => ConsentService(
  store: const ConsentStore(FlutterSecureStorage()),
  transport: FakeConsentTransport(),
  accessTokenProvider: () => '',
  deviceId: 'device-1',
);

Future<void> _pump(WidgetTester tester) async {
  final dependencies = AppDependencies(
    database: AppDatabase.forTesting(NativeDatabase.memory()),
    dio: Dio(),
    authController: AuthController(
      transport: FakeAuthTransport(),
      tokenStore: FakeTokenStore(),
      deviceId: 'device-1',
    ),
    deviceId: 'device-1',
    consent: _consent(),
  );
  addTearDown(dependencies.database.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
      child: testApp(const PrivacyNoticeScreen()),
    ),
  );
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  ElevatedButton acceptButton(WidgetTester tester) =>
      tester.widget<ElevatedButton>(
        find.descendant(
          of: find.byKey(const Key('privacy_accept_button')),
          matching: find.byType(ElevatedButton),
        ),
      );

  testWidgets('"Acepto y continúo" solo se habilita con las tres finalidades', (
    tester,
  ) async {
    await _pump(tester);
    expect(acceptButton(tester).onPressed, isNull);

    await _tapVisible(tester, find.byKey(const Key('privacy_account')));
    await _tapVisible(tester, find.byKey(const Key('privacy_location')));
    expect(acceptButton(tester).onPressed, isNull, reason: 'falta una');

    await _tapVisible(tester, find.byKey(const Key('privacy_photos')));
    expect(acceptButton(tester).onPressed, isNotNull);
  });

  testWidgets(
    'aceptar guarda la autorización de esta versión y pasa al login',
    (tester) async {
      await _pump(tester);
      for (final purpose in PrivacyPurpose.values) {
        await _tapVisible(tester, find.byKey(Key('privacy_${purpose.name}')));
      }
      await _tapVisible(tester, find.byKey(const Key('privacy_accept_button')));

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(await _consent().isAcceptedForCurrentVersion(), isTrue);
    },
  );

  testWidgets('no aceptar explica por qué y se queda en el aviso', (
    tester,
  ) async {
    await _pump(tester);
    await _tapVisible(tester, find.byKey(const Key('privacy_decline_button')));

    expect(find.byType(PrivacyNoticeScreen), findsOneWidget);
    expect(
      find.textContaining('no se puede usar la aplicación'),
      findsOneWidget,
    );
    expect(await _consent().isAcceptedForCurrentVersion(), isFalse);
  });

  testWidgets('muestra la versión del aviso', (tester) async {
    await _pump(tester);
    expect(
      find.textContaining(kPrivacyNoticeVersion, skipOffstage: false),
      findsOneWidget,
    );
  });
}
