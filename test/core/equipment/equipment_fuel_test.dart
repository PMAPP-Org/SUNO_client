// Combustibles (M&E fase 4): catálogo en caché, validación local y cola idempotente.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/equipment/equipment_manager.dart';
import 'package:suno/core/equipment/equipment_models.dart';
import 'package:suno/core/equipment/equipment_transport.dart';
import 'package:suno/data/local/database.dart';

import 'fake_equipment_transport.dart';

const _id = '11111111-1111-4111-8111-111111111111';
const _north = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _tank = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

FuelCatalogFetched _catalog({String version = 'c1'}) => FuelCatalogFetched(
  version: version,
  catalog: FuelCatalogInfo.fromJson({
    'stations': [
      {'id': _north, 'name': 'Norte', 'supplier': 'Terpel'},
    ],
    'stores': [
      {'id': _tank, 'name': 'Tanque 1'},
    ],
  }),
);

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
      newId: () => 'fill-${++counter}',
    );
    transport.fetches.add(
      EquipmentFetched(
        version: 'v1',
        items: [
          equipment(equipmentJson(meterUnits: const ['kilometers'], meters: [meterJson('kilometers', 1000)])),
        ],
      ),
    );
    await manager.refresh();
    transport.catalogFetches.add(_catalog());
    await manager.refreshFuelCatalog();
  });
  tearDown(() => db.close());

  Future<FuelOutcome> submit({
    FuelSource source = FuelSource.station,
    String? stationId = _north,
    String? storeId,
    String voucher = 'V-1',
    double gallons = 25.5,
    double? meter = 1100,
  }) => manager.submitFuelFill(
    equipmentId: _id,
    source: source,
    stationId: stationId,
    storeId: storeId,
    voucherNumber: voucher,
    gallons: gallons,
    meterValue: meter,
    driverName: 'Pedro',
  );

  group('catálogo', () {
    test('se guarda y se consulta sin red', () async {
      final catalog = await manager.fuelCatalog();

      expect([for (final s in catalog.stations) '${s.supplier} · ${s.name}'], ['Terpel · Norte']);
      expect([for (final s in catalog.stores) s.name], ['Tanque 1']);
    });

    test('envía la última version, "sin cambios" lo conserva y un fallo no lo toca', () async {
      transport.catalogFetches
        ..clear()
        ..add(const FuelCatalogUnchanged());
      expect(await manager.refreshFuelCatalog(), isTrue);
      expect(transport.catalogVersionsAsked.last, 'c1');

      transport.catalogFetches
        ..clear()
        ..add(const FuelCatalogFailed());
      expect(await manager.refreshFuelCatalog(), isFalse);
      expect((await manager.fuelCatalog()).stations, hasLength(1));
    });

    test('con otra organización no reutiliza la version y sin sesión no pide nada', () async {
      final other = EquipmentManager(db: db, transport: transport, session: () => (orgId: 'org-2', userId: 'beto'));
      transport.catalogFetches
        ..clear()
        ..add(_catalog(version: 'c2'));
      await other.refreshFuelCatalog();
      expect(transport.catalogVersionsAsked.last, isNull);

      final anonymous = EquipmentManager(db: db, transport: transport, session: () => null);
      expect(await anonymous.refreshFuelCatalog(), isFalse);
    });

    test('sin catálogo guardado está vacío', () async {
      final fresh = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(fresh.close);

      expect((await EquipmentManager(db: fresh, transport: transport, session: () => null).fuelCatalog()).isEmpty, isTrue);
    });
  });

  group('tanqueo', () {
    test('uno válido se encola y sale con el mismo id', () async {
      final outcome = await submit();

      expect(outcome.id, 'fill-1');
      expect(await manager.pendingFuelFillCount(), 1);
      expect(await manager.flushFuelFills(), 1);
      final sent = transport.sentFuelFills.single;
      expect((sent.id, sent.source, sent.stationId, sent.storeId), ('fill-1', FuelSource.station, _north, null));
      expect((sent.gallons, sent.meterUnit, sent.meterValue, sent.driverName), (25.5, MeterUnit.kilometers, 1100, 'Pedro'));
      expect(await manager.pendingFuelFillCount(), 0);
    });

    test('una salida del tanque propio lleva el tanque y no la estación', () async {
      await submit(source: FuelSource.store, stationId: null, storeId: _tank);
      await manager.flushFuelFills();

      final sent = transport.sentFuelFills.single;
      expect((sent.source, sent.stationId, sent.storeId), (FuelSource.store, null, _tank));
    });

    test('exige un origen del catálogo, vale, galones y lectura del medidor', () async {
      expect((await submit(stationId: null)).problem, FuelProblem.sourceMissing);
      expect((await submit(stationId: 'otra-estacion')).problem, FuelProblem.sourceMissing);
      expect((await submit(source: FuelSource.store, stationId: null)).problem, FuelProblem.sourceMissing);
      expect((await submit(voucher: '  ')).problem, FuelProblem.voucherRequired);
      expect((await submit(gallons: 0)).problem, FuelProblem.invalidGallons);
      expect((await submit(gallons: double.nan)).problem, FuelProblem.invalidGallons);
      expect((await submit(meter: null)).problem, FuelProblem.meterRequired);
      expect((await submit(meter: -1)).problem, FuelProblem.invalidMeter);
      expect(await manager.pendingFuelFillCount(), 0);
    });

    test('la lectura no baja respecto de la caché ni de otro tanqueo en cola', () async {
      final backwards = await submit(meter: 900);
      expect((backwards.problem, backwards.detail), (FuelProblem.meterBackwards, '1000.0'));

      await submit(voucher: 'V-1', meter: 1200);
      final again = await submit(voucher: 'V-2', meter: 1150);
      expect((again.problem, again.detail), (FuelProblem.meterBackwards, '1200.0'));
    });

    test('un equipo desconocido o sin sesión se rechaza', () async {
      final unknown = await manager.submitFuelFill(
        equipmentId: 'otro',
        source: FuelSource.station,
        stationId: _north,
        voucherNumber: 'V-1',
        gallons: 5,
        meterValue: 1,
      );
      expect(unknown.problem, FuelProblem.equipmentNotFound);
    });

    test('sin red se reintenta con el mismo id; el rechazo del servidor no se reintenta', () async {
      await submit();
      transport.fuelFillResult = const ReadingSendResult(ReadingSendStatus.retry);
      expect(await manager.flushFuelFills(), 0);
      expect(await manager.pendingFuelFillCount(), 1);

      transport.fuelFillResult = const ReadingSendResult(ReadingSendStatus.rejected, message: 'Ese vale ya fue registrado');
      await manager.flushFuelFills();
      expect(await manager.pendingFuelFillCount(), 0);
      final pending = (await manager.pendingFuelFillsFor(_id)).single;
      expect((pending.rejected, pending.lastError, pending.voucherNumber), (true, 'Ese vale ya fue registrado', 'V-1'));

      transport.sentFuelFills.clear();
      await manager.flushFuelFills();
      expect(transport.sentFuelFills, isEmpty);
      await manager.dismissRejectedFuelFill(pending.id);
      expect(await manager.pendingFuelFillsFor(_id), isEmpty);
    });

    test('envía en orden cronológico y se detiene en el primer error de red', () async {
      await manager.submitFuelFill(
        equipmentId: _id,
        source: FuelSource.station,
        stationId: _north,
        voucherNumber: 'V-1',
        gallons: 10,
        meterValue: 1100,
        filledAt: DateTime.utc(2026, 11, 8, 9),
      );
      await manager.submitFuelFill(
        equipmentId: _id,
        source: FuelSource.station,
        stationId: _north,
        voucherNumber: 'V-2',
        gallons: 10,
        meterValue: 1200,
        filledAt: DateTime.utc(2026, 11, 8, 10),
      );
      transport.fuelFillResult = const ReadingSendResult(ReadingSendStatus.retry);

      await manager.flushFuelFills();

      expect([for (final f in transport.sentFuelFills) f.voucherNumber], ['V-1']);
      transport.fuelFillResult = const ReadingSendResult(ReadingSendStatus.sent);
      transport.sentFuelFills.clear();
      await manager.flushFuelFills();
      expect([for (final f in transport.sentFuelFills) f.voucherNumber], ['V-1', 'V-2']);
    });

    test('solo envía los tanqueos de quien tiene la sesión', () async {
      await submit();
      final other = EquipmentManager(db: db, transport: transport, session: () => (orgId: 'org-1', userId: 'beto'));

      expect(await other.flushFuelFills(), 0);
      expect(transport.sentFuelFills, isEmpty);
    });

    test('sync envía el tanqueo y luego refresca el catálogo y la lista', () async {
      await submit();
      transport.catalogFetches
        ..clear()
        ..add(_catalog(version: 'c9'));

      await manager.sync();

      expect(transport.sentFuelFills, hasLength(1));
      expect(transport.catalogVersionsAsked.last, 'c1');
    });
  });
}
