// Transporte de materiales (M&E fase 5): catálogo en caché, validación local y cola idempotente.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/equipment/equipment_manager.dart';
import 'package:visitacampo/core/equipment/equipment_models.dart';
import 'package:visitacampo/core/equipment/equipment_transport.dart';
import 'package:visitacampo/data/local/database.dart';

import 'fake_equipment_transport.dart';

const _id = '11111111-1111-4111-8111-111111111111';
const _route = 'rrrrrrrr-0000-4000-8000-000000000001';
const _material = 'mmmmmmmm-0000-4000-8000-000000000001';
const _truck = 'vvvvvvvv-0000-4000-8000-000000000001';
const _noCapacity = 'vvvvvvvv-0000-4000-8000-000000000002';
const _ana = 'pppppppp-0000-4000-8000-00000000000a';
const _beto = 'pppppppp-0000-4000-8000-00000000000b';
const _carla = 'pppppppp-0000-4000-8000-00000000000c';

TransportCatalogFetched _catalog({String version = 't1'}) => TransportCatalogFetched(
  version: version,
  catalog: TransportCatalogInfo.fromJson({
    'routes': [
      {'id': _route, 'origin': 'Cantera', 'destination': 'Km 12', 'zone': 'Oriente', 'distance_km': 8.5},
    ],
    'materials': [
      {'id': _material, 'name': 'Gravas'},
    ],
    'vehicles': [
      {'id': _truck, 'plate': 'EXG871', 'contractor': 'Transportes TDR', 'capacity_m3': 14.0},
      {'id': _noCapacity, 'plate': 'ABC123', 'contractor': 'Otra', 'capacity_m3': null},
    ],
    'people': [
      {'id': _ana, 'name': 'Ana'},
      {'id': _beto, 'name': 'Beto'},
      {'id': _carla, 'name': 'Carla'},
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
      session: () => (orgId: 'org-1', userId: _ana),
      clock: () => DateTime.utc(2026, 11, 8, 12),
      newId: () => 'trip-${++counter}',
    );
    transport.fetches.add(EquipmentFetched(version: 'v1', items: [equipment(equipmentJson())]));
    await manager.refresh();
    transport.transportFetches.add(_catalog());
    await manager.refreshTransportCatalog();
  });
  tearDown(() => db.close());

  Future<TripOutcome> submit({
    String? equipmentId,
    String? vehicleId = _truck,
    String routeId = _route,
    String materialId = _material,
    double volume = 12.5,
    String requestedBy = _carla,
    String dispatchedBy = _ana,
    String receivedBy = _beto,
  }) => manager.submitTrip(
    equipmentId: equipmentId,
    vehicleId: vehicleId,
    routeId: routeId,
    materialId: materialId,
    volumeM3: volume,
    requestedBy: requestedBy,
    dispatchedBy: dispatchedBy,
    receivedBy: receivedBy,
    driverName: 'Pedro',
  );

  group('catálogo', () {
    test('se guarda y se consulta sin red', () async {
      final catalog = await manager.transportCatalog();

      expect(catalog.canRegisterTrips, isTrue);
      expect([for (final r in catalog.routes) (r.origin, r.destination, r.distanceKm)], [('Cantera', 'Km 12', 8.5)]);
      expect([for (final v in catalog.vehicles) (v.plate, v.capacityM3)], [('EXG871', 14.0), ('ABC123', null)]);
      expect([for (final p in catalog.people) p.name], ['Ana', 'Beto', 'Carla']);
    });

    test('envía la última version, "sin cambios" lo conserva y un fallo no lo toca', () async {
      transport.transportFetches
        ..clear()
        ..add(const TransportCatalogUnchanged());
      expect(await manager.refreshTransportCatalog(), isTrue);
      expect(transport.transportVersionsAsked.last, 't1');

      transport.transportFetches
        ..clear()
        ..add(const TransportCatalogFailed());
      expect(await manager.refreshTransportCatalog(), isFalse);
      expect((await manager.transportCatalog()).routes, hasLength(1));
    });

    test('sin sesión no pide nada y sin catálogo no se puede registrar', () async {
      final anonymous = EquipmentManager(db: db, transport: transport, session: () => null);
      expect(await anonymous.refreshTransportCatalog(), isFalse);

      final fresh = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(fresh.close);
      expect(
        (await EquipmentManager(db: fresh, transport: transport, session: () => null).transportCatalog())
            .canRegisterTrips,
        isFalse,
      );
    });
  });

  group('viaje', () {
    test('uno válido de un vehículo de terceros se encola y sale con el mismo id', () async {
      final outcome = await submit();

      expect(outcome.id, 'trip-1');
      expect(await manager.pendingTripCount(), 1);
      expect((await manager.pendingTrips()).single.vehicleLabel, 'EXG871');
      expect(await manager.flushTrips(), 1);
      final sent = transport.sentTrips.single;
      expect((sent.id, sent.vehicleId, sent.equipmentId, sent.volumeM3), ('trip-1', _truck, null, 12.5));
      expect((sent.requestedBy, sent.dispatchedBy, sent.receivedBy), (_carla, _ana, _beto));
      expect(await manager.pendingTripCount(), 0);
    });

    test('con equipo propio lleva el equipo y no el vehículo', () async {
      await submit(equipmentId: _id, vehicleId: null);

      expect((await manager.pendingTrips()).single.vehicleLabel, 'EQ-1');
      await manager.flushTrips();
      final sent = transport.sentTrips.single;
      expect((sent.equipmentId, sent.vehicleId), (_id, null));
    });

    test('exige exactamente un vehículo que exista', () async {
      expect((await submit(vehicleId: null)).problem, TripProblem.vehicleMissing);
      expect((await submit(equipmentId: _id)).problem, TripProblem.vehicleMissing);
      expect((await submit(vehicleId: 'otro')).problem, TripProblem.vehicleMissing);
      expect((await submit(equipmentId: 'otro', vehicleId: null)).problem, TripProblem.vehicleMissing);
      expect(await manager.pendingTripCount(), 0);
    });

    test('exige tramo y material del catálogo, volumen válido y respeta la capacidad', () async {
      expect((await submit(routeId: 'otro')).problem, TripProblem.routeMissing);
      expect((await submit(materialId: 'otro')).problem, TripProblem.materialMissing);
      expect((await submit(volume: 0)).problem, TripProblem.invalidVolume);
      expect((await submit(volume: double.nan)).problem, TripProblem.invalidVolume);
      final over = await submit(volume: 14.5);
      expect((over.problem, over.detail), (TripProblem.overCapacity, '14'));
      expect((await submit(vehicleId: _noCapacity, volume: 500)).ok, isTrue);
    });

    test('exige tres personas del catálogo y que quien despacha no sea quien recibe', () async {
      expect((await submit(requestedBy: 'otra')).problem, TripProblem.peopleMissing);
      expect((await submit(dispatchedBy: '')).problem, TripProblem.peopleMissing);
      expect((await submit(receivedBy: _ana)).problem, TripProblem.sameDispatcherAndReceiver);
      expect(await manager.pendingTripCount(), 0);
    });

    test('sin red se reintenta con el mismo id; el rechazo del servidor no se reintenta', () async {
      await submit();
      transport.tripResult = const ReadingSendResult(ReadingSendStatus.retry);
      expect(await manager.flushTrips(), 0);
      expect(await manager.pendingTripCount(), 1);

      transport.tripResult = const ReadingSendResult(ReadingSendStatus.rejected, message: 'Supera la capacidad');
      await manager.flushTrips();
      expect(await manager.pendingTripCount(), 0);
      final pending = (await manager.pendingTrips()).single;
      expect((pending.rejected, pending.lastError), (true, 'Supera la capacidad'));

      transport.sentTrips.clear();
      await manager.flushTrips();
      expect(transport.sentTrips, isEmpty);
      await manager.dismissRejectedTrip(pending.id);
      expect(await manager.pendingTrips(), isEmpty);
    });

    test('envía en orden cronológico y se detiene en el primer error de red', () async {
      await manager.submitTrip(
        vehicleId: _truck,
        routeId: _route,
        materialId: _material,
        volumeM3: 5,
        requestedBy: _carla,
        dispatchedBy: _ana,
        receivedBy: _beto,
        recordedAt: DateTime.utc(2026, 11, 8, 9),
      );
      await manager.submitTrip(
        vehicleId: _truck,
        routeId: _route,
        materialId: _material,
        volumeM3: 6,
        requestedBy: _carla,
        dispatchedBy: _ana,
        receivedBy: _beto,
        recordedAt: DateTime.utc(2026, 11, 8, 10),
      );
      transport.tripResult = const ReadingSendResult(ReadingSendStatus.retry);

      await manager.flushTrips();

      expect([for (final t in transport.sentTrips) t.volumeM3], [5]);
    });

    test('solo envía los viajes de quien tiene la sesión', () async {
      await submit();
      final other = EquipmentManager(db: db, transport: transport, session: () => (orgId: 'org-1', userId: _beto));

      expect(await other.flushTrips(), 0);
      expect(transport.sentTrips, isEmpty);
    });

    test('sync envía el viaje y refresca ambos catálogos', () async {
      await submit();
      transport.transportFetches
        ..clear()
        ..add(_catalog(version: 't9'));

      await manager.sync();

      expect(transport.sentTrips, hasLength(1));
      expect(transport.transportVersionsAsked.last, 't1');
    });
  });
}
