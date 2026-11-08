// `EquipmentApiClient` contra un servidor HTTP local: lista con `?version=`,
// "sin cambios", y los códigos de la lectura de medidor (200 enviada, 403/404/
// 422 rechazada, 5xx o sin red reintentable).
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/equipment/equipment_models.dart';
import 'package:visitacampo/core/equipment/equipment_transport.dart';
import 'package:visitacampo/data/http/equipment_api_client.dart';

import '../../core/equipment/fake_equipment_transport.dart';

void main() {
  late HttpServer server;
  late int status;
  late Object body;
  late List<({String method, String path, Map<String, String> query, String auth, String payload})> requests;

  setUp(() async {
    requests = [];
    status = 200;
    body = {'version': 'v1', 'changed': true, 'items': <Object>[]};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add((
        method: request.method,
        path: request.uri.path,
        query: request.uri.queryParameters,
        auth: request.headers.value('authorization') ?? '',
        payload: await utf8.decoder.bind(request).join(),
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

  OutgoingMeterReading reading() => OutgoingMeterReading(
    id: 'r-1',
    equipmentId: 'e-1',
    meterUnit: MeterUnit.hours,
    value: 339.5,
    readAt: DateTime.utc(2026, 11, 1, 8),
    notes: 'turno',
  );

  test('pide la lista con el bearer y la version conocida', () async {
    body = {
      'version': 'v9',
      'changed': true,
      'items': [equipmentJson()],
    };

    final result = await client().fetchList(version: 'v8');

    expect(result, isA<EquipmentFetched>().having((r) => r.version, 'version', 'v9').having((r) => r.items.length, 'n', 1));
    expect(requests.single.path, '/v1/equipment');
    expect(requests.single.query, {'version': 'v8'});
    expect(requests.single.auth, 'Bearer tok');
  });

  test('sin version no manda el parámetro, y changed:false es "sin cambios"', () async {
    body = {'version': 'v1', 'changed': false, 'items': <Object>[]};

    final result = await client().fetchList();

    expect(result, isA<EquipmentUnchanged>());
    expect(requests.single.query, isEmpty);
  });

  test('un error del servidor o un cuerpo inválido no es una lista', () async {
    status = 500;
    expect(await client().fetchList(), isA<EquipmentFetchFailed>());
    status = 200;
    body = {'version': 'v1', 'changed': true, 'items': [{'id': 'sin-campos'}]};
    expect(await client().fetchList(), isA<EquipmentFetchFailed>());
  });

  test('sin conexión la lista falla sin lanzar', () async {
    final result = await EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')),
      accessTokenProvider: () => 'tok',
    ).fetchList();

    expect(result, isA<EquipmentFetchFailed>());
  });

  test('envía la lectura con su id y el instante en UTC', () async {
    body = {'id': 'r-1'};

    final result = await client().sendMeterReading(reading());

    expect(result.status, ReadingSendStatus.sent);
    expect(requests.single.method, 'POST');
    expect(requests.single.path, '/v1/equipment/e-1/meter-readings');
    expect(jsonDecode(requests.single.payload), {
      'id': 'r-1',
      'meter_unit': 'hours',
      'value': 339.5,
      'read_at': '2026-11-01T08:00:00.000Z',
      'notes': 'turno',
    });
  });

  test('403, 404 y 422 son rechazos definitivos con el mensaje del servidor', () async {
    for (final code in [403, 404, 422]) {
      status = code;
      body = {'code': 'x', 'message': 'no'};
      final result = await client().sendMeterReading(reading());
      expect((result.status, result.message), (ReadingSendStatus.rejected, 'no'), reason: '$code');
    }
  });

  test('5xx, 401 y falta de red se reintentan', () async {
    for (final code in [500, 401, 429]) {
      status = code;
      expect((await client().sendMeterReading(reading())).status, ReadingSendStatus.retry, reason: '$code');
    }
    final offline = EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')),
      accessTokenProvider: () => 'tok',
    );
    expect((await offline.sendMeterReading(reading())).status, ReadingSendStatus.retry);
  });
}
