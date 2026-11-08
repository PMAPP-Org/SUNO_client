// Preoperacional (M&E fase 2): validación local, cola idempotente y estados.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/equipment/equipment_manager.dart';
import 'package:visitacampo/core/equipment/equipment_models.dart';
import 'package:visitacampo/core/equipment/equipment_transport.dart';
import 'package:visitacampo/data/local/database.dart';

import 'fake_equipment_transport.dart';

const _id = '11111111-1111-4111-8111-111111111111';
const _brakes = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _lights = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

void main() {
  late AppDatabase db;
  late FakeEquipmentTransport transport;
  late EquipmentManager manager;
  var counter = 0;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeEquipmentTransport();
    counter = 0;
    manager = EquipmentManager(
      db: db,
      transport: transport,
      session: () => (orgId: 'org-1', userId: 'ana'),
      clock: () => DateTime.utc(2026, 11, 8, 12),
      newId: () => 'insp-${++counter}',
    );
    transport.fetches.add(
      EquipmentFetched(
        version: 'v1',
        items: [
          equipment(
            equipmentJson(
              meters: [meterJson('hours', 339)],
              checklist: [checklistItemJson(_brakes, 'Frenos', critical: true), checklistItemJson(_lights, 'Luces')],
              recentInspections: [inspectionSummaryJson('old', status: 'rejected', comment: 'Foto ilegible')],
            ),
          ),
        ],
      ),
    );
    await manager.refresh();
  });
  tearDown(() => db.close());

  List<InspectionAnswer> answers({bool brakesOk = true, String brakesNote = ''}) => [
    InspectionAnswer(itemId: _brakes, ok: brakesOk, note: brakesNote),
    const InspectionAnswer(itemId: _lights, ok: true),
  ];

  test('la ficha trae la lista de chequeo y el estado de las últimas revisiones', () async {
    final item = (await manager.byId(_id))!;

    expect([for (final c in item.checklist) (c.label, c.critical)], [('Frenos', true), ('Luces', false)]);
    expect(item.recentInspections.single.status, InspectionStatus.rejected);
    expect(item.recentInspections.single.reviewComment, 'Foto ilegible');
    expect(item.needsMeterForInspection, isTrue);
  });

  test('una inspección completa se encola con su snapshot y sale con el mismo id', () async {
    final outcome = await manager.submitInspection(equipmentId: _id, answers: answers(), meterValue: 345);

    expect(outcome.id, 'insp-1');
    expect(await manager.pendingInspectionCount(), 1);
    expect(await manager.flushInspections(), 1);
    final sent = transport.sentInspections.single;
    expect((sent.id, sent.meterUnit, sent.meterValue), ('insp-1', MeterUnit.hours, 345));
    expect([for (final i in sent.items) (i.itemId, i.ok)], [(_brakes, true), (_lights, true)]);
    expect(await manager.pendingInspectionCount(), 0);
  });

  test('exige todos los ítems, la descripción de cada novedad y la lectura inicial', () async {
    final incomplete = await manager.submitInspection(
      equipmentId: _id,
      answers: [InspectionAnswer(itemId: _brakes, ok: true)],
      meterValue: 345,
    );
    expect((incomplete.problem, incomplete.detail), (InspectionProblem.incomplete, 'Luces'));

    final noNote = await manager.submitInspection(
      equipmentId: _id,
      answers: answers(brakesOk: false, brakesNote: '  '),
      meterValue: 345,
    );
    expect((noNote.problem, noNote.detail), (InspectionProblem.faultWithoutNote, 'Frenos'));

    expect(
      (await manager.submitInspection(equipmentId: _id, answers: answers())).problem,
      InspectionProblem.meterRequired,
    );
    expect(
      (await manager.submitInspection(equipmentId: _id, answers: answers(), meterValue: -1)).problem,
      InspectionProblem.invalidMeter,
    );
    expect(await manager.pendingInspectionCount(), 0);
  });

  test('la lectura inicial no puede bajar respecto de la última conocida', () async {
    final outcome = await manager.submitInspection(equipmentId: _id, answers: answers(), meterValue: 100);

    expect((outcome.problem, outcome.detail), (InspectionProblem.meterBackwards, '339.0'));
  });

  test('una novedad queda marcada y el equipo sin lista de chequeo no inspecciona', () async {
    await manager.submitInspection(
      equipmentId: _id,
      answers: answers(brakesOk: false, brakesNote: 'Pedal blando'),
      meterValue: 345,
    );
    expect((await manager.pendingInspectionsFor(_id)).single.hasFaults, isTrue);

    transport.fetches
      ..clear()
      ..add(EquipmentFetched(version: 'v2', items: [equipment(equipmentJson())]));
    await manager.refresh();
    expect(
      (await manager.submitInspection(equipmentId: _id, answers: const [], meterValue: 400)).problem,
      InspectionProblem.noChecklist,
    );
  });

  test('un equipo controlado por fecha no pide medidor', () async {
    transport.fetches
      ..clear()
      ..add(
        EquipmentFetched(
          version: 'v2',
          items: [
            equipment(
              equipmentJson(
                controlScheme: 'date',
                meterUnits: const [],
                checklist: [checklistItemJson(_brakes, 'Frenos'), checklistItemJson(_lights, 'Luces')],
              ),
            ),
          ],
        ),
      );
    await manager.refresh();

    final outcome = await manager.submitInspection(equipmentId: _id, answers: answers());
    await manager.flushInspections();

    expect(outcome.ok, isTrue);
    expect((transport.sentInspections.single.meterUnit, transport.sentInspections.single.meterValue), (null, null));
  });

  test('sin red se reintenta con el mismo id; el rechazo del servidor no se reintenta', () async {
    await manager.submitInspection(equipmentId: _id, answers: answers(), meterValue: 345);
    transport.inspectionResult = const ReadingSendResult(ReadingSendStatus.retry);
    expect(await manager.flushInspections(), 0);
    expect(await manager.pendingInspectionCount(), 1);

    transport.inspectionResult = const ReadingSendResult(ReadingSendStatus.rejected, message: 'Faltan ítems');
    await manager.flushInspections();
    expect(await manager.pendingInspectionCount(), 0);
    final pending = (await manager.pendingInspectionsFor(_id)).single;
    expect((pending.rejected, pending.lastError), (true, 'Faltan ítems'));

    transport.sentInspections.clear();
    await manager.flushInspections();
    expect(transport.sentInspections, isEmpty);
    await manager.dismissRejectedInspection(pending.id);
    expect(await manager.pendingInspectionsFor(_id), isEmpty);
  });

  test('solo envía los preoperacionales de quien tiene la sesión', () async {
    await manager.submitInspection(equipmentId: _id, answers: answers(), meterValue: 345);
    final other = EquipmentManager(db: db, transport: transport, session: () => (orgId: 'org-1', userId: 'beto'));

    expect(await other.flushInspections(), 0);
    expect(transport.sentInspections, isEmpty);
  });

  test('sync envía lecturas y preoperacionales antes de traer la lista', () async {
    await manager.submitInspection(equipmentId: _id, answers: answers(), meterValue: 345);
    transport.fetches
      ..clear()
      ..add(
        EquipmentFetched(
          version: 'v2',
          items: [
            equipment(
              equipmentJson(
                checklist: [checklistItemJson(_brakes, 'Frenos')],
                recentInspections: [inspectionSummaryJson('insp-1')],
              ),
            ),
          ],
        ),
      );

    await manager.sync();

    expect(transport.sentInspections, hasLength(1));
    expect((await manager.byId(_id))!.recentInspections.single.id, 'insp-1');
  });

  test('el JSON de ítems guardado conserva el orden de la lista', () async {
    await manager.submitInspection(equipmentId: _id, answers: answers().reversed.toList(), meterValue: 345);

    final row = await db.select(db.inspectionOutbox).getSingle();
    expect([for (final i in jsonDecode(row.itemsJson) as List<dynamic>) (i as Map)['item_id']], [_brakes, _lights]);
  });
}
