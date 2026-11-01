import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/schedule/progress_input.dart';

void main() {
  test('acepta 0..100 con hasta dos decimales, con coma o punto', () {
    expect(parseProgressPct('0'), 0);
    expect(parseProgressPct('35'), 35);
    expect(parseProgressPct(' 35,5 '), 35.5);
    expect(parseProgressPct('99.99'), 99.99);
    expect(parseProgressPct('100'), 100);
  });

  test('rechaza vacío, negativos, más de 100, tres decimales y texto', () {
    for (final text in ['', '-1', '100.01', '101', '33.333', 'abc', '1e2', '35%']) {
      expect(parseProgressPct(text), isNull, reason: text);
    }
  });

  test('se muestra sin ceros de más y con coma', () {
    expect(formatProgressPct(40), '40');
    expect(formatProgressPct(40.5), '40,5');
    expect(formatProgressPct(33.25), '33,25');
    expect(formatProgressPct(100), '100');
    expect(formatProgressPct(0), '0');
  });
}
