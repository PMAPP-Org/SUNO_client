// Tareas del cronograma (costos, etapa 1): la lista se reemplaza entera cuando
// cambia, "sin cambios" no toca nada y sin red se conserva la anterior.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/auth/auth_models.dart';
import 'package:suno/core/schedule/schedule_task_sync.dart';
import 'package:suno/data/local/database.dart';
import 'package:suno/data/local/schedule_task_repository.dart';

import 'fake_schedule_task_transport.dart';

const _ana = UserProfile(id: 'ana', username: 'ana', orgId: 'org-1', roles: ['FIELD_AGENT']);
const _beto = UserProfile(id: 'beto', username: 'beto', orgId: 'org-1', roles: ['FIELD_AGENT']);

ScheduleTaskInfo _task(String id, String wbs, String name, {double? pct}) => ScheduleTaskInfo(
  id: id,
  projectId: 'p-1',
  projectName: 'Obra Norte',
  wbs: wbs,
  outlineNumber: wbs,
  name: name,
  lastValidatedPct: pct,
);

ScheduleTaskPage _page(String version, List<ScheduleTaskInfo> items) =>
    ScheduleTaskPage(version: version, changed: true, items: items);

const _unchanged = ScheduleTaskPage(version: 'v1', changed: false, items: []);

void main() {
  late AppDatabase db;
  late FakeScheduleTaskTransport transport;
  late ScheduleTaskSync sync;
  UserProfile? current;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeScheduleTaskTransport();
    current = _ana;
    sync = ScheduleTaskSync(
      db: db,
      transport: transport,
      currentUser: () => current,
      clock: () => DateTime.utc(2026, 11, 2),
    );
  });
  tearDown(() => db.close());

  Future<List<String>> labels(UserProfile user) async => [
    for (final t in await ScheduleTaskRepository(db).forUser(orgId: user.orgId, userId: user.id)) t.label,
  ];

  test('primera descarga: guarda la lista en orden, con su versión', () async {
    transport.responses.add(
      _page('v1', [_task('t-2', '1.1', 'Localización'), _task('t-3', '1.2', 'Descapote', pct: 40)]),
    );
    expect(await sync.refresh(), isTrue);
    expect(transport.versions, [null]);
    expect(await labels(_ana), ['1.1 Localización', '1.2 Descapote']);
    final items = await ScheduleTaskRepository(db).forUser(orgId: 'org-1', userId: 'ana');
    expect(items.last.lastValidatedPct, 40);
    expect((await db.readScheduleTaskState())!.version, 'v1');
  });

  test('sin cambios: envía la versión y no toca la lista', () async {
    transport.responses
      ..add(_page('v1', [_task('t-2', '1.1', 'Localización')]))
      ..add(_unchanged);
    await sync.refresh();
    expect(await sync.refresh(), isTrue);
    expect(transport.versions, [null, 'v1']);
    expect(await labels(_ana), ['1.1 Localización']);
  });

  test('lo que deja de venir desaparece (tarea retirada o responsabilidad quitada)', () async {
    transport.responses
      ..add(_page('v1', [_task('t-2', '1.1', 'Localización'), _task('t-5', '2.1', 'Columnas')]))
      ..add(_page('v2', [_task('t-2', '1.1', 'Localización (replanteo)')]));
    await sync.refresh();
    await sync.refresh();
    expect(await labels(_ana), ['1.1 Localización (replanteo)']);
  });

  test('sin red no se toca nada', () async {
    transport.responses
      ..add(_page('v1', [_task('t-2', '1.1', 'Localización')]))
      ..add(null);
    await sync.refresh();
    expect(await sync.refresh(), isFalse);
    expect(await labels(_ana), ['1.1 Localización']);
  });

  test('otro usuario en el mismo teléfono pide la lista completa', () async {
    transport.responses
      ..add(_page('v1', [_task('t-2', '1.1', 'Localización')]))
      ..add(_page('v9', [_task('t-6', '2.2', 'Fin de obra')]));
    await sync.refresh();
    current = _beto;
    expect(await labels(_beto), isEmpty, reason: 'la lista guardada es de ana');
    await sync.refresh();
    expect(transport.versions, [null, null]);
    expect(await labels(_beto), ['2.2 Fin de obra']);
    expect(await labels(_ana), isEmpty);
  });

  test('sin sesión no pide nada', () async {
    current = null;
    expect(await sync.refresh(), isFalse);
    expect(transport.versions, isEmpty);
  });

  test('"sin cambios" sin versión enviada no reemplaza nada y no da la lista por vigente', () async {
    transport.responses.add(_page('v1', [_task('t-2', '1.1', 'Localización')]));
    await sync.refresh();
    current = _beto; // su versión no es la de Ana: no se envía ninguna
    transport.responses.add(_unchanged);

    expect(await sync.refresh(), isFalse);
    expect(transport.versions.last, isNull);
    expect(await labels(_ana), ['1.1 Localización']);
  });

  group('costos, pieza 4b', () {
    ScheduleTaskPage measuredPage() => ScheduleTaskPage.fromJson({
      'version': 'v2',
      'changed': true,
      'items': [
        {
          'id': 't-3',
          'project_id': 'p-1',
          'project_name': 'Obra Norte',
          'wbs': '1.2',
          'outline_number': '1.2',
          'name': 'Descapote',
          'last_validated_pct': 40,
          'measured_by': 'quantities',
          'location': {'id': 'loc-1', 'label': 'Tramo 2'},
          'location_options': [
            {'id': 'loc-1', 'label': 'Tramo 2'},
            {'id': 'loc-2', 'label': 'Tramo 2 / PR 1'},
          ],
          'planned_items': [
            {
              'item_id': 'item-1',
              'code': '2.1',
              'description': 'Concreto zapatas',
              'unit': 'm3',
              'planned_quantity': 10,
              'executed_quantity': 4.5,
            },
          ],
        },
      ],
      'project_items': [
        {
          'project_id': 'p-1',
          'items': [
            {'item_id': 'item-1', 'code': '2.1', 'description': 'Concreto zapatas', 'unit': 'm3'},
            {'item_id': 'item-2', 'code': '2.2', 'description': 'Acero de refuerzo', 'unit': 'kg'},
          ],
        },
      ],
    });

    test('guarda cómo se mide la tarea, sus ítems, sus ubicaciones y el catálogo', () async {
      transport.responses.add(measuredPage());
      expect(await sync.refresh(), isTrue);
      final repo = ScheduleTaskRepository(db);
      final task = (await repo.forUser(orgId: 'org-1', userId: 'ana')).single;
      expect((task.projectId, task.measuredBy, task.measuredByQuantities), ('p-1', 'quantities', true));

      final context = await repo.quantityContext(taskId: 't-3', projectId: 'p-1');
      expect(context.planned.single.item.label, '2.1 Concreto zapatas');
      expect((context.planned.single.planned, context.planned.single.validated), (10.0, 4.5));
      expect(context.taskLocation?.label, 'Tramo 2');
      expect([for (final l in context.refinements) l.label], ['Tramo 2 / PR 1']);
      expect([for (final i in context.catalog) i.code], ['2.1', '2.2']);
      expect([for (final i in context.unplannedCatalog) i.code], ['2.2']);
      expect((await repo.knownItems({'item-2'}))['item-2']?.unit, 'kg');
      expect(await repo.locationLabels({'loc-2', 'loc-9'}), {'loc-2': 'Tramo 2 / PR 1'});
    });

    test('los ítems conocidos sobreviven a un catálogo nuevo', () async {
      transport.responses
        ..add(measuredPage())
        ..add(_page('v3', [_task('t-3', '1.2', 'Descapote')]));
      await sync.refresh();
      await sync.refresh();
      final repo = ScheduleTaskRepository(db);
      expect((await repo.quantityContext(taskId: 't-3', projectId: 'p-1')).catalog, isEmpty);
      expect((await repo.knownItems({'item-1'}))['item-1']?.code, '2.1');
    });

    test('una tarea sin las claves nuevas se mide por %', () async {
      transport.responses.add(_page('v1', [_task('t-2', '1.1', 'Localización')]));
      await sync.refresh();
      final task = (await ScheduleTaskRepository(db).forUser(orgId: 'org-1', userId: 'ana')).single;
      expect(task.measuredBy, 'pct');
      expect(await ScheduleTaskRepository(db).byId('t-2'), isNotNull);
    });
  });
}
