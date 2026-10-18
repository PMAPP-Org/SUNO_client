// Ajustes del GPS (Fase A): qué precisión se pide, cuántas lecturas se
// promedian y cuánto se espera. Cada proyecto tiene su terreno: bajo dosel o
// en ciudad, 10 m puede ser inalcanzable; en un levantamiento, poco.
//
// Se guardan en el almacenamiento seguro del sistema (como el resto de la
// configuración local) y solo admiten los valores de las listas de abajo: un
// valor guardado que no está en ellas (versión vieja, almacenamiento
// manipulado) vuelve al de fábrica en vez de dejar el GPS sin tiempo máximo.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'gps_sampler.dart';

/// Opciones que ofrece la pantalla de ajustes.
abstract final class GpsOptions {
  static const targetAccuracyM = <double>[3, 5, 10, 20, 50];
  static const samples = <int>[1, 3, 5, 10];
  static const timeoutSeconds = <int>[30, 60, 120, 300];
}

class GpsSettings {
  GpsSettings(this._storage);

  final FlutterSecureStorage _storage;

  static const _entry = 'visitacampo.gps_policy.v1';

  GpsPolicy _policy = const GpsPolicy();

  GpsPolicy get policy => _policy;

  /// Lee los ajustes guardados; sin ellos o ilegibles, los de fábrica.
  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _entry);
      if (raw == null) return;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final target = (json['target_accuracy_m'] as num).toDouble();
      final samples = json['samples'] as int;
      final timeout = json['timeout_s'] as int;
      if (!GpsOptions.targetAccuracyM.contains(target) ||
          !GpsOptions.samples.contains(samples) ||
          !GpsOptions.timeoutSeconds.contains(timeout)) {
        return;
      }
      _policy = GpsPolicy(targetAccuracyM: target, samples: samples, timeout: Duration(seconds: timeout));
    } on Object {
      // Ilegible: se queda con los de fábrica.
    }
  }

  Future<void> update(GpsPolicy policy) async {
    _policy = policy;
    await _storage.write(
      key: _entry,
      value: jsonEncode({
        'target_accuracy_m': policy.targetAccuracyM,
        'samples': policy.samples,
        'timeout_s': policy.timeout.inSeconds,
      }),
    );
  }
}
