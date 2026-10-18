// Detalle de una visita (Fase A): etiquetas de la plantilla, opciones con su
// texto, ubicación con precisión, y sin plantilla en caché, las claves.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/auth/auth_models.dart';
import 'package:visitacampo/core/auth/auth_result.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/visits/visit_detail_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../support/test_app.dart';

const _definitionJson = {
  'fields': [
    {
      'key': 'estado',
      'type': 'single_choice',
      'label': {'es': 'Estado de la planta'},
      'options': [
        {
          'value': 'sana',
          'label': {'es': 'Sana'},
        },
        {
          'value': 'enferma',
          'label': {'es': 'Enferma'},
        },
      ],
    },
    {
      'key': 'tiene_riego',
      'type': 'boolean',
      'label': {'es': '¿Tiene riego?'},
    },
  ],
};

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<(AppDependencies, String)> scenario({required bool withTemplate}) async {
    final auth = AuthController(
      transport: FakeAuthTransport()
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
        ),
      tokenStore: FakeTokenStore(),
      deviceId: 'device-1',
    );
    await auth.login(
      username: 'agente1',
      password: 'x',
      deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
    );
    final dependencies = AppDependencies(database: db, dio: Dio(), authController: auth, deviceId: 'device-1');
    if (withTemplate) {
      await dependencies.formTemplates.upsertFromServerRow({
        'id': 'tv-1',
        'org_id': 'org-1',
        'version': 1,
        'change_seq': 1,
        'deleted_at': null,
        'template_id': 'tpl-1',
        'name': 'Inspección',
        'version_number': 1,
        'published_at': '2026-10-01T00:00:00Z',
        'definition': _definitionJson,
      });
    }
    final id = await VisitCapture(db: db).save(
      identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: (parseFormDefinition(_definitionJson) as DefinitionOk).definition,
      answers: {'estado': 'enferma', 'tiene_riego': true},
      captured: const {},
      fix: const LocationFix(lat: 4.6097, lon: -74.0817, accuracyM: 4.4, altitudeM: 2640),
    );
    return (dependencies, id);
  }

  Future<void> pump(WidgetTester tester, AppDependencies dependencies, String id) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(VisitDetailScreen(visitId: id)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('muestra las respuestas con las etiquetas y opciones de la plantilla', (tester) async {
    final (dependencies, id) = await scenario(withTemplate: true);
    await pump(tester, dependencies, id);

    expect(find.text('Inspección'), findsOneWidget, reason: 'título: la plantilla');
    expect(find.text('Estado de la planta'), findsOneWidget);
    expect(find.text('Enferma'), findsOneWidget, reason: 'la etiqueta, no el valor `enferma`');
    expect(find.text('¿Tiene riego?'), findsOneWidget);
    expect(find.text('Sí'), findsOneWidget);
    expect(find.text('lat: 4.609700, lon: -74.081700 (±4 m)'), findsOneWidget);
    expect(find.text('Altitud: 2640 m'), findsOneWidget);
    expect(find.text('Pendiente'), findsOneWidget, reason: 'aún no se sincroniza');
  });

  testWidgets('sin la plantilla en caché muestra las claves, no una pantalla vacía', (tester) async {
    final (dependencies, id) = await scenario(withTemplate: false);
    await pump(tester, dependencies, id);

    expect(find.text('estado'), findsOneWidget);
    expect(find.text('enferma'), findsOneWidget);
  });

  testWidgets('una visita que ya no está lo dice', (tester) async {
    final (dependencies, _) = await scenario(withTemplate: true);
    await pump(tester, dependencies, 'no-existe');
    expect(find.byKey(const Key('visit_not_found')), findsOneWidget);
  });
}
