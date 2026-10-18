// Cálculos geográficos pequeños (Fase B y C).
//
// Esféricos (radio medio de la Tierra), suficientes para trabajo de campo:
// frente al elipsoide WGS84 (`pyproj.Geod`) el error es < 0,5 %, que los
// tests acotan. Las posiciones GeoJSON van como `[lon, lat]`.
import 'dart:math' as math;

const _earthRadiusM = 6371008.8;

double _rad(double deg) => deg * math.pi / 180;

/// Distancia en metros entre dos puntos WGS84 (haversine).
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) + math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(a)));
}

/// Longitud en metros de una línea de posiciones `[lon, lat]`.
double lineLengthM(List<List<double>> positions) {
  var total = 0.0;
  for (var i = 1; i < positions.length; i++) {
    total += distanceM(positions[i - 1][1], positions[i - 1][0], positions[i][1], positions[i][0]);
  }
  return total;
}

/// Área en m² de un anillo `[lon, lat]` (cerrado o no): fórmula esférica de
/// Chamberlain y Duquette, la que usan OpenLayers y Turf.
double polygonAreaM2(List<List<double>> ring) {
  if (ring.length < 3) return 0;
  var sum = 0.0;
  for (var i = 0; i < ring.length; i++) {
    final p1 = ring[i];
    final p2 = ring[(i + 1) % ring.length];
    sum += _rad(p2[0] - p1[0]) * (2 + math.sin(_rad(p1[1])) + math.sin(_rad(p2[1])));
  }
  return (sum * _earthRadiusM * _earthRadiusM / 2).abs();
}
