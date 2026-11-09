// `EquipmentApiClient`: catálogo de combustible y tanqueos contra un servidor HTTP local.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/equipment/equipment_models.dart';
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
    body = {'version': 'c1', 'changed': true, 'stations': <Object>[], 'stores': <Object>[]};
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

  OutgoingFuelFill fill({FuelSource source = FuelSource.station}) => OutgoingFuelFill(
    id: 'f-1',
    equipmentId: 'e-1',
    source: source,
    stationId: source == FuelSource.station ? 's-1' : null,
    storeId: source == FuelSource.store ? 't-1' : null,
    fuelType: 'acpm',
    voucherNumber: 'V-9',
    filledAt: DateTime.utc(2026, 11, 8, 8),
    gallons: 25.5,
    meterUnit: MeterUnit.kilometers,
    meterValue: 1100,
    workFront: 'Frente 2',
    driverName: 'Pedro',
    driverDocument: '1020',
    notes: '',
  );

  test('pide el catálogo con el bearer y la version, y lo lee', () async {
    body = {
      'version': 'c2',
      'changed': true,
      'stations': [
        {'id': 's-1', 'name': 'Norte', 'supplier': 'Terpel'},
      ],
      'stores': [
        {'id': 't-1', 'name': 'Tanque 1'},
      ],
    };

    final result = await client().fetchFuelCatalog(version: 'c1');

    expect(result, isA<FuelCatalogFetched>().having((r) => r.version, 'version', 'c2'));
    expect((result as FuelCatalogFetched).catalog.stations.single.supplier, 'Terpel');
    expect(requests.single.path, '/v1/fuel/catalog');
    expect(requests.single.query['version'], 'c1');
    expect(requests.single.auth, 'Bearer tok');
  });

  test('"sin cambios", error del servidor y sin red', () async {
    body = {'version': 'c1', 'changed': false, 'stations': <Object>[], 'stores': <Object>[]};
    expect(await client().fetchFuelCatalog(), isA<FuelCatalogUnchanged>());
    expect(requests.single.query, isEmpty);

    status = 500;
    expect(await client().fetchFuelCatalog(), isA<FuelCatalogFailed>());
    final offline = EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')),
      accessTokenProvider: () => 'tok',
    );
    expect(await offline.fetchFuelCatalog(), isA<FuelCatalogFailed>());
  });

  test('el tanqueo de estación viaja con su id, estación, vale, galones y lectura', () async {
    final result = await client().sendFuelFill(fill());

    expect(result.status, ReadingSendStatus.sent);
    expect(requests.single.path, '/v1/equipment/e-1/fuel-fills');
    expect(jsonDecode(requests.single.payload), {
      'id': 'f-1',
      'source': 'station',
      'station_id': 's-1',
      'store_id': null,
      'fuel_type': 'acpm',
      'voucher_number': 'V-9',
      'filled_at': '2026-11-08T08:00:00.000Z',
      'gallons': 25.5,
      'meter_unit': 'kilometers',
      'meter_value': 1100,
      'work_front': 'Frente 2',
      'driver_name': 'Pedro',
      'driver_document': '1020',
      'notes': '',
    });
  });

  test('una salida del tanque propio manda el tanque', () async {
    await client().sendFuelFill(fill(source: FuelSource.store));

    final sent = jsonDecode(requests.single.payload) as Map<String, dynamic>;
    expect((sent['source'], sent['station_id'], sent['store_id']), ('store', null, 't-1'));
  });

  test('403, 404 y 422 son rechazos; 5xx, 401 y sin red se reintentan', () async {
    for (final code in [403, 404, 422]) {
      status = code;
      body = {'code': 'x', 'message': 'Ese vale ya fue registrado'};
      final result = await client().sendFuelFill(fill());
      expect((result.status, result.message), (ReadingSendStatus.rejected, 'Ese vale ya fue registrado'), reason: '$code');
    }
    for (final code in [500, 401]) {
      status = code;
      expect((await client().sendFuelFill(fill())).status, ReadingSendStatus.retry, reason: '$code');
    }
    final offline = EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')),
      accessTokenProvider: () => 'tok',
    );
    expect((await offline.sendFuelFill(fill())).status, ReadingSendStatus.retry);
  });
}
