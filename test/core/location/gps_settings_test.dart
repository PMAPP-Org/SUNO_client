// Ajustes del GPS (Fase A): se guardan, y un valor guardado fuera de las
// opciones vuelve al de fábrica.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/location/gps_sampler.dart';
import 'package:visitacampo/core/location/gps_settings.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('sin nada guardado, los de fábrica', () async {
    final settings = GpsSettings(const FlutterSecureStorage());
    await settings.load();
    expect(settings.policy.targetAccuracyM, const GpsPolicy().targetAccuracyM);
  });

  test('lo guardado sobrevive a reiniciar la app', () async {
    await GpsSettings(
      const FlutterSecureStorage(),
    ).update(const GpsPolicy(targetAccuracyM: 20, samples: 3, timeout: Duration(seconds: 120)));

    final restarted = GpsSettings(const FlutterSecureStorage());
    await restarted.load();
    expect(restarted.policy.targetAccuracyM, 20);
    expect(restarted.policy.samples, 3);
    expect(restarted.policy.timeout, const Duration(seconds: 120));
  });

  test('un valor fuera de las opciones o ilegible vuelve a los de fábrica', () async {
    for (final raw in ['{"target_accuracy_m": 10, "samples": 5, "timeout_s": 0}', '{roto']) {
      FlutterSecureStorage.setMockInitialValues({'visitacampo.gps_policy.v1': raw});
      final settings = GpsSettings(const FlutterSecureStorage());
      await settings.load();
      expect(settings.policy.timeout, const GpsPolicy().timeout, reason: raw);
    }
  });
}
