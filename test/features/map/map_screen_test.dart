// Mapa (Fase B): visitas y asignaciones como puntos, y tocar uno lleva a la
// visita o a iniciar la asignación. Sin red ni teselas.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
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
import 'package:visitacampo/features/capture/capture_screen.dart';
import 'package:visitacampo/features/map/map_screen.dart';
import 'package:visitacampo/features/visits/visit_detail_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../support/test_app.dart';

class _Gps implements LocationSource {
  _Gps(this.status);
  final LocationStatus status;
  final controller = StreamController<LocationFix>.broadcast();

  Future<void> close() => controller.close();

  @override
  Future<LocationStatus> ensureReady() async => status;

  @override
  Stream<LocationFix> watch() => controller.stream;

  @override
  Future<void> openSettings(LocationStatus status) async {}
}

void main() {
  late AppDatabase db;
  late _Gps gps;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() async {
    await db.close();
    await gps.close();
  });

  Future<(AppDependencies, String)> scenario({LocationStatus gpsStatus = LocationStatus.serviceDisabled}) async {
    gps = _Gps(gpsStatus);
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
    final visitId = await VisitCapture(db: db).save(
      identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: (parseFormDefinition({'fields': <Object>[]}) as DefinitionOk).definition,
      answers: const {},
      captured: const {},
      fix: const LocationFix(lat: 4.6, lon: -74.08, accuracyM: 3),
    );
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
            lat: const Value(4.61),
            lon: const Value(-74.07),
          ),
        );
    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: auth,
      deviceId: 'device-1',
      locationSource: gps,
    );
    return (dependencies, visitId);
  }

  Future<void> pump(WidgetTester tester, AppDependencies dependencies) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const MapScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('muestra visitas y asignaciones; tocar una visita la abre', (tester) async {
    final (dependencies, visitId) = await scenario();
    await pump(tester, dependencies);

    expect(find.byKey(ValueKey('map-visit-$visitId')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-assignment-asg-1')), findsOneWidget);
    expect(find.byKey(const Key('map_hint')), findsOneWidget, reason: 'sin mapa base, se avisa');
    expect(find.byKey(const Key('map_center_me')), findsNothing, reason: 'sin GPS no hay "centrar en mí"');

    await tester.tap(find.byKey(ValueKey('map-visit-$visitId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map_sheet_action')));
    await tester.pumpAndSettle();
    expect(find.byType(VisitDetailScreen), findsOneWidget);
  });

  testWidgets('tocar una asignación pendiente inicia su visita', (tester) async {
    final (dependencies, _) = await scenario();
    await pump(tester, dependencies);

    await tester.tap(find.byKey(const ValueKey('map-assignment-asg-1')));
    await tester.pumpAndSettle();
    expect(find.text('Finca El Roble'), findsOneWidget);
    await tester.tap(find.byKey(const Key('map_sheet_action')));
    await tester.pumpAndSettle();
    expect(find.byType(CaptureScreen), findsOneWidget);
  });

  testWidgets('con GPS, mi posición aparece y se puede centrar en ella', (tester) async {
    final (dependencies, _) = await scenario(gpsStatus: LocationStatus.ready);
    await pump(tester, dependencies);

    gps.controller.add(const LocationFix(lat: 4.605, lon: -74.075, accuracyM: 4));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('map-me')), findsOneWidget);
    await tester.tap(find.byKey(const Key('map_center_me')));
    await tester.pumpAndSettle();
  });
}
