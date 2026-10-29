// Mapa (Fase B): visitas y asignaciones como puntos, y tocar uno lleva a la
// visita o a iniciar la asignación. Sin red ni teselas.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/auth/auth_models.dart';
import 'package:visitacampo/core/auth/auth_result.dart';
import 'package:visitacampo/core/basemaps/basemap_manager.dart';
import 'package:visitacampo/core/layers/layer_manager.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/capture/capture_screen.dart';
import 'package:visitacampo/features/assignments/assignment_navigation_screen.dart';
import 'package:visitacampo/features/assignments/assignments_screen.dart';
import 'package:visitacampo/features/map/map_screen.dart';
import 'package:visitacampo/features/visits/visit_detail_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/basemaps/fake_basemap_transport.dart';
import '../../core/layers/fake_layer_transport.dart';
import '../../support/test_app.dart';

class _Gps implements LocationSource {
  _Gps(this.status);
  final LocationStatus status;
  final controller = StreamController<LocationFix>.broadcast();
  int checks = 0;

  Future<void> close() => controller.close();

  @override
  Future<LocationStatus> ensureReady() async {
    checks++;
    return status;
  }

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

  Future<(AppDependencies, String)> scenario({
    LocationStatus gpsStatus = LocationStatus.serviceDisabled,
    BasemapManager? basemaps,
    LayerManager? layers,
  }) async {
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
      basemaps: basemaps,
      layers: layers,
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

  testWidgets('desde el mapa se orienta a la asignación y al volver recupera el GPS', (tester) async {
    final (dependencies, _) = await scenario(gpsStatus: LocationStatus.ready);
    await pump(tester, dependencies);
    await tester.tap(find.byKey(const ValueKey('map-assignment-asg-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map_navigate')));
    // La cancelación del stream creado en scenario corre fuera del reloj simulado.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byType(AssignmentNavigationScreen), findsOneWidget);
    gps.controller.add(const LocationFix(lat: 4.60, lon: -74.07, accuracyM: 3));
    await tester.pumpAndSettle();
    expect(find.text('Rumbo 0° desde el norte'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(MapScreen), findsOneWidget);
    expect(gps.controller.hasListener, isTrue);
  });

  testWidgets('sin permiso, volver de la navegación no vuelve a pedirlo desde el mapa', (tester) async {
    final (dependencies, _) = await scenario(gpsStatus: LocationStatus.permissionDenied);
    await pump(tester, dependencies);
    await tester.tap(find.byKey(const ValueKey('map-assignment-asg-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map_navigate')));
    await tester.pumpAndSettle();
    expect(find.byType(AssignmentNavigationScreen), findsOneWidget);
    final checksBeforeBack = gps.checks;
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(MapScreen), findsOneWidget);
    expect(gps.checks, checksBeforeBack);
  });

  testWidgets('lista: solo ofrece navegar con un punto; mantiene el acceso a captura', (tester) async {
    final (dependencies, _) = await scenario();
    await db.into(db.assignments).insert(
      AssignmentsCompanion.insert(
        id: 'no-point', orgId: 'org-1', version: 1,
        templateVersionId: 'tv-1', assignedTo: 'user-1', title: const Value('Sin punto'),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const AssignmentsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('navigate-no-point')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('navigate-asg-1')));
    await tester.pumpAndSettle();
    expect(find.byType(AssignmentNavigationScreen), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Finca El Roble'));
    await tester.pumpAndSettle();
    expect(find.byType(CaptureScreen), findsOneWidget);
  });

  testWidgets('con un mapa base descargado, se dibuja como capa y lo nombra el aviso', (tester) async {
    final dir = Directory.systemTemp.createTempSync('map-basemap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final transport = FakeBasemapTransport();
    final manager = BasemapManager(transport: transport, directory: dir);
    // Un MBTiles mínimo, descargado y verificado como en la app.
    final source = '${dir.path}/src.mbtiles';
    sqlite3.open(source)
      ..execute('CREATE TABLE metadata (name TEXT, value TEXT)')
      ..execute('CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)')
      ..close();
    final bytes = File(source).readAsBytesSync();
    final roble = info('roble', bytes);
    transport
      ..offered = [roble]
      ..contents['roble'] = bytes;
    await tester.runAsync(() => manager.download(roble));

    final (dependencies, _) = await scenario(basemaps: manager);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const MapScreen()),
      ),
    );
    for (var i = 0; i < 50 && find.byKey(const ValueKey('map-basemap-roble')).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byKey(const ValueKey('map-basemap-roble')), findsOneWidget);
    expect(find.text('Mapa base: Mapa roble'), findsOneWidget);
  });

  testWidgets('las capas de referencia se dibujan y tocar un punto muestra sus atributos (Fase C)', (tester) async {
    final dir = Directory.systemTemp.createTempSync('map-layers');
    addTearDown(() => dir.deleteSync(recursive: true));
    final transport = FakeLayerTransport();
    final bytes = geoJsonBytes();
    transport
      ..offered = [layerInfo('predios', bytes)]
      ..contents['predios'] = bytes;
    final manager = LayerManager(transport: transport, directory: dir);
    await tester.runAsync(manager.syncAll);

    final (dependencies, _) = await scenario(layers: manager);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const MapScreen()),
      ),
    );
    // La capa se lee en otro isolate: se deja correr de verdad.
    final pin = find.bySemanticsLabel('Capa predios');
    for (var i = 0; i < 100 && pin.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(pin, findsOneWidget, reason: 'el punto de la capa');

    // El punto de prueba cae bajo el marcador de una visita (las visitas van
    // encima a propósito): se toca el marcador de la capa directamente.
    tester.widget<InkResponse>(find.descendant(of: pin, matching: find.byType(InkResponse))).onTap!();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('map_feature_sheet')), findsOneWidget);
  });
}
