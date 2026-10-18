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
import 'package:visitacampo/core/location/coordinate_system.dart';
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

  Future<(AppDependencies, String)> scenario({required bool withTemplate, String author = 'user-1'}) async {
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
      identity: CaptureIdentity(orgId: 'org-1', userId: author, deviceId: 'device-1'),
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
    expect(find.text('lat 4.609700, lon -74.081700 (±4 m)'), findsOneWidget);
    expect(find.text('Altitud: 2640 m'), findsOneWidget);
    expect(find.text('Pendiente'), findsOneWidget, reason: 'aún no se sincroniza');
  });

  testWidgets('muestra la ubicación en el sistema elegido en Ajustes (Fase C)', (tester) async {
    final (dependencies, id) = await scenario(withTemplate: true);
    dependencies.coordinates.current.value = CoordinateSystem.magnaOrigenNacional;
    await pump(tester, dependencies, id);
    expect(find.text('E 4880061.56, N 2067458.02 (EPSG:9377) (±4 m)'), findsOneWidget);
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

  testWidgets('las propias se pueden eliminar, con confirmación', (tester) async {
    final (dependencies, id) = await scenario(withTemplate: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => VisitDetailScreen(visitId: id))),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('visit_edit')), findsOneWidget);

    await tester.tap(find.byKey(const Key('visit_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('visit_delete_confirm')));
    await tester.pumpAndSettle();

    expect(find.byType(VisitDetailScreen), findsNothing, reason: 'vuelve a la lista');
    final visit = await (db.select(db.visits)..where((t) => t.id.equals(id))).getSingle();
    expect(visit.deletedAt, isNotNull);
    final ops = await db.select(db.outboxOps).get();
    expect(ops.map((o) => o.opType), ['create', 'delete']);
  });

  testWidgets('las de otro agente no muestran editar ni eliminar', (tester) async {
    final (dependencies, id) = await scenario(withTemplate: true, author: 'user-2');
    await pump(tester, dependencies, id);
    expect(find.byKey(const Key('visit_edit')), findsNothing);
    expect(find.byKey(const Key('visit_delete')), findsNothing);
  });
}
