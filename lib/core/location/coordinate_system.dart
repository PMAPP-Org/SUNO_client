// Sistema de coordenadas en que el agente **ve** las ubicaciones (Fase C).
//
// Todo se guarda y se sincroniza en EPSG:4326 (WGS84, grados): es lo que da
// el GPS y lo que define el contrato (`lat`/`lon`). Elegir otro sistema solo
// cambia cómo se **muestran** las coordenadas, nunca lo que se guarda: así no
// se mezclan sistemas en la base de datos y la elección se puede cambiar en
// cualquier momento sin migrar nada.
//
// Las definiciones PROJ salen de `pyproj` (EPSG oficial), y los tests las
// comprueban contra valores calculados con `pyproj`, no contra sí mismas.
import 'package:meta/meta.dart';
import 'package:proj4dart/proj4dart.dart';

@immutable
class CoordinateSystem {
  const CoordinateSystem._(this.code, this.name, this._proj);

  /// `EPSG:4326`, `EPSG:9377`…
  final String code;
  final String name;

  /// Definición PROJ; `null` para el geográfico WGS84.
  final String? _proj;

  bool get isGeographic => _proj == null;

  static const wgs84 = CoordinateSystem._('EPSG:4326', 'WGS 84 (grados)', null);

  static const magnaOrigenNacional = CoordinateSystem._(
    'EPSG:9377',
    'MAGNA-SIRGAS 2018 / Origen Nacional',
    '+proj=tmerc +lat_0=4 +lon_0=-73 +k=0.9992 +x_0=5000000 +y_0=2000000 +ellps=GRS80 +units=m +no_defs',
  );

  static const magnaBogota = CoordinateSystem._(
    'EPSG:3116',
    'MAGNA-SIRGAS / Colombia Bogotá',
    '+proj=tmerc +lat_0=4.59620041666667 +lon_0=-74.0775079166667 +k=1 '
        '+x_0=1000000 +y_0=1000000 +ellps=GRS80 +units=m +no_defs',
  );

  static const utm18n = CoordinateSystem._(
    'EPSG:32618',
    'WGS 84 / UTM 18N',
    '+proj=utm +zone=18 +datum=WGS84 +units=m +no_defs',
  );

  static const utm19n = CoordinateSystem._(
    'EPSG:32619',
    'WGS 84 / UTM 19N',
    '+proj=utm +zone=19 +datum=WGS84 +units=m +no_defs',
  );

  /// Los que ofrece Ajustes, el de fábrica primero.
  static const all = [wgs84, magnaOrigenNacional, magnaBogota, utm18n, utm19n];

  static CoordinateSystem? byCode(String code) {
    for (final crs in all) {
      if (crs.code == code) return crs;
    }
    return null;
  }

  static final Map<String, Projection> _projections = {};

  /// (este, norte) en metros para [lat]/[lon] en grados WGS84. Solo para
  /// sistemas proyectados.
  ({double easting, double northing}) project(double lat, double lon) {
    final definition = _proj;
    if (definition == null) throw StateError('$code es geográfico: no se proyecta.');
    // `parse` y no `add`: no se registra nada en el almacén global de
    // proj4dart (que `flutter_map` también usa).
    final target = _projections.putIfAbsent(code, () => Projection.parse(definition));
    final point = Projection.WGS84.transform(target, Point(x: lon, y: lat));
    return (easting: point.x, northing: point.y);
  }

  /// Texto para mostrar [lat]/[lon] en este sistema: grados con 6 decimales
  /// (~0,1 m) o metros con 2.
  String format(double lat, double lon) {
    if (isGeographic) return 'lat ${lat.toStringAsFixed(6)}, lon ${lon.toStringAsFixed(6)}';
    final p = project(lat, lon);
    return 'E ${p.easting.toStringAsFixed(2)}, N ${p.northing.toStringAsFixed(2)} ($code)';
  }

  @override
  bool operator ==(Object other) => other is CoordinateSystem && other.code == code;

  @override
  int get hashCode => code.hashCode;
}
