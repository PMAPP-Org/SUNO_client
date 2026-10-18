// Fase C: el sistema elegido sobrevive a reiniciar la app; uno desconocido
// vuelve a WGS84.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/location/coordinate_settings.dart';
import 'package:visitacampo/core/location/coordinate_system.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('de fábrica, WGS84', () async {
    final settings = CoordinateSettings(const FlutterSecureStorage());
    await settings.load();
    expect(settings.current.value, CoordinateSystem.wgs84);
  });

  test('lo elegido sobrevive a reiniciar la app', () async {
    await CoordinateSettings(const FlutterSecureStorage()).update(CoordinateSystem.magnaOrigenNacional);
    final restarted = CoordinateSettings(const FlutterSecureStorage());
    await restarted.load();
    expect(restarted.current.value, CoordinateSystem.magnaOrigenNacional);
  });

  test('un código desconocido vuelve a WGS84', () async {
    FlutterSecureStorage.setMockInitialValues({'visitacampo.coordinate_system.v1': 'EPSG:1234'});
    final settings = CoordinateSettings(const FlutterSecureStorage());
    await settings.load();
    expect(settings.current.value, CoordinateSystem.wgs84);
  });
}
