// Fase C: longitud y área frente a `pyproj.Geod` (elipsoide WGS84). Lo
// esférico se acepta con un error relativo < 0,5 %.
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/location/geo.dart';

void main() {
  test('longitud de una línea', () {
    final line = [
      [-74.08, 4.6],
      [-74.079, 4.601],
      [-74.07, 4.61],
    ];
    expect(lineLengthM(line), closeTo(1566.555, 1566.555 * 0.005));
  });

  test('área de un lote pequeño (~1,2 ha) y de uno grande (~123 km²)', () {
    final lote = [
      [-74.08, 4.6],
      [-74.079, 4.6],
      [-74.079, 4.601],
      [-74.08, 4.601],
      [-74.08, 4.6],
    ];
    expect(polygonAreaM2(lote), closeTo(12270.471, 12270.471 * 0.005));
    final grande = [
      [-74.1, 4.5],
      [-74.0, 4.5],
      [-74.0, 4.6],
      [-74.1, 4.6],
      [-74.1, 4.5],
    ];
    expect(polygonAreaM2(grande), closeTo(122713153.4, 122713153.4 * 0.005));
  });

  test('el sentido del anillo no cambia el área; menos de 3 vértices es 0', () {
    final cw = [
      [-74.08, 4.6],
      [-74.08, 4.601],
      [-74.079, 4.601],
      [-74.079, 4.6],
    ];
    expect(polygonAreaM2(cw), closeTo(12270.471, 12270.471 * 0.005));
    expect(polygonAreaM2(cw.sublist(0, 2)), 0);
  });
}
