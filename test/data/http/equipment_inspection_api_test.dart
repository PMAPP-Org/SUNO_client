// `EquipmentApiClient.sendInspection` contra un servidor HTTP local.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/equipment/equipment_models.dart';
import 'package:visitacampo/core/equipment/equipment_transport.dart';
import 'package:visitacampo/data/http/equipment_api_client.dart';

void main() {
  late HttpServer server;
  late int status;
  late List<({String path, String payload})> requests;

  setUp(() async {
    requests = [];
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add((path: request.uri.path, payload: await utf8.decoder.bind(request).join()));
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'code': 'x', 'message': 'Faltan ítems'}));
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  EquipmentApiClient client() => EquipmentApiClient(
    dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')),
    accessTokenProvider: () => 'tok',
  );

  OutgoingInspection inspection({MeterUnit? unit = MeterUnit.hours, double? value = 339.5}) => OutgoingInspection(
    id: 'i-1',
    equipmentId: 'e-1',
    capturedAt: DateTime.utc(2026, 11, 8, 8),
    meterUnit: unit,
    meterValue: value,
    items: const [
      OutgoingInspectionItem(itemId: 'a', ok: true, note: ''),
      OutgoingInspectionItem(itemId: 'b', ok: false, note: 'Pedal blando'),
    ],
    notes: 'turno',
  );

  test('envía id, instante UTC, medidor y las respuestas por ítem', () async {
    final result = await client().sendInspection(inspection());

    expect(result.status, ReadingSendStatus.sent);
    expect(requests.single.path, '/v1/equipment/e-1/inspections');
    expect(jsonDecode(requests.single.payload), {
      'id': 'i-1',
      'captured_at': '2026-11-08T08:00:00.000Z',
      'meter_unit': 'hours',
      'meter_value': 339.5,
      'items': [
        {'item_id': 'a', 'ok': true, 'note': ''},
        {'item_id': 'b', 'ok': false, 'note': 'Pedal blando'},
      ],
      'notes': 'turno',
    });
  });

  test('un equipo controlado por fecha manda el medidor en null', () async {
    await client().sendInspection(inspection(unit: null, value: null));

    final body = jsonDecode(requests.single.payload) as Map<String, dynamic>;
    expect((body['meter_unit'], body['meter_value']), (null, null));
  });

  test('403, 404 y 422 son rechazos con el mensaje; 5xx y sin red se reintentan', () async {
    for (final code in [403, 404, 422]) {
      status = code;
      final result = await client().sendInspection(inspection());
      expect((result.status, result.message), (ReadingSendStatus.rejected, 'Faltan ítems'), reason: '$code');
    }
    for (final code in [500, 401]) {
      status = code;
      expect((await client().sendInspection(inspection())).status, ReadingSendStatus.retry, reason: '$code');
    }
    final offline = EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')),
      accessTokenProvider: () => 'tok',
    );
    expect((await offline.sendInspection(inspection())).status, ReadingSendStatus.retry);
  });
}
