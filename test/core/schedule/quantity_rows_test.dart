// Filas de cantidad (costos, pieza 4b): número, notas obligatorias, sobreejecución,
// payload del contrato y lectura de lo guardado. Puro.
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/schedule/quantity_rows.dart';

const _concrete = QuantityItem(itemId: 'item-1', code: '2.1', description: 'Concreto zapatas', unit: 'm3');
const _steel = QuantityItem(itemId: 'item-2', code: '2.2', description: 'Acero de refuerzo', unit: 'kg');

QuantityRowDraft _planned(String id, String text, {String note = '', double validated = 4}) => QuantityRowDraft(
  clientId: id,
  item: _concrete,
  planned: 10,
  validated: validated,
  isPlanned: true,
  text: text,
  note: note,
);

QuantityRowDraft _unplanned(String id, String text, {String note = ''}) =>
    QuantityRowDraft(clientId: id, item: _steel, text: text, note: note, added: true);

void main() {
  group('parseQuantity', () {
    test('acepta coma o punto, signo y hasta 4 decimales', () {
      expect(parseQuantity('12,5'), 12.5);
      expect(parseQuantity(' 3.0001 '), 3.0001);
      expect(parseQuantity('-2'), -2);
      expect(parseQuantity('99999999999,9999'), closeTo(99999999999.9999, 0.0001));
      expect(parseQuantity('0,0001'), 0.0001);
    });

    test('rechaza lo demás', () {
      // Hasta 15 cifras significativas: lo que el contrato devuelve exacto.
      for (final text in ['', 'abc', '1,23456', '123456789012345', '1e3', '--1', '1,', '99999999999999,9999']) {
        expect(parseQuantity(text), isNull, reason: text);
      }
    });
  });

  test('formatQuantity: sin ceros sobrantes y con coma', () {
    expect(formatQuantity(10), '10');
    expect(formatQuantity(2.5), '2,5');
    expect(formatQuantity(-0.125), '-0,125');
    expect(formatQuantity(1.23456), '1,2346');
  });

  group('checkQuantityRows', () {
    test('ítem no planeado y ajuste negativo exigen nota', () {
      final check = checkQuantityRows([_planned('a', '-1'), _unplanned('b', '3'), _planned('c', '2')]);
      expect(check.rows, {'a': QuantityRowProblem.noteRequired, 'b': QuantityRowProblem.noteRequired});
      expect(check.ok, isFalse);
      expect(checkQuantityRows([_planned('a', '-1', note: 'ajuste'), _unplanned('b', '3', note: 'extra')]).ok, isTrue);
    });

    test('las filas vacías o en 0 no cuentan; hace falta al menos una cantidad', () {
      final check = checkQuantityRows([_planned('a', ''), _planned('b', '0'), _unplanned('c', '')]);
      expect(check.rows, isEmpty);
      expect(check.noQuantity, isTrue);
    });

    test('un número mal escrito se señala en su fila', () {
      expect(checkQuantityRows([_planned('a', '1,23456')]).rows, {'a': QuantityRowProblem.invalidNumber});
    });

    test('hasta 200 filas con cantidad', () {
      final rows = [for (var i = 0; i < maxQuantityRows + 1; i++) _planned('r$i', '1')];
      expect(checkQuantityRows(rows).tooManyRows, isTrue);
      expect(checkQuantityRows(rows.sublist(1)).tooManyRows, isFalse);
    });

    test('nota de más de 500 caracteres', () {
      expect(checkQuantityRows([_unplanned('a', '1', note: 'x' * 501)]).rows, {'a': QuantityRowProblem.noteTooLong});
    });
  });

  test('sobreejecución: lo validado más la suma de hoy del ítem supera lo planeado', () {
    expect(overrunItems([_planned('a', '3'), _planned('b', '4')]), {'item-1'});
    expect(overrunItems([_planned('a', '6')]), isEmpty);
    expect(todayTotal([_planned('a', '3'), _planned('b', '2,5')], 'item-1'), 5.5);
  });

  test('payload: solo las filas con cantidad distinta de 0, con la forma del contrato', () {
    final row = _planned('a', '12,5', note: ' bien ').copyWith(
      locationId: 'loc-2',
      capturedAt: DateTime.utc(2026, 11, 9, 14, 3),
      gps: const GpsReading(lat: 4.6, lon: -74.08, accuracyM: 7),
      seen: const QuantitySeen(planned: 10, validated: 4, locationId: 'loc-1'),
    );
    expect(quantityPayload([row, _planned('b', '0'), _planned('c', '')]), [
      {
        'item_id': 'item-1',
        'location_id': 'loc-2',
        'quantity': 12.5,
        'note': 'bien',
        'client_id': 'a',
        'captured_at': '2026-11-09T14:03:00.000Z',
        'gps': {'lat': 4.6, 'lon': -74.08, 'accuracy_m': 7.0},
        'seen': {'planned': 10.0, 'validated': 4.0, 'location_id': 'loc-1'},
        'location_mode': 'refined',
      },
    ]);
  });

  test('lo guardado vuelve como fila (también una del pull sin datos automáticos)', () {
    final row = QuantityRowDraft.fromStored(
      {
        'item_id': 'item-1',
        'location_id': null,
        'quantity': 3.5,
        'note': '',
        'client_id': null,
        'captured_at': null,
        'gps': null,
        'seen': null,
        'location_mode': null,
      },
      item: _concrete,
      planned: const PlannedQuantity(item: _concrete, planned: 10, validated: 4),
      fallbackId: 'nuevo',
    );
    expect(
      (row.clientId, row.text, row.isPlanned, row.locationMode, row.capturedAt),
      ('nuevo', '3,5', true, 'task', null),
    );
    final full = QuantityRowDraft.fromStored(
      quantityPayload([
        _planned(
          'a',
          '2',
        ).copyWith(capturedAt: DateTime.utc(2026), gps: const GpsReading(lat: 1, lon: 2, accuracyM: 3)),
      ]).single,
      item: _concrete,
      fallbackId: 'x',
    );
    expect(
      (full.clientId, full.capturedAt, full.gps?.accuracyM, full.isPlanned),
      ('a', DateTime.utc(2026), 3.0, false),
    );
  });

  group('una fila que ya existía se reenvía sin datos automáticos nuevos', () {
    // Revisión del servidor: un registro validado compara la forma guardada, así que
    // agregar `client_id` u otro dato automático a una fila vieja (o del pull sin ellos)
    // haría rechazar con `record_validated` un reenvío que no cambia nada.
    const legacy = {
      'item_id': 'item-1',
      'location_id': null,
      'quantity': 3.5,
      'note': '',
      'client_id': null,
      'captured_at': null,
      'gps': null,
      'seen': null,
      'location_mode': null,
    };

    test('sin client_id ni datos automáticos: solo ítem, ubicación, cantidad y nota', () {
      final row = QuantityRowDraft.fromStored(legacy, item: _concrete, fallbackId: 'nuevo');
      expect(row.toPayload(), {'item_id': 'item-1', 'location_id': null, 'quantity': 3.5, 'note': ''});
    });

    test('aunque se le pongan hora, GPS o ubicación al editarla', () {
      final row = QuantityRowDraft.fromStored(legacy, item: _concrete, fallbackId: 'nuevo').copyWith(
        text: '4',
        locationId: 'loc-2',
        capturedAt: DateTime.utc(2026, 11, 9),
        gps: const GpsReading(lat: 1, lon: 2, accuracyM: 3),
        seen: const QuantitySeen(planned: 10, validated: 4, locationId: null),
      );
      // La ubicación cambió: su modo se recalcula; lo demás no se agrega.
      expect(row.toPayload(), {
        'item_id': 'item-1',
        'location_id': 'loc-2',
        'quantity': 4.0,
        'note': '',
        'location_mode': 'refined',
      });
    });

    test('con datos automáticos: se reenvían tal como llegaron', () {
      const stored = {
        'item_id': 'item-1',
        'location_id': 'loc-2',
        'quantity': 2,
        'note': 'n',
        'client_id': 'c-1',
        'captured_at': '2026-11-09T14:03:00.000Z',
        'gps': null,
        'seen': {'planned': 10.0, 'validated': null, 'location_id': null},
        // Otro cliente pudo enviar `task` con una ubicación precisada: no se recalcula.
        'location_mode': 'task',
      };
      final row = QuantityRowDraft.fromStored(
        stored,
        item: _concrete,
        fallbackId: 'x',
      ).copyWith(capturedAt: DateTime.utc(2030));
      expect(row.toPayload(), {
        'item_id': 'item-1',
        'location_id': 'loc-2',
        'quantity': 2.0,
        'note': 'n',
        'client_id': 'c-1',
        'captured_at': '2026-11-09T14:03:00.000Z',
        'seen': {'planned': 10.0, 'validated': null, 'location_id': null},
        'location_mode': 'task',
      });
    });
  });

  group('modo de ubicación de una fila guardada', () {
    const stored = {
      'item_id': 'item-1',
      'location_id': 'loc-2',
      'quantity': 2,
      'note': '',
      'client_id': 'c-1',
      'captured_at': '2026-11-09T14:03:00.000Z',
      'gps': {'lat': 4.6, 'lon': -74.08, 'accuracy_m': 7.0},
      'seen': {'planned': 10.0, 'validated': 4.0, 'location_id': 'loc-1'},
      'location_mode': 'refined',
    };

    test('sin tocar: idéntica a lo guardado', () {
      final row = QuantityRowDraft.fromStored(stored, item: _concrete, fallbackId: 'x');
      expect(row.toPayload(), {...stored, 'quantity': 2.0});
    });

    test('si pasa a la ubicación de la tarea, el modo se recalcula; lo demás queda', () {
      final row = QuantityRowDraft.fromStored(stored, item: _concrete, fallbackId: 'x').copyWith(locationId: null);
      expect(row.toPayload(), {...stored, 'quantity': 2.0, 'location_id': null, 'location_mode': 'task'});
    });

    test('si vuelve a la ubicación guardada, el modo guardado vuelve', () {
      final row = QuantityRowDraft.fromStored(
        stored,
        item: _concrete,
        fallbackId: 'x',
      ).copyWith(locationId: null).copyWith(locationId: 'loc-2');
      expect(row.toPayload()['location_mode'], 'refined');
    });
  });

  test('withUnit: sin espacios dobles si no hay unidad', () {
    expect(withUnit(2.5, 'm3'), '2,5 m3');
    expect(withUnit(2.5, ''), '2,5');
  });

  test('sameQuantities no depende del orden de las filas', () {
    final a = {'item_id': 'a', 'location_id': null, 'quantity': 1, 'note': ''};
    final b = {'item_id': 'b', 'location_id': 'loc', 'quantity': 2, 'note': 'n'};
    expect(sameQuantities([a, b, a], [b, a, a]), isTrue);
    expect(sameQuantities([a, b], [a, a]), isFalse);
    expect(sameQuantities([a], [a, a]), isFalse);
  });

  test('sameQuantities compara ítem, ubicación, cantidad y nota', () {
    final a = [
      {'item_id': 'i', 'location_id': null, 'quantity': 2, 'note': 'x', 'gps': null},
    ];
    final b = [
      {
        'item_id': 'i',
        'location_id': null,
        'quantity': 2.0,
        'note': 'x',
        'client_id': 'c',
        'seen': {'planned': 1},
      },
    ];
    expect(sameQuantities(a, b), isTrue);
    expect(
      sameQuantities(a, [
        {...b.single, 'quantity': 3},
      ]),
      isFalse,
    );
    expect(sameQuantities(const [], decodeQuantities('[]')), isTrue);
  });

  test('QuantityLine: código y unidad conocidos, o el id si no', () {
    final line = QuantityLine.fromStored({'item_id': 'item-9', 'location_id': 'loc-2', 'quantity': 1, 'note': 'n'});
    expect((line.code, line.label, line.locationId, line.quantity), ('', 'item-9', 'loc-2', 1.0));
    final known = QuantityLine.fromStored({
      'item_id': 'item-1',
      'location_id': null,
      'quantity': 2.5,
      'note': '',
    }, item: _concrete);
    expect((known.label, known.unit), ('2.1 Concreto zapatas', 'm3'));
  });
}
