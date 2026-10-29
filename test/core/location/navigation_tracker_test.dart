import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/core/location/navigation_tracker.dart';

import '../../support/fake_navigation.dart';

void main() {
  late FakeNavigationGps gps;
  late NavigationTracker tracker;
  const fix = LocationFix(lat: 4.6, lon: -74.08, accuracyM: 3);

  setUp(() {
    gps = FakeNavigationGps();
    tracker = NavigationTracker(gps);
  });
  tearDown(() async {
    tracker.dispose();
    await gps.controller.close();
  });

  testWidgets('sin señal caduca la posición; una nueva lectura recupera el rumbo', (tester) async {
    await tracker.start();
    await tester.pump(NavigationTracker.signalTimeout);
    expect(tracker.status, NavigationStatus.noSignal);
    gps.controller.add(fix);
    await tester.pump();
    expect(tracker.fix, fix);
    expect(tracker.status, NavigationStatus.tracking);
    await tester.pump(NavigationTracker.signalTimeout);
    expect(tracker.fix, isNull);
    expect(tracker.status, NavigationStatus.noSignal);
    gps.controller.add(fix);
    await tester.pump();
    expect(tracker.fix, fix);
    tracker.stop();
    expect(gps.controller.hasListener, isFalse);
    expect(tracker.fix, isNull);
  });

  testWidgets('lecturas inválidas no mantienen viva una posición antigua', (tester) async {
    await tracker.start();
    gps.controller.add(fix);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    for (final invalid in [
      const LocationFix(lat: double.nan, lon: 0, accuracyM: 3),
      const LocationFix(lat: 4, lon: 181, accuracyM: 3),
      const LocationFix(lat: 4, lon: 0, accuracyM: -1),
      const LocationFix(lat: 4, lon: 0, accuracyM: double.infinity),
    ]) {
      gps.controller.add(invalid);
    }
    await tester.pump(const Duration(seconds: 10));
    expect(tracker.fix, isNull);
    expect(tracker.status, NavigationStatus.noSignal);
  });

  test('errores al solicitar GPS, en el stream y su cierre permiten reintentar', () async {
    gps.failReadiness = true;
    await tracker.start();
    expect(tracker.status, NavigationStatus.noSignal);
    gps.failReadiness = false;
    await tracker.start();
    gps.controller.add(fix);
    await Future<void>.delayed(Duration.zero);
    gps.controller.addError(StateError('GPS disabled'));
    await Future<void>.delayed(Duration.zero);
    expect(tracker.fix, isNull);
    expect(gps.controller.hasListener, isFalse);
    await tracker.start();
    gps.controller.add(fix);
    await Future<void>.delayed(Duration.zero);
    expect(tracker.fix, fix);
    final closing = gps.controller.close();
    await Future<void>.delayed(Duration.zero);
    await closing;
    expect(tracker.status, NavigationStatus.noSignal);
    expect(tracker.fix, isNull);
  });

  test('apagar el GPS durante la sesión se informa como servicio apagado, no como falta de señal', () async {
    await tracker.start();
    gps.controller.add(fix);
    await Future<void>.delayed(Duration.zero);
    gps.controller.addError(const LocationServiceDisabledError());
    await Future<void>.delayed(Duration.zero);
    expect(tracker.status, NavigationStatus.serviceDisabled);
    expect(tracker.fix, isNull);
    expect(gps.controller.hasListener, isFalse);
  });

  testWidgets('un permiso que termina después de salir no vuelve a encender el GPS', (tester) async {
    final permission = Completer<LocationStatus>();
    gps.pendingPermission = permission.future;
    final starting = tracker.start();
    await tester.pump();
    tracker.stop();
    permission.complete(LocationStatus.ready);
    await starting;
    expect(gps.controller.hasListener, isFalse);
  });

  testWidgets('reintentos solapados solo conservan la solicitud más reciente', (tester) async {
    final permission = Completer<LocationStatus>();
    gps.pendingPermission = permission.future;
    final first = tracker.start();
    await tester.pump();
    gps.pendingPermission = null;
    gps.status = LocationStatus.permissionDenied;
    await tracker.start();
    permission.complete(LocationStatus.ready);
    await first;
    expect(tracker.status, NavigationStatus.permissionDenied);
    expect(gps.controller.hasListener, isFalse);
  });
}
