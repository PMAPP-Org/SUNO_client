import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/location/coordinate_system.dart';
import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/core/location/navigation_target.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/assignments/assignment_navigation_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../support/fake_navigation.dart';
import '../../support/test_app.dart';

void main() {
  late AppDatabase db;
  late AppDependencies dependencies;
  late FakeNavigationGps gps;
  late FakeRouteLauncher launcher;
  final target = NavigationTarget.tryCreate(4.61, -74.08)!;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    gps = FakeNavigationGps();
    launcher = FakeRouteLauncher();
    dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: AuthController(
        transport: FakeAuthTransport(),
        tokenStore: FakeTokenStore(),
        deviceId: 'device-1',
      ),
      deviceId: 'device-1',
      locationSource: gps,
      routeLauncher: launcher,
    );
  });
  tearDown(() async {
    await gps.controller.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(AssignmentNavigationScreen(target: target, title: 'Finca El Roble')),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final button = find.byKey(Key(key));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('GPS actualiza distancia y rumbo sin red; al llegar no inventa una dirección', (tester) async {
    await pump(tester);
    expect(launcher.opened, isEmpty, reason: 'abrir la pantalla no comparte el destino');
    gps.controller.add(const LocationFix(lat: 4.60, lon: -74.08, accuracyM: 3));
    await tester.pumpAndSettle();
    expect(find.text('1112 m en línea recta'), findsOneWidget);
    expect(find.text('Rumbo 0° desde el norte'), findsOneWidget);
    gps.controller.add(const LocationFix(lat: 4.61, lon: -74.08, accuracyM: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation_bearing')), findsNothing);
    expect(find.byKey(const Key('navigation_near')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(gps.controller.hasListener, isFalse, reason: 'salir apaga el GPS');
    expect(await db.select(db.visits).get(), isEmpty, reason: 'orientarse no crea ni cumple una visita');
  });

  testWidgets('señala precisión baja y GPS simulado; no muestra datos caducados', (tester) async {
    await pump(tester);
    gps.controller.add(const LocationFix(lat: 4.60, lon: -74.08, accuracyM: 100, isMocked: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation_low_accuracy')), findsOneWidget);
    expect(find.byKey(const Key('navigation_mocked')), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    expect(find.byKey(const Key('navigation_distance')), findsNothing);
    expect(find.byKey(const Key('navigation_retry')), findsOneWidget);
  });

  for (final status in [LocationStatus.serviceDisabled, LocationStatus.permissionDeniedForever]) {
    testWidgets('$status: abre ajustes, informa fallos y reintenta', (tester) async {
      gps.status = status;
      await pump(tester);
      await tap(tester, 'navigation_settings');
      expect(gps.settingsOpened, status);
      gps.failSettings = true;
      await tap(tester, 'navigation_settings');
      expect(find.textContaining('No se pudieron abrir los ajustes'), findsOneWidget);
      gps.status = LocationStatus.ready;
      await tap(tester, 'navigation_retry');
      expect(gps.controller.hasListener, isTrue);
    });
  }

  testWidgets('sin permiso se puede abrir ruta; usa WGS84 aunque se vea otro CRS', (tester) async {
    gps.status = LocationStatus.permissionDenied;
    dependencies.coordinates.current.value = CoordinateSystem.magnaOrigenNacional;
    await pump(tester);
    expect(find.byKey(const Key('navigation_settings')), findsNothing);
    expect(gps.controller.hasListener, isFalse);
    expect(find.text(dependencies.coordinates.current.value.format(target.lat, target.lon)), findsOneWidget);
    await tap(tester, 'navigation_external');
    expect(launcher.opened.single.directionsUri.queryParameters['destination'], '4.61,-74.08');
    gps.status = LocationStatus.ready;
    await tap(tester, 'navigation_retry');
    expect(gps.controller.hasListener, isTrue);
  });

  testWidgets('fallo externo se recupera y no permite aperturas duplicadas', (tester) async {
    await pump(tester);
    launcher.result = false;
    await tap(tester, 'navigation_external');
    expect(find.byKey(const Key('navigation_launch_failed')), findsOneWidget);
    launcher.throws = true;
    await tap(tester, 'navigation_external');
    expect(find.byKey(const Key('navigation_launch_failed')), findsOneWidget);
    launcher.throws = false;
    launcher.pending = Completer<bool>();
    await tap(tester, 'navigation_external');
    final button = tester.widget<FilledButton>(find.byKey(const Key('navigation_external')));
    expect(button.onPressed, isNull);
    launcher.pending!.complete(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation_launch_failed')), findsNothing);
  });

  testWidgets('en segundo plano apaga GPS y al volver exige una lectura nueva', (tester) async {
    await pump(tester);
    gps.controller.add(const LocationFix(lat: 4.60, lon: -74.08, accuracyM: 3));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(gps.controller.hasListener, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(gps.controller.hasListener, isTrue);
    expect(find.byKey(const Key('navigation_distance')), findsNothing);
    gps.controller.add(const LocationFix(lat: 4.60, lon: -74.08, accuracyM: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('navigation_distance')), findsOneWidget);
  });

  testWidgets('pantalla pequeña con letra grande permite acceder a la ruta sin desbordar', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pump(tester);
    gps.controller.add(const LocationFix(lat: 4.60, lon: -74.08, accuracyM: 3));
    await tester.pumpAndSettle();
    await tap(tester, 'navigation_external');
    expect(launcher.opened, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
