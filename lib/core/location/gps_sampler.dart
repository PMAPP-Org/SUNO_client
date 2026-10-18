// `GpsSampler` — cuándo una posición es lo bastante buena (Fase A).
//
// Antes se guardaba la primera lectura que daba el sistema: en campo, recién
// encendido el GPS, esa lectura puede tener ±80 m (o venir de la red celular)
// y quedar como evidencia de la visita. Ahora:
// - se descartan para el promedio las lecturas peores que
//   [GpsPolicy.targetAccuracyM];
// - con [GpsPolicy.samples] lecturas buenas se promedian y se termina;
// - si pasa [GpsPolicy.timeout] sin llegar, se para y queda la mejor lectura,
//   marcada como de baja precisión: el agente decide si la usa (bajo techo o
//   en un cañón no siempre se consigue más).
//
// La precisión que se informa del promedio es la media de las precisiones
// usadas, no `media / √n`: los errores del GPS están correlacionados en el
// tiempo y el valor optimista engañaría a quien revisa la visita.
import 'dart:async';

import 'location_source.dart';

class GpsPolicy {
  const GpsPolicy({
    this.targetAccuracyM = 10,
    this.samples = 5,
    this.timeout = const Duration(seconds: 60),
  }) : assert(targetAccuracyM > 0),
       assert(samples > 0);

  /// Precisión (m) a partir de la cual una lectura cuenta para el promedio.
  final double targetAccuracyM;

  /// Lecturas buenas que se promedian.
  final int samples;

  /// Tiempo máximo buscando señal.
  final Duration timeout;
}

/// Estado del muestreo, una vez por lectura (y al terminar).
class GpsReading {
  const GpsReading({
    required this.fix,
    required this.goodSamples,
    required this.totalSamples,
    required this.policy,
    required this.done,
    required this.timedOut,
  });

  /// Posición a usar ahora: el promedio de las buenas o, si aún no hay
  /// ninguna buena, la mejor lectura. `null` sin lecturas todavía.
  final LocationFix? fix;
  final int goodSamples;
  final int totalSamples;
  final GpsPolicy policy;

  /// Terminó: por llegar a [GpsPolicy.samples] o por [timedOut].
  final bool done;
  final bool timedOut;

  bool get meetsTarget => goodSamples > 0;
  bool get isMocked => fix?.isMocked ?? false;
}

class GpsSampler {
  GpsSampler(this.policy);

  final GpsPolicy policy;

  /// Muestrea [source] hasta terminar. El flujo cierra tras el evento con
  /// `done`; cancelar la suscripción apaga el GPS.
  Stream<GpsReading> sample(LocationSource source) {
    late StreamController<GpsReading> controller;
    StreamSubscription<LocationFix>? subscription;
    Timer? timer;
    final good = <LocationFix>[];
    LocationFix? best;
    var total = 0;
    var mocked = false;

    GpsReading reading({required bool done, bool timedOut = false}) {
      final average = _average(good, mocked: mocked);
      return GpsReading(
        fix: average ?? best,
        goodSamples: good.length,
        totalSamples: total,
        policy: policy,
        done: done,
        timedOut: timedOut,
      );
    }

    var finished = false;
    Future<void> finish(GpsReading last) async {
      // Objetivo, tiempo, error y fin del flujo pueden coincidir: un solo
      // evento final.
      if (finished) return;
      finished = true;
      timer?.cancel();
      final pending = subscription;
      subscription = null;
      controller.add(last);
      await pending?.cancel();
      await controller.close();
    }

    controller = StreamController<GpsReading>(
      onListen: () {
        timer = Timer(policy.timeout, () => unawaited(finish(reading(done: true, timedOut: true))));
        subscription = source.watch().listen(
          (fix) {
            total++;
            // Una sola lectura simulada contamina el resultado entero.
            mocked = mocked || fix.isMocked;
            if (best == null || fix.accuracyM < best!.accuracyM) best = fix;
            if (fix.accuracyM <= policy.targetAccuracyM) good.add(fix);
            if (good.length >= policy.samples) {
              unawaited(finish(reading(done: true)));
            } else {
              controller.add(reading(done: false));
            }
          },
          onError: (Object error, StackTrace stack) {
            // Un error de plataforma no deja la hoja colgada: se termina con
            // lo que haya.
            unawaited(finish(reading(done: true, timedOut: true)));
          },
          onDone: () => unawaited(finish(reading(done: true, timedOut: true))),
        );
      },
      onCancel: () async {
        timer?.cancel();
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  static LocationFix? _average(List<LocationFix> fixes, {required bool mocked}) {
    if (fixes.isEmpty) return null;
    double mean(double Function(LocationFix) of) =>
        fixes.map(of).reduce((a, b) => a + b) / fixes.length;
    final altitudes = [for (final f in fixes) ?f.altitudeM];
    return LocationFix(
      lat: mean((f) => f.lat),
      lon: mean((f) => f.lon),
      accuracyM: mean((f) => f.accuracyM),
      altitudeM: altitudes.isEmpty ? null : altitudes.reduce((a, b) => a + b) / altitudes.length,
      isMocked: mocked,
    );
  }
}
