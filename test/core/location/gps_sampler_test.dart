// Fase A, GPS fiable: precisión objetivo, promedio de lecturas buenas y un
// tiempo máximo que deja la mejor lectura marcada como de baja precisión.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/location/gps_sampler.dart';
import 'package:visitacampo/core/location/location_source.dart';

class _Gnss implements LocationSource {
  final _controller = StreamController<LocationFix>();
  var listening = false;

  void add(LocationFix fix) => _controller.add(fix);

  Future<void> close() => _controller.close();

  @override
  Future<LocationStatus> ensureReady() async => LocationStatus.ready;

  @override
  Stream<LocationFix> watch() {
    _controller
      ..onListen = (() => listening = true)
      ..onCancel = (() => listening = false);
    return _controller.stream;
  }

  @override
  Future<void> openSettings(LocationStatus status) async {}
}

LocationFix _fix(double lat, double accuracy, {double? altitude, bool mocked = false}) =>
    LocationFix(lat: lat, lon: -74, accuracyM: accuracy, altitudeM: altitude, isMocked: mocked);

void main() {
  // Tiempo máximo corto: los tests esperan de verdad, sin reloj simulado.
  const policy = GpsPolicy(targetAccuracyM: 10, samples: 3, timeout: Duration(milliseconds: 100));
  const pastTimeout = Duration(milliseconds: 200);

  late _Gnss gnss;
  late List<GpsReading> readings;

  setUp(() {
    gnss = _Gnss();
    readings = [];
  });
  tearDown(() => gnss.close());

  Future<StreamSubscription<GpsReading>> start() async {
    final subscription = GpsSampler(policy).sample(gnss).listen(readings.add);
    await pumpEventQueue();
    return subscription;
  }

  test('promedia solo las lecturas buenas y termina al llegar al número pedido', () async {
    await start();
    gnss
      ..add(_fix(4.0, 80)) // arranque en frío: no cuenta
      ..add(_fix(4.6, 8, altitude: 2600))
      ..add(_fix(4.8, 6, altitude: 2610))
      ..add(_fix(4.7, 4));
    await pumpEventQueue();

    final last = readings.last;
    expect(last.done, isTrue);
    expect(last.timedOut, isFalse);
    expect(last.goodSamples, 3);
    expect(last.totalSamples, 4);
    expect(last.fix!.lat, closeTo(4.7, 1e-9));
    expect(last.fix!.accuracyM, closeTo(6, 1e-9), reason: 'media, no media/√n');
    expect(last.fix!.altitudeM, closeTo(2605, 1e-9), reason: 'solo las que tienen altitud');
    expect(gnss.listening, isFalse, reason: 'al terminar se apaga el GPS');
  });

  test('mientras no hay lecturas buenas propone la mejor, sin darla por buena', () async {
    final subscription = await start();
    gnss
      ..add(_fix(4.0, 80))
      ..add(_fix(4.1, 25));
    await pumpEventQueue();

    expect(readings.last.fix!.accuracyM, 25);
    expect(readings.last.meetsTarget, isFalse);
    expect(readings.last.done, isFalse);
    await subscription.cancel();
  });

  test('al vencer el tiempo termina con lo mejor que hubo', () async {
    await start();
    gnss.add(_fix(4.1, 25));
    await Future<void>.delayed(pastTimeout);

    expect(readings.last.done, isTrue);
    expect(readings.last.timedOut, isTrue);
    expect(readings.last.fix!.accuracyM, 25);
    expect(gnss.listening, isFalse);
  });

  test('sin ninguna lectura, al vencer el tiempo no hay posición', () async {
    await start();
    await Future<void>.delayed(pastTimeout);

    expect(readings.single.done, isTrue);
    expect(readings.single.fix, isNull);
  });

  test('una sola lectura simulada marca el resultado', () async {
    await start();
    gnss
      ..add(_fix(4.6, 5, mocked: true))
      ..add(_fix(4.6, 5))
      ..add(_fix(4.6, 5));
    await pumpEventQueue();

    expect(readings.last.done, isTrue);
    expect(readings.last.isMocked, isTrue);
  });

  test('cancelar apaga el GPS', () async {
    final subscription = await start();
    expect(gnss.listening, isTrue);
    await subscription.cancel();
    expect(gnss.listening, isFalse);
  });
}
