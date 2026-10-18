// Fase C: vértices ↔ GeoJSON, y que lo que produce la app pase la misma
// validación que el servidor.
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/forms/geometry.dart';

const _label = I18nText({'es': 'x'});

void main() {
  const lote = [Vertex(4.6, -74.08), Vertex(4.6, -74.079), Vertex(4.601, -74.079)];

  test('un polígono se guarda cerrado y vuelve abierto', () {
    final geoJson = toGeoJson(GeometryKind.polygon, lote);
    expect(geoJson, {
      'type': 'Polygon',
      'coordinates': [
        [
          [-74.08, 4.6],
          [-74.079, 4.6],
          [-74.079, 4.601],
          [-74.08, 4.6],
        ],
      ],
    });
    expect(verticesOf(geoJson), lote);
    expect(kindOf(geoJson), GeometryKind.polygon);
  });

  test('lo que produce la app es válido para el validador compartido', () {
    const polygon = PolygonFieldDef(key: 'lote', label: _label, help: null, required: false, visibleIf: null);
    const line = LineFieldDef(key: 'cerca', label: _label, help: null, required: false, visibleIf: null);
    expect(polygon.checkAnswer(toGeoJson(GeometryKind.polygon, lote)), isNull);
    expect(line.checkAnswer(toGeoJson(GeometryKind.line, lote)), isNull);
  });

  test('medidas legibles en m/km y m²/ha', () {
    expect(formatMeasure(GeometryKind.line, 850.4), '850 m');
    expect(formatMeasure(GeometryKind.line, 1566.5), '1.57 km');
    expect(formatMeasure(GeometryKind.polygon, 8500), '8500 m²');
    expect(formatMeasure(GeometryKind.polygon, 12270), '1.23 ha');
  });

  test('una respuesta que no es geometría no da vértices', () {
    expect(verticesOf({'lat': 4.6, 'lon': -74}), isEmpty);
    expect(kindOf('x'), isNull);
  });
}
