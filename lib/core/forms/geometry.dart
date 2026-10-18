// Geometrías de los campos `line` y `polygon` (Fase C): vértices ↔ GeoJSON.
//
// Los vértices van en el orden en que el agente los marcó, como `[lon, lat]`
// en WGS84 (el orden de GeoJSON). Un polígono se guarda **cerrado** (el
// último vértice repite el primero), como exige el servidor; en pantalla se
// trabaja con el anillo abierto.
import 'package:meta/meta.dart';

import '../location/geo.dart';

enum GeometryKind {
  line,
  polygon;

  /// Vértices mínimos (distintos) para poder guardar.
  int get minVertices => this == line ? 2 : 3;
}

@immutable
class Vertex {
  const Vertex(this.lat, this.lon);
  final double lat;
  final double lon;

  List<double> get position => [lon, lat];

  @override
  bool operator ==(Object other) => other is Vertex && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);
}

/// GeoJSON de [vertices] para el tipo [kind].
Map<String, Object?> toGeoJson(GeometryKind kind, List<Vertex> vertices) => switch (kind) {
  GeometryKind.line => {
    'type': 'LineString',
    'coordinates': [for (final v in vertices) v.position],
  },
  GeometryKind.polygon => {
    'type': 'Polygon',
    'coordinates': [
      [for (final v in vertices) v.position, vertices.first.position],
    ],
  },
};

/// Los vértices de una respuesta guardada (anillo abierto en polígonos);
/// vacío si no tiene la forma esperada.
List<Vertex> verticesOf(Object? geoJson) {
  if (geoJson is! Map) return const [];
  final coordinates = geoJson['coordinates'];
  final positions = switch (geoJson['type']) {
    'LineString' => coordinates,
    'Polygon' when coordinates is List && coordinates.length == 1 => coordinates.single,
    _ => null,
  };
  if (positions is! List) return const [];
  final vertices = <Vertex>[
    for (final p in positions)
      if (p is List && p.length == 2 && p[0] is num && p[1] is num) Vertex((p[1] as num).toDouble(), (p[0] as num).toDouble()),
  ];
  if (geoJson['type'] == 'Polygon' && vertices.length > 1 && vertices.first == vertices.last) {
    vertices.removeLast();
  }
  return vertices;
}

/// Tipo de una respuesta guardada, o `null` si no es una línea o polígono.
GeometryKind? kindOf(Object? geoJson) => switch (geoJson) {
  {'type': 'LineString'} => GeometryKind.line,
  {'type': 'Polygon'} => GeometryKind.polygon,
  _ => null,
};

/// Longitud (línea) o área (polígono) en unidades base: m o m².
double measure(GeometryKind kind, List<Vertex> vertices) {
  final positions = [for (final v in vertices) v.position];
  return kind == GeometryKind.line ? lineLengthM(positions) : polygonAreaM2(positions);
}

/// `123 m` / `1.25 km` y `850 m²` / `1.23 ha`.
String formatMeasure(GeometryKind kind, double value) {
  if (kind == GeometryKind.line) {
    return value < 1000 ? '${value.round()} m' : '${(value / 1000).toStringAsFixed(2)} km';
  }
  return value < 10000 ? '${value.round()} m²' : '${(value / 10000).toStringAsFixed(2)} ha';
}
