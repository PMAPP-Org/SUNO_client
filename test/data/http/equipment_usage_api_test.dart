// `EquipmentApiClient.sendUsageReport` contra un servidor HTTP local.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/equipment/equipment_transport.dart';
import 'package:visitacampo/data/http/equipment_api_client.dart';

void main() {
  late HttpServer server;
  late int status;
  late List<({String path, String payload, String auth})> requests;

  setUp(() async {
    requests = [];
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add((
        path: request.uri.path,
        payload: await utf8.decoder.bind(request).join(),
        auth: request.headers.value('authorization') ?? '',
      ));
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'code': 'x', 'message': 'Se cruza con otro uso'}));
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  EquipmentApiClient client() => EquipmentApiClient(
    dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')),
    accessTokenProvider: () => 'tok',
  );

  OutgoingUsageReport report({double? startMeter = 500, double? endMeter = 504, int start = 485, int end = 725}) =>
      OutgoingUsageReport(
        id: 'u-1',
        equipmentId: 'e-1',
        projectId: 'p-1',
        usageDate: '2026-11-07',
        startMinutes: start,
        endMinutes: end,
        activity: 'Zanja',
        location: 'Frente 2',
        startMeter: startMeter,
        endMeter: endMeter,
        notes: '',
      );

  test('envía id, proyecto, fecha, horas HH:MM:SS, actividad y lecturas con el bearer', () async {
    final result = await client().sendUsageReport(report());

    expect(result.status, ReadingSendStatus.sent);
    expect(requests.single.path, '/v1/equipment/e-1/usage-reports');
    expect(requests.single.auth, 'Bearer tok');
    expect(jsonDecode(requests.single.payload), {
      'id': 'u-1',
      'project_id': 'p-1',
      'usage_date': '2026-11-07',
      'start_time': '08:05:00',
      'end_time': '12:05:00',
      'activity': 'Zanja',
      'location': 'Frente 2',
      'start_meter': 500,
      'end_meter': 504,
      'notes': '',
    });
  });

  test('un equipo sin medidor manda las lecturas en null', () async {
    await client().sendUsageReport(report(startMeter: null, endMeter: null));

    final sent = jsonDecode(requests.single.payload) as Map<String, dynamic>;
    expect((sent['start_meter'], sent['end_meter']), (null, null));
  });

  test('403, 404 y 422 son rechazos con el mensaje; 5xx, 401 y sin red se reintentan', () async {
    for (final code in [403, 404, 422]) {
      status = code;
      final result = await client().sendUsageReport(report());
      expect((result.status, result.message), (ReadingSendStatus.rejected, 'Se cruza con otro uso'), reason: '$code');
    }
    for (final code in [500, 401]) {
      status = code;
      expect((await client().sendUsageReport(report())).status, ReadingSendStatus.retry, reason: '$code');
    }
    final offline = EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')),
      accessTokenProvider: () => 'tok',
    );
    expect((await offline.sendUsageReport(report())).status, ReadingSendStatus.retry);
  });
}
