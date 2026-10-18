// Hoja de ubicación (Fase A): el agente ve la precisión en vivo, puede usar
// una lectura antes de tiempo con aviso, y sin permiso se le dice qué hacer.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/location/gps_sampler.dart';
import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/features/capture/location_capture_sheet.dart';

import '../../support/test_app.dart';

class _Gnss implements LocationSource {
  _Gnss({this.status = LocationStatus.ready});

  LocationStatus status;
  final controller = StreamController<LocationFix>.broadcast();

  Future<void> close() => controller.close();
  final opened = <LocationStatus>[];

  @override
  Future<LocationStatus> ensureReady() async => status;

  @override
  Stream<LocationFix> watch() => controller.stream;

  @override
  Future<void> openSettings(LocationStatus status) async => opened.add(status);
}

const _policy = GpsPolicy(targetAccuracyM: 10, samples: 2, timeout: Duration(seconds: 30));

void main() {
  late LocationFix? result;
  late bool closed;
  late _Gnss gnss;

  tearDown(() => gnss.close());

  Future<void> open(WidgetTester tester, LocationSource source) async {
    closed = false;
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showLocationCaptureSheet(context, source: source, policy: _policy);
              closed = true;
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pump();
    // Fin de la animación de entrada (no `pumpAndSettle`: el indicador de
    // "buscando señal" no se detiene).
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('muestra la precisión en vivo y se cierra sola al llegar al objetivo', (tester) async {
    gnss = _Gnss();
    await open(tester, gnss);
    expect(find.byKey(const Key('gps_searching')), findsOneWidget);

    gnss.controller.add(const LocationFix(lat: 4.6, lon: -74, accuracyM: 30));
    await tester.pump();
    expect(find.text('±30 m'), findsOneWidget);
    expect(find.byKey(const Key('gps_low_accuracy')), findsOneWidget);

    gnss.controller
      ..add(const LocationFix(lat: 4.6, lon: -74, accuracyM: 6))
      ..add(const LocationFix(lat: 4.8, lon: -74, accuracyM: 4));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(result!.lat, closeTo(4.7, 1e-9));
    expect(result!.accuracyM, closeTo(5, 1e-9));
  });

  testWidgets('"Usar esta ubicación" toma lo que haya antes del objetivo', (tester) async {
    gnss = _Gnss();
    await open(tester, gnss);
    gnss.controller.add(const LocationFix(lat: 4.6, lon: -74, accuracyM: 30));
    await tester.pump();

    await tester.tap(find.byKey(const Key('gps_use')));
    await tester.pumpAndSettle();
    expect(result!.accuracyM, 30);
  });

  testWidgets('una posición simulada no se acepta sola: el agente decide', (tester) async {
    gnss = _Gnss();
    await open(tester, gnss);
    gnss.controller
      ..add(const LocationFix(lat: 4.6, lon: -74, accuracyM: 3, isMocked: true))
      ..add(const LocationFix(lat: 4.6, lon: -74, accuracyM: 3, isMocked: true));
    await tester.pumpAndSettle();

    expect(closed, isFalse);
    expect(find.byKey(const Key('gps_mocked')), findsOneWidget);
  });

  testWidgets('con el permiso bloqueado ofrece abrir los ajustes de la app', (tester) async {
    gnss = _Gnss(status: LocationStatus.permissionDeniedForever);
    await open(tester, gnss);
    expect(find.byKey(const Key('gps_not_ready')), findsOneWidget);

    await tester.tap(find.byKey(const Key('gps_open_settings')));
    await tester.pump();
    expect(gnss.opened, [LocationStatus.permissionDeniedForever]);

    // Lo activó y vuelve: "Reintentar" empieza a muestrear.
    gnss.status = LocationStatus.ready;
    await tester.tap(find.byKey(const Key('gps_retry')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('gps_searching')), findsOneWidget);

    await tester.tap(find.byKey(const Key('gps_cancel')));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
