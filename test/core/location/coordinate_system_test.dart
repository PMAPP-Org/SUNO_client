// Fase C: conversiones de WGS84 a los sistemas que ofrece Ajustes. Los
// valores esperados se calcularon con `pyproj` (PROJ/EPSG oficial), no con
// la propia implementación.
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/location/coordinate_system.dart';

typedef _Case = ({double lat, double lon, double e, double n});

void main() {
  // Bogotá, Barranquilla, Leticia.
  final expected = <CoordinateSystem, List<_Case>>{
    CoordinateSystem.magnaOrigenNacional: [
      (lat: 4.6097, lon: -74.0817, e: 4880061.559, n: 2067458.018),
      (lat: 10.9878, lon: -74.7889, e: 4804614.225, n: 2772775.465),
      (lat: -4.2153, lon: -69.9406, e: 5339544.706, n: 1091643.422),
    ],
    CoordinateSystem.magnaBogota: [
      (lat: 4.6097, lon: -74.0817, e: 999534.839, n: 1001492.805),
      (lat: 10.9878, lon: -74.7889, e: 922248.636, n: 1706976.059),
      (lat: -4.2153, lon: -69.9406, e: 1459678.952, n: 24433.933),
    ],
    CoordinateSystem.utm18n: [
      (lat: 4.6097, lon: -74.0817, e: 601859.799, n: 509586.985),
      (lat: 10.9878, lon: -74.7889, e: 523062.372, n: 1214638.572),
    ],
    CoordinateSystem.utm19n: [(lat: 4.6097, lon: -74.0817, e: -64384.822, n: 511536.858)],
  };

  for (final MapEntry(key: crs, value: cases) in expected.entries) {
    test('${crs.code} coincide con PROJ (±1 cm)', () {
      for (final c in cases) {
        final p = crs.project(c.lat, c.lon);
        expect(p.easting, closeTo(c.e, 0.01), reason: '${c.lat},${c.lon} este');
        expect(p.northing, closeTo(c.n, 0.01), reason: '${c.lat},${c.lon} norte');
      }
    });
  }

  test('WGS84 se muestra en grados y no se proyecta', () {
    expect(CoordinateSystem.wgs84.format(4.6097, -74.0817), 'lat 4.609700, lon -74.081700');
    expect(() => CoordinateSystem.wgs84.project(4.6, -74), throwsStateError);
  });

  test('un proyectado se muestra en metros con su código', () {
    expect(
      CoordinateSystem.magnaOrigenNacional.format(4.6097, -74.0817),
      'E 4880061.56, N 2067458.02 (EPSG:9377)',
    );
  });

  test('se encuentra por su código; uno desconocido es null', () {
    expect(CoordinateSystem.byCode('EPSG:9377'), CoordinateSystem.magnaOrigenNacional);
    expect(CoordinateSystem.byCode('EPSG:1234'), isNull);
    expect(CoordinateSystem.all.first, CoordinateSystem.wgs84, reason: 'el de fábrica');
  });
}
