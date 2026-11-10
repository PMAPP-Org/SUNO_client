// Paridad con el contrato (costos, pieza 4b): lo que la app envía en cada fila de
// cantidad y lo que lee de la lista de tareas existe en `contract/v1.yaml`, la copia
// fijada del contrato del servidor.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/schedule/quantity_rows.dart';
import 'package:yaml/yaml.dart';

void main() {
  final schemas =
      ((loadYaml(File('contract/v1.yaml').readAsStringSync()) as Map)['components'] as Map)['schemas'] as Map;

  Set<String> properties(String name) => {
    for (final key in ((schemas[name] as Map)['properties'] as Map).keys) key as String,
  };
  Set<String> required(String name) => {
    for (final key in ((schemas[name] as Map)['required'] as List?) ?? const []) key as String,
  };

  final row = QuantityRowDraft(
    clientId: '0190f5d2-0000-7000-8000-000000000001',
    item: const QuantityItem(itemId: 'item-1', code: '1.1', description: 'Excavación', unit: 'm3'),
    planned: 100,
    validated: 4,
    isPlanned: true,
    text: '12,5',
    capturedAt: DateTime.utc(2026, 11, 9, 14),
    gps: const GpsReading(lat: 4.6, lon: -74.08, accuracyM: 7),
    seen: const QuantitySeen(planned: 100, validated: 4, locationId: null),
  ).toPayload();

  test('cada clave de la fila que se envía está en RecordQuantityPayload', () {
    expect(properties('RecordQuantityPayload'), containsAll(row.keys));
    expect(row.keys, containsAll(required('RecordQuantityPayload')));
  });

  test('gps y seen tienen exactamente las claves del contrato', () {
    expect((row['gps']! as Map).keys.toSet(), required('QuantityGps'));
    expect((row['seen']! as Map).keys.toSet(), required('QuantitySeen'));
  });

  test('lo que se guarda tras el pull tiene las claves de RecordQuantity', () {
    expect(required('RecordQuantity'), containsAll(row.keys));
  });

  test('una fila del pull sin datos automáticos se reenvía con claves del payload', () {
    final pulled = <String, Object?>{for (final key in required('RecordQuantity')) key: null}
      ..addAll({'item_id': 'item-1', 'quantity': 2, 'note': ''});
    final resent = QuantityRowDraft.fromStored(
      pulled,
      item: const QuantityItem.unknown('item-1'),
      fallbackId: 'x',
    ).toPayload();
    expect(properties('RecordQuantityPayload'), containsAll(resent.keys));
    expect(resent.containsKey('client_id'), isFalse);
  });

  test('la lista de tareas trae lo que lee ScheduleTaskSync', () {
    expect(properties('FieldTaskList'), containsAll(['version', 'changed', 'items', 'project_items']));
    expect(properties('FieldTask'), containsAll(['measured_by', 'location', 'location_options', 'planned_items']));
    expect(
      properties('FieldPlannedItem'),
      containsAll(['item_id', 'code', 'description', 'unit', 'planned_quantity', 'executed_quantity']),
    );
    expect(properties('FieldLocation'), containsAll(['id', 'label']));
    expect(properties('FieldProjectItems'), containsAll(['project_id', 'items']));
    expect(properties('FieldProjectItem'), containsAll(['item_id', 'code', 'description', 'unit']));
  });
}
