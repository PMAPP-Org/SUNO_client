// Captura de cantidades (costos, pieza 4b): el controlador lleva las filas y sus datos
// automáticos; la sección las dibuja con sus avisos.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/schedule/quantity_rows.dart';
import 'package:suno/features/capture/quantity_capture_section.dart';

import '../../support/test_app.dart';

const _concrete = QuantityItem(itemId: 'item-1', code: '2.1', description: 'Concreto zapatas', unit: 'm3');
const _steel = QuantityItem(itemId: 'item-2', code: '2.2', description: 'Acero de refuerzo', unit: 'kg');

const _task = QuantityTaskContext(
  taskId: 'task-1',
  planned: [PlannedQuantity(item: _concrete, planned: 10, validated: 8)],
  locations: [
    LocationChoice(id: 'loc-1', label: 'Tramo 2', isTaskLocation: true),
    LocationChoice(id: 'loc-2', label: 'Tramo 2 / PR 1', isTaskLocation: false),
  ],
  catalog: [_concrete, _steel],
);

void main() {
  late QuantityCaptureController controller;
  late List<GpsReading?> gps;
  var ids = 0;

  setUp(() {
    ids = 0;
    gps = [const GpsReading(lat: 4.6, lon: -74.08, accuracyM: 7)];
    controller = QuantityCaptureController(
      newId: () => 'c-${ids++}',
      readGps: () async => gps.isEmpty ? null : gps.removeAt(0),
      clock: () => DateTime.utc(2026, 11, 9, 14),
    );
  });
  tearDown(() => controller.dispose());

  group('controlador', () {
    test('una fila vacía por ítem planeado', () {
      controller.load(_task);
      expect(
        [for (final r in controller.rows) (r.clientId, r.item.code, r.isPlanned, r.text)],
        [('c-0', '2.1', true, '')],
      );
      expect(controller.hasCaptured, isFalse);
    });

    test('al digitar por primera vez toma la hora, lo que se veía y una lectura GPS', () async {
      controller.load(_task);
      controller.setQuantity('c-0', '1');
      await Future<void>.delayed(Duration.zero);
      controller.setQuantity('c-0', '1,5');
      final row = controller.rows.single;
      expect(row.capturedAt, DateTime.utc(2026, 11, 9, 14));
      expect(row.seen?.toJson(), {'planned': 10.0, 'validated': 8.0, 'location_id': 'loc-1'});
      expect(row.gps?.accuracyM, 7);
      expect(row.text, '1,5');
      expect(gps, isEmpty, reason: 'una sola lectura por fila');
      expect(controller.hasCaptured, isTrue);
    });

    test('precisar la ubicación cambia el modo', () {
      controller.load(_task);
      controller.setLocation('c-0', 'loc-2');
      expect((controller.rows.single.locationId, controller.rows.single.locationMode), ('loc-2', 'refined'));
      controller.setLocation('c-0', null);
      expect(controller.rows.single.locationMode, 'task');
    });

    test('otra fila del mismo ítem y un ítem no planeado; las agregadas se quitan', () {
      controller.load(_task);
      controller.addRowLike('c-0');
      controller.addUnplanned(_steel);
      expect(
        [for (final r in controller.rows) (r.item.code, r.isPlanned, r.added)],
        [('2.1', true, false), ('2.1', true, true), ('2.2', false, true)],
      );
      controller.removeRow('c-1');
      expect(controller.rows.length, 2);
    });

    test('validar: nota obligatoria en el no planeado y al menos una cantidad', () {
      controller.load(_task);
      expect(controller.validate(), isFalse);
      expect(controller.check?.noQuantity, isTrue);
      controller.addUnplanned(_steel);
      controller.setQuantity('c-1', '3');
      expect(controller.validate(), isFalse);
      expect(controller.check?.rows, {'c-1': QuantityRowProblem.noteRequired});
      controller.setNote('c-1', 'sobrante');
      expect(controller.validate(), isTrue);
      expect([for (final r in controller.payload()) r['item_id']], ['item-2']);
    });

    test('carga lo guardado: la primera fila de un ítem planeado ocupa su lugar', () {
      controller.load(
        _task,
        stored: [
          {'item_id': 'item-1', 'location_id': null, 'quantity': 2, 'note': '', 'client_id': 'g-1'},
          {'item_id': 'item-1', 'location_id': 'loc-2', 'quantity': 1, 'note': '', 'client_id': 'g-2'},
          {'item_id': 'item-9', 'location_id': null, 'quantity': 4, 'note': 'x', 'client_id': 'g-3'},
        ],
        known: {'item-9': const QuantityItem(itemId: 'item-9', code: '9.9', description: 'Viejo', unit: 'un')},
        flaggedRows: {2},
      );
      expect(
        [for (final r in controller.rows) (r.clientId, r.item.code, r.text, r.added)],
        [('g-1', '2.1', '2', false), ('g-2', '2.1', '1', true), ('g-3', '9.9', '4', true)],
      );
      expect(controller.isFlagged('g-3'), isTrue);
      controller.reassignItem('g-3', _concrete);
      final last = controller.rows.last;
      expect((last.item.code, last.isPlanned, controller.isFlagged('g-3')), ('2.1', true, false));
    });

    test('una fila guardada sin datos automáticos se edita sin ganarlos ni leer el GPS', () async {
      controller.load(
        _task,
        stored: [
          {
            'item_id': 'item-1',
            'location_id': null,
            'quantity': 2,
            'note': '',
            'client_id': null,
            'captured_at': null,
            'gps': null,
            'seen': null,
            'location_mode': null,
          },
        ],
      );
      final id = controller.rows.single.clientId;
      controller.setQuantity(id, '3');
      await Future<void>.delayed(Duration.zero);
      expect(gps, hasLength(1), reason: 'no se lee el GPS');
      expect(controller.payload(), [
        {'item_id': 'item-1', 'location_id': null, 'quantity': 3.0, 'note': ''},
      ]);
    });
  });

  Future<void> pump(WidgetTester tester, {bool correcting = false}) async {
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ListView(
            children: [QuantityCaptureSection(controller: controller, correcting: correcting)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('referencia, aviso de sobreejecución y de ajuste', (tester) async {
    controller.load(_task);
    await pump(tester);
    expect(find.text('Planeado 10 m3 · validado 8 m3'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('quantity_field-c-0')), '3');
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Con lo validado llega a 11 m3 y supera lo planeado (10 m3). Se guardará y la supervisión lo verá marcado.',
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey('quantity_field-c-0')), '-1');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quantity_overrun-c-0')), findsNothing);
    expect(find.byKey(const ValueKey('quantity_adjustment-c-0')), findsOneWidget);
    expect(find.text('Nota (obligatoria)'), findsOneWidget);
  });

  testWidgets('agregar un ítem no planeado desde el buscador', (tester) async {
    controller.load(_task);
    await pump(tester);
    await tester.tap(find.byKey(const Key('quantity_add_unplanned')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quantity_item-item-1')), findsNothing, reason: 'ya está planeado');
    await tester.enterText(find.byKey(const Key('quantity_item_search')), 'acero');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quantity_item-item-2')));
    await tester.pumpAndSettle();
    expect(find.text('2.2 Acero de refuerzo'), findsOneWidget);
    expect(find.text('No planeado en esta tarea'), findsOneWidget);
    expect(find.text('Nota (obligatoria)'), findsOneWidget);
  });

  testWidgets('elegir una ubicación precisada', (tester) async {
    controller.load(_task);
    await pump(tester);
    expect(find.text('La de la tarea (Tramo 2)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('quantity_location-c-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tramo 2 / PR 1').last);
    await tester.pumpAndSettle();
    expect(controller.rows.single.locationId, 'loc-2');
  });

  testWidgets('solo lectura: sin campos editables ni botones', (tester) async {
    controller.load(
      _task,
      stored: [
        {'item_id': 'item-1', 'location_id': null, 'quantity': 2, 'note': '', 'client_id': 'g-1'},
      ],
      readOnly: true,
    );
    await pump(tester);
    expect(find.byKey(const Key('quantity_read_only')), findsOneWidget);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('quantity_field-g-1'))).enabled, isFalse);
    expect(find.byKey(const Key('quantity_add_unplanned')), findsNothing);
    expect(find.byKey(const ValueKey('quantity_add_row-g-1')), findsNothing);
  });

  testWidgets('a 390 px los textos largos no desbordan', (tester) async {
    const long = QuantityItem(
      itemId: 'item-3',
      code: '12.34.56',
      description: 'Suministro, transporte e instalación de tubería de concreto reforzado de 900 mm clase III',
      unit: 'ml',
    );
    controller.load(
      const QuantityTaskContext(
        taskId: 't',
        planned: [PlannedQuantity(item: long, planned: 12345678.1234, validated: 9876543.5)],
        locations: [
          LocationChoice(id: 'a', label: 'Tramo 2', isTaskLocation: true),
          LocationChoice(
            id: 'b',
            label: 'Tramo 2 / PR 12+300 / Costado izquierdo / Carril de desaceleración',
            isTaskLocation: false,
          ),
        ],
      ),
    );
    await pump(tester);
    expect(tester.takeException(), isNull);
  });
}
