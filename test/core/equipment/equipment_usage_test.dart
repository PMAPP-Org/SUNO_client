// Reporte de uso desde campo: validación local, solape, cola idempotente.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/equipment/equipment_manager.dart';
import 'package:visitacampo/core/equipment/equipment_transport.dart';
import 'package:visitacampo/data/local/database.dart';

import 'fake_equipment_transport.dart';

const _id = '11111111-1111-4111-8111-111111111111';
const _north = 'pppppppp-0000-4000-8000-000000000001';
const _south = 'pppppppp-0000-4000-8000-000000000002';

// "Ahora" fijo: 8 de noviembre de 2026, 12:00 hora local.
final _now = DateTime(2026, 11, 8, 12);
final _yesterday = DateTime(2026, 11, 7);
final _today = DateTime(2026, 11, 8);

void main() {
  late AppDatabase db;
  late FakeEquipmentTransport transport;
  late EquipmentManager manager;
  var counter = 0;
  var seeds = 0;

  Future<void> seed({List<Map<String, dynamic>> recent = const [], bool meter = true, List<Map<String, dynamic>>? projects}) async {
    transport.fetches
      ..clear()
      ..add(
        EquipmentFetched(
          version: 'v${seeds++}',
          items: [
            equipment(
              equipmentJson(
                controlScheme: meter ? 'meter' : 'date',
                meterUnits: meter ? const ['hours'] : const [],
                meters: meter ? [meterJson('hours', 500)] : const [],
                usageProjects: projects ?? [usageProjectJson(_north, 'Norte'), usageProjectJson(_south, 'Sur')],
                recentUsage: recent,
              ),
            ),
          ],
        ),
      );
    await manager.refresh();
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeEquipmentTransport();
    counter = 0;
    manager = EquipmentManager(
      db: db,
      transport: transport,
      session: () => (orgId: 'org-1', userId: 'ana'),
      clock: () => _now.toUtc(),
      newId: () => 'usage-${++counter}',
    );
    await seed();
  });
  tearDown(() => db.close());

  Future<UsageOutcome> submit({
    String projectId = _north,
    DateTime? date,
    int start = 8 * 60,
    int end = 12 * 60,
    String activity = 'Excavación de zanja',
    double? startMeter = 500,
    double? endMeter = 504,
  }) => manager.submitUsageReport(
    equipmentId: _id,
    projectId: projectId,
    usageDate: date ?? _yesterday,
    startMinutes: start,
    endMinutes: end,
    activity: activity,
    location: 'Frente 2',
    startMeter: startMeter,
    endMeter: endMeter,
  );

  test('un reporte válido se encola y sale con el mismo id y la fecha como texto', () async {
    final outcome = await submit();

    expect(outcome.id, 'usage-1');
    expect(await manager.pendingUsageCount(), 1);
    expect(await manager.flushUsage(), 1);
    final sent = transport.sentUsage.single;
    expect((sent.id, sent.projectId, sent.usageDate, sent.startMinutes, sent.endMinutes), ('usage-1', _north, '2026-11-07', 480, 720));
    expect((sent.activity, sent.location, sent.startMeter, sent.endMeter), ('Excavación de zanja', 'Frente 2', 500, 504));
    expect(await manager.pendingUsageCount(), 0);
  });

  test('solo se puede reportar a un proyecto de los ofrecidos y con actividad', () async {
    expect((await submit(projectId: 'otro')).problem, UsageProblem.projectMissing);
    expect((await submit(activity: '  ')).problem, UsageProblem.activityRequired);
    await seed(projects: const []);
    expect((await submit()).problem, UsageProblem.projectMissing);
    expect(await manager.pendingUsageCount(), 0);
  });

  test('las horas deben ser coherentes y no estar en el futuro', () async {
    expect((await submit(start: 600, end: 600)).problem, UsageProblem.invalidTimes);
    expect((await submit(start: 700, end: 600)).problem, UsageProblem.invalidTimes);
    expect((await submit(date: _today, start: 13 * 60, end: 14 * 60)).problem, UsageProblem.futureTime);
    expect((await submit(date: DateTime(2026, 11, 9))).problem, UsageProblem.futureTime);
    expect((await submit(date: _today, start: 10 * 60, end: 12 * 60 + 3)).ok, isTrue);
  });

  test('con medidor exige ambas lecturas, ordenadas y sin bajar de la última conocida', () async {
    expect((await submit(startMeter: null, endMeter: null)).problem, UsageProblem.meterRequired);
    expect((await submit(startMeter: 504, endMeter: 500)).problem, UsageProblem.invalidMeter);
    final backwards = await submit(startMeter: 400, endMeter: 410);
    expect((backwards.problem, backwards.detail), (UsageProblem.meterBackwards, '500.0'));
  });

  test('la lectura final de un uso en cola cuenta como última conocida', () async {
    await submit(start: 8 * 60, end: 10 * 60, startMeter: 500, endMeter: 520);
    final next = await submit(start: 13 * 60, end: 15 * 60, startMeter: 510, endMeter: 530);

    expect((next.problem, next.detail), (UsageProblem.meterBackwards, '520.0'));
    expect((await submit(start: 13 * 60, end: 15 * 60, startMeter: 520, endMeter: 530)).ok, isTrue);
  });

  test('un equipo controlado por fecha no pide medidor y no lo guarda', () async {
    await seed(meter: false);

    final outcome = await submit(startMeter: 1, endMeter: 2);
    await manager.flushUsage();

    expect(outcome.ok, isTrue);
    expect((transport.sentUsage.single.startMeter, transport.sentUsage.single.endMeter), (null, null));
  });

  test('no deja cruzar horas con un uso ya reportado ni con uno en cola, pero sí repartir la jornada', () async {
    await seed(recent: [usageJson('u-1', date: '2026-11-07', start: '08:00', end: '12:00', activity: 'Zanja')]);

    final clash = await submit(start: 11 * 60, end: 13 * 60, startMeter: 504, endMeter: 506);
    expect((clash.problem, clash.detail), (UsageProblem.overlap, 'Zanja'));
    expect((await submit(start: 12 * 60, end: 14 * 60, startMeter: 504, endMeter: 506)).ok, isTrue);

    final queuedClash = await submit(start: 13 * 60, end: 15 * 60, startMeter: 506, endMeter: 508);
    expect((queuedClash.problem, queuedClash.detail), (UsageProblem.overlap, 'Excavación de zanja'));
    expect((await submit(date: _today, start: 8 * 60, end: 10 * 60, startMeter: 506, endMeter: 508)).ok, isTrue);
  });

  test('un uso cancelado no estorba', () async {
    await seed(recent: [usageJson('u-1', date: '2026-11-07', start: '08:00', end: '12:00', status: 'cancelled')]);

    expect((await submit()).ok, isTrue);
  });

  test('sin red se reintenta con el mismo id; el rechazo del servidor no se reintenta', () async {
    await submit();
    transport.usageResult = const ReadingSendResult(ReadingSendStatus.retry);
    expect(await manager.flushUsage(), 0);
    expect(await manager.pendingUsageCount(), 1);

    transport.usageResult = const ReadingSendResult(ReadingSendStatus.rejected, message: 'El operador no está asignado');
    await manager.flushUsage();
    expect(await manager.pendingUsageCount(), 0);
    final pending = (await manager.pendingUsageFor(_id)).single;
    expect((pending.rejected, pending.lastError, pending.usageDate), (true, 'El operador no está asignado', _yesterday));

    transport.sentUsage.clear();
    await manager.flushUsage();
    expect(transport.sentUsage, isEmpty);
    await manager.dismissRejectedUsage(pending.id);
    expect(await manager.pendingUsageFor(_id), isEmpty);
  });

  test('envía en orden cronológico y se detiene en el primer error de red', () async {
    await submit(date: _today, start: 8 * 60, end: 10 * 60, startMeter: 500, endMeter: 510);
    await submit(start: 8 * 60, end: 10 * 60, startMeter: 510, endMeter: 520);
    transport.usageResult = const ReadingSendResult(ReadingSendStatus.retry);

    await manager.flushUsage();

    expect([for (final r in transport.sentUsage) r.usageDate], ['2026-11-07']);
  });

  test('solo envía los reportes de quien tiene la sesión', () async {
    await submit();
    final other = EquipmentManager(db: db, transport: transport, session: () => (orgId: 'org-1', userId: 'beto'));

    expect(await other.flushUsage(), 0);
    expect(transport.sentUsage, isEmpty);
  });

  test('sync envía el reporte antes de traer la lista', () async {
    await submit();
    await seed(recent: [usageJson('u-9', date: '2026-11-07')]);

    await manager.sync();

    expect(transport.sentUsage, hasLength(1));
    expect((await manager.byId(_id))!.recentUsage.single.id, 'u-9');
  });

  test('la ficha trae proyectos y últimos usos', () async {
    await seed(recent: [usageJson('u-1', hours: 4.5, activity: 'Nivelación', project: 'Sur')]);

    final item = (await manager.byId(_id))!;

    expect([for (final p in item.usageProjects) p.name], ['Norte', 'Sur']);
    final usage = item.recentUsage.single;
    expect((usage.activity, usage.hours, usage.projectName, usage.startMinutes, usage.endMinutes), ('Nivelación', 4.5, 'Sur', 480, 720));
    expect(usage.usageDate, DateTime(2026, 11, 7));
  });
}
