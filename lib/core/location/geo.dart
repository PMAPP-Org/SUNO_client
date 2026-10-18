// Cálculos geográficos pequeños (Fase B).
import 'dart:math' as math;

const _earthRadiusM = 6371008.8;

/// Distancia en metros entre dos puntos WGS84 (haversine). Para distancias de
/// campo (metros a decenas de km) el error frente al elipsoide es < 0,5 %.
double distanceM(double lat1, double lon1, double lat2, double lon2) {
  double rad(double deg) => deg * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(a)));
}
