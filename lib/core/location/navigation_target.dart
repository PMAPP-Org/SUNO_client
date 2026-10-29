import 'dart:math' as math;

import 'geo.dart';
import 'location_source.dart';

/// Destino WGS84. No depende del sistema elegido para mostrar coordenadas.
class NavigationTarget {
  const NavigationTarget._(this.lat, this.lon);

  final double lat;
  final double lon;

  static NavigationTarget? tryCreate(double? lat, double? lon) {
    if (lat == null || lon == null || !lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) {
      return null;
    }
    return NavigationTarget._(lat, lon);
  }

  double distanceFrom(LocationFix fix) => distanceM(fix.lat, fix.lon, lat, lon);

  /// Azimut inicial, en grados horarios desde el norte geográfico.
  /// En puntos coincidentes o antípodas no existe un rumbo único.
  double? bearingFrom(LocationFix fix) {
    final from = fix.lat * math.pi / 180;
    final to = lat * math.pi / 180;
    final delta = (lon - fix.lon) * math.pi / 180;
    final y = math.sin(delta) * math.cos(to);
    final x = math.cos(from) * math.sin(to) - math.sin(from) * math.cos(to) * math.cos(delta);
    if (x.abs() < 1e-12 && y.abs() < 1e-12) return null;
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// URL universal: app de Google Maps si está instalada o navegador.
  /// Sin origen, identidad, título de la asignación ni datos de la visita.
  /// Decimales fijos: `toString` daría `5e-7` o `-0.0` cerca del ecuador o
  /// del meridiano. Siete decimales son ~1 cm.
  Uri get directionsUri => Uri.https('www.google.com', '/maps/dir/', {
    'api': '1',
    'destination': '${_coordinate(lat)},${_coordinate(lon)}',
  });

  static String _coordinate(double value) {
    if (value.abs() < 5e-8) return '0';
    return value.toStringAsFixed(7).replaceFirst(RegExp(r'\.?0+$'), '');
  }
}

abstract interface class RouteLauncher {
  Future<bool> open(NavigationTarget target);
}
