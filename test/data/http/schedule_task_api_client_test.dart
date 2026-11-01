// `ScheduleTaskApiClient` contra un servidor HTTP local.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/data/http/schedule_task_api_client.dart';

void main() {
  late HttpServer server;
  final seen = <({Map<String, String> query, String? auth})>[];
  var status = 200;
  Object body = const <String, dynamic>{};

  setUp(() async {
    seen.clear();
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      seen.add((query: request.uri.queryParameters, auth: request.headers.value('authorization')));
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  ScheduleTaskApiClient client() => ScheduleTaskApiClient(
    dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')),
    accessTokenProvider: () => 'token-1',
  );

  test('lee la lista y envía la versión conocida con el bearer', () async {
    body = {
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
        },
      ],
    };
    final page = await client().fetch(version: 'v1');
    expect(seen.single.query, {'version': 'v1'});
    expect(seen.single.auth, 'Bearer token-1');
    expect(
      (page!.version, page.changed, page.items.single.name, page.items.single.lastValidatedPct),
      ('v2', true, 'Descapote', 40.0),
    );
  });

  test('sin versión no envía el parámetro', () async {
    body = {'version': 'v1', 'changed': true, 'items': <Object>[]};
    await client().fetch();
    expect(seen.single.query, isEmpty);
  });

  test('error del servidor o respuesta rara: null (no se toca la lista)', () async {
    status = 500;
    expect(await client().fetch(), isNull);
    status = 200;
    body = {'version': 'v1'};
    expect(await client().fetch(), isNull);
  });
}
