// Trazar en el mapa (Fase C): tocando el mapa o con la posición GPS; no se
// puede guardar sin los vértices mínimos; deshacer quita el último.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/forms/geometry.dart';
import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/capture/geometry_capture_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../support/test_app.dart';

class _Gps implements LocationSource {
  final controller = StreamController<LocationFix>.broadcast();

  Future<void> close() => controller.close();

  @override
  Future<LocationStatus> ensureReady() async => LocationStatus.ready;

  @override
  Stream<LocationFix> watch() => controller.stream;

  @override
  Future<void> openSettings(LocationStatus status) async {}
}

void main() {
  late AppDatabase db;
  late _Gps gps;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    gps = _Gps();
  });
  tearDown(() async {
    await db.close();
    await gps.close();
  });

  /// Abre la pantalla y devuelve una función que lee lo que devolvió al cerrar.
  Future<Map<String, Object?>? Function()> open(
    WidgetTester tester,
    GeometryKind kind, {
    List<Vertex> initial = const [],
  }) async {
    Map<String, Object?>? result;
    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: AuthController(transport: FakeAuthTransport(), tokenStore: FakeTokenStore(), deviceId: 'd'),
      deviceId: 'd',
      locationSource: gps,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await Navigator.of(context).push<Map<String, Object?>>(
                  MaterialPageRoute(builder: (_) => GeometryCaptureScreen(kind: kind, title: 'Lote', initial: initial)),
                );
              },
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    return () => result;
  }

  Future<void> tapMap(WidgetTester tester, Offset offset) async {
    final center = tester.getCenter(find.byType(FlutterMap));
    await tester.tapAt(center + offset);
    await tester.pumpAndSettle();
  }

  testWidgets('tocar el mapa marca vértices; con 3 se guarda un polígono válido', (tester) async {
    final result = await open(tester, GeometryKind.polygon);
    final save = find.byKey(const Key('geometry_save'));
    expect(tester.widget<TextButton>(save).onPressed, isNull, reason: 'sin vértices no se guarda');

    await tapMap(tester, const Offset(-40, -40));
    await tapMap(tester, const Offset(40, -40));
    expect(tester.widget<TextButton>(save).onPressed, isNull, reason: '2 vértices no hacen un polígono');
    await tapMap(tester, const Offset(0, 40));
    expect(find.textContaining('3 vértices'), findsOneWidget);

    await tester.tap(save);
    await tester.pumpAndSettle();
    const field = PolygonFieldDef(
      key: 'lote',
      label: I18nText({'es': 'Lote'}),
      help: null,
      required: false,
      visibleIf: null,
    );
    expect(field.checkAnswer(result()), isNull);
  });

  testWidgets('con el GPS se agrega la posición actual y deshacer la quita', (tester) async {
    await open(tester, GeometryKind.line);
    final add = find.byKey(const Key('geometry_add_position'));
    expect(tester.widget<FilledButton>(add).onPressed, isNull, reason: 'sin señal aún');

    gps.controller.add(const LocationFix(lat: 4.6, lon: -74.08, accuracyM: 3));
    await tester.pumpAndSettle();
    await tester.tap(add);
    gps.controller.add(const LocationFix(lat: 4.601, lon: -74.08, accuracyM: 3));
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    expect(find.textContaining('2 vértices · 111 m'), findsOneWidget);

    await tester.tap(find.byKey(const Key('geometry_undo')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 vértice'), findsOneWidget);
  });

  testWidgets('parte de lo ya trazado y lo devuelve como GeoJSON válido', (tester) async {
    final result = await open(
      tester,
      GeometryKind.line,
      initial: const [Vertex(4.6, -74.08), Vertex(4.601, -74.079)],
    );
    await tester.tap(find.byKey(const Key('geometry_save')));
    await tester.pumpAndSettle();

    const field = LineFieldDef(key: 'cerca', label: I18nText({'es': 'Cerca'}), help: null, required: false, visibleIf: null);
    expect(field.checkAnswer(result()), isNull);
    expect(verticesOf(result()), hasLength(2));
  });
}
