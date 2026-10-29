import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/core/location/navigation_target.dart';

void main() {
  const origin = LocationFix(lat: 0, lon: 0, accuracyM: 3);

  test('azimuts cardinales y distancia conocida de un grado en el ecuador', () {
    for (final (lat, lon, bearing) in [(1.0, 0.0, 0), (0.0, 1.0, 90), (-1.0, 0.0, 180), (0.0, -1.0, 270)]) {
      final target = NavigationTarget.tryCreate(lat, lon)!;
      expect(target.bearingFrom(origin), closeTo(bearing, 1e-9));
      expect(target.distanceFrom(origin), closeTo(111195.08, 0.01));
    }
  });

  test('cruza el antimeridiano por el camino corto; coincide y antípoda sin rumbo', () {
    const fix = LocationFix(lat: 0, lon: 179.9, accuracyM: 3);
    final target = NavigationTarget.tryCreate(0, -179.9)!;
    expect(target.bearingFrom(fix), closeTo(90, 1e-9));
    expect(target.distanceFrom(fix), closeTo(22239.02, 0.01));
    expect(NavigationTarget.tryCreate(0, 0)!.bearingFrom(origin), isNull);
    expect(NavigationTarget.tryCreate(0, 180)!.bearingFrom(origin), isNull);
  });

  test('no ofrece navegación sin punto WGS84 válido', () {
    for (final (lat, lon) in <(double?, double?)>[
      (null, 0),
      (0, null),
      (double.nan, 0),
      (0, double.infinity),
      (91, 0),
      (0, -181),
    ]) {
      expect(NavigationTarget.tryCreate(lat, lon), isNull);
    }
    expect(NavigationTarget.tryCreate(-90, 180), isNotNull);
  });

  test('URL de ruta solo comparte destino en WGS84 y conserva orden latitud,longitud', () {
    final uri = NavigationTarget.tryCreate(4.6097, -74.0817)!.directionsUri;
    expect(uri.scheme, 'https');
    expect(uri.host, 'www.google.com');
    expect(uri.path, '/maps/dir/');
    expect(uri.queryParameters, {'api': '1', 'destination': '4.6097,-74.0817'});
  });

  test('URL de ruta sin notación exponencial ni cero negativo', () {
    String destination(double lat, double lon) =>
        NavigationTarget.tryCreate(lat, lon)!.directionsUri.queryParameters['destination']!;
    expect(destination(0.0000005, -78.5), '0.0000005,-78.5');
    expect(destination(-0.0, 10), '0,10');
    expect(destination(1e-9, -1e-9), '0,0');
  });
}
