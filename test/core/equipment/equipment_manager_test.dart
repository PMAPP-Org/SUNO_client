// Maquinaria y equipos (fase 1): caché de la lista, búsqueda por QR y cola de
// lecturas de medidor con envío idempotente.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/equipment/equipment_manager.dart';
import 'package:visitacampo/core/equipment/equipment_models.dart';
import 'package:visitacampo/core/equipment/equipment_transport.dart';
import 'package:visitacampo/data/local/database.dart';

import 'fake_equipment_transport.dart';

const _volqueta = '11111111-1111-4111-8111-111111111111';
const _cargador = '33333333-3333-4333-8333-333333333333';

void main() {
  late AppDatabase db;
  late FakeEquipmentTransport transport;
  late EquipmentManager manager;
  ({String orgId, String userId})? who;
  var counter = 0;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeEquipmentTransport();
    who = (orgId: 'org-1', userId: 'ana');
    counter = 0;
    manager = EquipmentManager(
      db: db,
      transport: transport,
      session: () => who,
      clock: () => DateTime.utc(2026, 11, 8, 12),
      newId: () => 'reading-${++counter}',
    );
  });
  tearDown(() => db.close());

  EquipmentFetched fetched(List<Map<String, dynamic>> items, {String version = 'v1'}) =>
      EquipmentFetched(version: version, items: [for (final item in items) equipment(item)]);

  group('lista', () {
    test('refresh guarda la lista y se consulta sin red, ordenada por código', () async {
      transport.fetches.add(
        fetched([
          equipmentJson(id: _cargador, code: 'EQ-2', name: 'Cargador', plate: ''),
          equipmentJson(),
        ]),
      );

      expect(await manager.refresh(), isTrue);
      transport.fetches
        ..clear()
        ..add(const EquipmentFetchFailed());

      expect([for (final e in await manager.list()) e.code], ['EQ-1', 'EQ-2']);
      expect((await manager.byId(_volqueta))!.departmentLabel, 'CC-1 · Maquinaria Norte');
    });

    test('envía la última version y "sin cambios" conserva la caché', () async {
      transport.fetches.add(fetched([equipmentJson()], version: 'huella-7'));
      await manager.refresh();

      transport.fetches
        ..clear()
        ..add(const EquipmentUnchanged());
      expect(await manager.refresh(), isTrue);

      expect(transport.versionsAsked, [null, 'huella-7']);
      expect(await manager.list(), hasLength(1));
    });

    test('una lista nueva reemplaza a la anterior: el equipo que ya no es visible desaparece', () async {
      transport.fetches.add(fetched([equipmentJson(), equipmentJson(id: _cargador, code: 'EQ-2')]));
      await manager.refresh();
      transport.fetches
        ..clear()
        ..add(fetched([equipmentJson()], version: 'v2'));

      await manager.refresh();

      expect([for (final e in await manager.list()) e.code], ['EQ-1']);
    });

    test('sin red o sin sesión no toca la caché', () async {
      transport.fetches.add(fetched([equipmentJson()]));
      await manager.refresh();

      transport.fetches
        ..clear()
        ..add(const EquipmentFetchFailed());
      expect(await manager.refresh(), isFalse);
      expect(await manager.list(), hasLength(1));

      who = null;
      expect(await manager.refresh(), isFalse);
    });

    test('con otra organización la version guardada no se reutiliza', () async {
      transport.fetches.add(fetched([equipmentJson()], version: 'huella-org-1'));
      await manager.refresh();
      who = (orgId: 'org-2', userId: 'beto');

      await manager.refresh();

      expect(transport.versionsAsked.last, isNull);
    });
  });

  group('QR y búsqueda', () {
    setUp(() async {
      transport.fetches.add(fetched([equipmentJson()]));
      await manager.refresh();
    });

    test('lee el id de suno:eq:<uuid> aunque el QR traiga más líneas', () async {
      final scan = 'suno:eq:${_volqueta.toUpperCase()}\nVolqueta 1\nCAT 740';

      expect(EquipmentManager.parseQr(scan), _volqueta);
      expect((await manager.findByScan(scan))!.code, 'EQ-1');
    });

    test('un QR ajeno o un uuid mal formado no resuelve nada', () async {
      expect(EquipmentManager.parseQr('https://ejemplo.co'), isNull);
      expect(EquipmentManager.parseQr('suno:eq:no-es-un-uuid'), isNull);
      expect(await manager.findByScan('suno:eq:$_cargador'), isNull);
    });

    test('también encuentra por código o placa, sin distinguir mayúsculas', () async {
      expect((await manager.findByScan('eq-1'))!.id, _volqueta);
      expect((await manager.findByScan(' exg871 '))!.id, _volqueta);
      expect(await manager.findByScan('otro'), isNull);
      expect(await manager.findByScan('   '), isNull);
    });
  });

  group('lecturas de medidor', () {
    setUp(() async {
      transport.fetches.add(fetched([equipmentJson(meters: [meterJson('hours', 339)])]));
      await manager.refresh();
    });

    test('una lectura válida se encola y sale en el siguiente envío', () async {
      final outcome = await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: 345.5);

      expect(outcome.ok, isTrue);
      expect(await manager.pendingCount(), 1);
      expect(await manager.flushReadings(), 1);
      expect(transport.sent.single.id, 'reading-1');
      expect(transport.sent.single.value, 345.5);
      expect(await manager.pendingCount(), 0);
    });

    test('no deja bajar el medidor respecto de la caché ni de lo ya encolado', () async {
      final backwards = await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: 100);
      expect(backwards.problem, ReadingProblem.backwards);
      expect(backwards.baseline, 339);

      await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: 400);
      final again = await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: 399);
      expect(again.problem, ReadingProblem.backwards);
      expect(again.baseline, 400);
    });

    test('rechaza medidor no configurado, valor inválido y equipo desconocido', () async {
      transport.fetches
        ..clear()
        ..add(fetched([equipmentJson(meterUnits: const ['hours'])], version: 'v2'));
      await manager.refresh();

      expect(
        (await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.kilometers, value: 1)).problem,
        ReadingProblem.unitNotConfigured,
      );
      expect(
        (await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: -1)).problem,
        ReadingProblem.invalidValue,
      );
      expect(
        (await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: double.nan)).problem,
        ReadingProblem.invalidValue,
      );
      expect(
        (await manager.recordReading(equipmentId: _cargador, unit: MeterUnit.hours, value: 1)).problem,
        ReadingProblem.equipmentNotFound,
      );
      expect(await manager.pendingCount(), 0);
    });

    test('sin red la lectura se queda en cola y se reintenta con el mismo id', () async {
      await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: 350);
      transport.sendResult = const ReadingSendResult(ReadingSendStatus.retry, message: 'connectionError');

      expect(await manager.flushReadings(), 0);
      expect(await manager.pendingCount(), 1);

      transport.sendResult = const ReadingSendResult(ReadingSendStatus.sent);
      expect(await manager.flushReadings(), 1);
      expect([for (final r in transport.sent) r.id], ['reading-1', 'reading-1']);
    });

    test('el primer error de red detiene el envío del resto', () async {
      await manager.recordReading(
        equipmentId: _volqueta,
        unit: MeterUnit.hours,
        value: 350,
        readAt: DateTime.utc(2026, 11, 8, 9),
      );
      await manager.recordReading(
        equipmentId: _volqueta,
        unit: MeterUnit.hours,
        value: 360,
        readAt: DateTime.utc(2026, 11, 8, 10),
      );
      transport.sendResult = const ReadingSendResult(ReadingSendStatus.retry);

      await manager.flushReadings();

      expect(transport.sent, hasLength(1));
      expect(transport.sent.single.value, 350, reason: 'se envía en orden cronológico');
    });

    test('una lectura rechazada por el servidor no se reintenta y se puede descartar', () async {
      await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: 350);
      transport.sendResult = const ReadingSendResult(ReadingSendStatus.rejected, message: 'La lectura retrocede');

      expect(await manager.flushReadings(), 0);
      expect(await manager.pendingCount(), 0);
      final pending = (await manager.pendingFor(_volqueta)).single;
      expect((pending.rejected, pending.lastError), (true, 'La lectura retrocede'));

      transport.sent.clear();
      await manager.flushReadings();
      expect(transport.sent, isEmpty);

      await manager.dismissRejected(pending.id);
      expect(await manager.pendingFor(_volqueta), isEmpty);
    });

    test('solo envía las lecturas del usuario con sesión', () async {
      await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: 350);
      who = (orgId: 'org-1', userId: 'beto');

      expect(await manager.flushReadings(), 0);
      expect(transport.sent, isEmpty);
    });

    test('sync envía primero lo de campo y luego trae la lista actualizada', () async {
      await manager.recordReading(equipmentId: _volqueta, unit: MeterUnit.hours, value: 350);
      transport.fetches
        ..clear()
        ..add(fetched([equipmentJson(meters: [meterJson('hours', 350)])], version: 'v2'));

      await manager.sync();

      expect(transport.sent, hasLength(1));
      expect((await manager.byId(_volqueta))!.meter(MeterUnit.hours)!.value, 350);
    });
  });
}
