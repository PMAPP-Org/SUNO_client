// `EquipmentApiClient`: catálogo de transporte y viajes contra un servidor HTTP local.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/equipment/equipment_transport.dart';
import 'package:suno/data/http/equipment_api_client.dart';

void main() {
  late HttpServer server;
  late int status;
  late Object body;
  late List<({String path, Map<String, String> query, String payload, String auth})> requests;

  setUp(() async {
    requests = [];
    status = 200;
    body = {'version': 't1', 'changed': true, 'routes': <Object>[], 'materials': <Object>[], 'vehicles': <Object>[], 'people': <Object>[]};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add((
        path: request.uri.path,
        query: request.uri.queryParameters,
        payload: await utf8.decoder.bind(request).join(),
        auth: request.headers.value('authorization') ?? '',
      ));
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  EquipmentApiClient client() => EquipmentApiClient(
    dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')),
    accessTokenProvider: () => 'tok',
  );

  OutgoingTrip trip({bool own = false}) => OutgoingTrip(
    id: 't-1',
    equipmentId: own ? 'e-1' : null,
    vehicleId: own ? null : 'v-1',
    routeId: 'r-1',
    materialId: 'm-1',
    volumeM3: 12.5,
    recordedAt: DateTime.utc(2026, 11, 8, 8),
    requestedBy: 'p-1',
    dispatchedBy: 'p-2',
    receivedBy: 'p-3',
    driverName: 'Pedro',
    driverDocument: '1020',
    notes: '',
  );

  test('pide el catálogo con el bearer y la version, y lo lee completo', () async {
    body = {
      'version': 't2',
      'changed': true,
      'routes': [
        {'id': 'r-1', 'origin': 'Cantera', 'destination': 'Km 12', 'zone': 'Oriente', 'distance_km': 8.5},
      ],
      'materials': [
        {'id': 'm-1', 'name': 'Gravas'},
      ],
      'vehicles': [
        {'id': 'v-1', 'plate': 'EXG871', 'contractor': 'TDR', 'capacity_m3': 14},
      ],
      'people': [
        {'id': 'p-1', 'name': 'Ana'},
      ],
    };

    final result = await client().fetchTransportCatalog(version: 't1');

    expect(result, isA<TransportCatalogFetched>().having((r) => r.version, 'version', 't2'));
    final catalog = (result as TransportCatalogFetched).catalog;
    expect((catalog.routes.single.distanceKm, catalog.vehicles.single.capacityM3), (8.5, 14.0));
    expect(requests.single.path, '/v1/transport/catalog');
    expect(requests.single.query['version'], 't1');
    expect(requests.single.auth, 'Bearer tok');
  });

  test('"sin cambios", error del servidor y sin red', () async {
    body = {'version': 't1', 'changed': false, 'routes': <Object>[], 'materials': <Object>[], 'vehicles': <Object>[], 'people': <Object>[]};
    expect(await client().fetchTransportCatalog(), isA<TransportCatalogUnchanged>());
    expect(requests.single.query, isEmpty);

    status = 500;
    expect(await client().fetchTransportCatalog(), isA<TransportCatalogFailed>());
    final offline = EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')),
      accessTokenProvider: () => 'tok',
    );
    expect(await offline.fetchTransportCatalog(), isA<TransportCatalogFailed>());
  });

  test('el viaje de terceros viaja con su id, vehículo, tramo, material, volumen y las tres personas', () async {
    final result = await client().sendTrip(trip());

    expect(result.status, ReadingSendStatus.sent);
    expect(requests.single.path, '/v1/transport/trips');
    expect(jsonDecode(requests.single.payload), {
      'id': 't-1',
      'recorded_at': '2026-11-08T08:00:00.000Z',
      'route_id': 'r-1',
      'material_id': 'm-1',
      'volume_m3': 12.5,
      'equipment_id': null,
      'vehicle_id': 'v-1',
      'requested_by_id': 'p-1',
      'dispatched_by_id': 'p-2',
      'received_by_id': 'p-3',
      'driver_name': 'Pedro',
      'driver_document': '1020',
      'notes': '',
    });
  });

  test('un viaje con equipo propio manda el equipo y no el vehículo', () async {
    await client().sendTrip(trip(own: true));

    final sent = jsonDecode(requests.single.payload) as Map<String, dynamic>;
    expect((sent['equipment_id'], sent['vehicle_id']), ('e-1', null));
  });

  test('403, 404 y 422 son rechazos; 5xx, 401 y sin red se reintentan', () async {
    for (final code in [403, 404, 422]) {
      status = code;
      body = {'code': 'x', 'message': 'Quien despacha no puede ser quien recibe.'};
      final result = await client().sendTrip(trip());
      expect(
        (result.status, result.message),
        (ReadingSendStatus.rejected, 'Quien despacha no puede ser quien recibe.'),
        reason: '$code',
      );
    }
    for (final code in [500, 401]) {
      status = code;
      expect((await client().sendTrip(trip())).status, ReadingSendStatus.retry, reason: '$code');
    }
    final offline = EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')),
      accessTokenProvider: () => 'tok',
    );
    expect((await offline.sendTrip(trip())).status, ReadingSendStatus.retry);
  });
}
