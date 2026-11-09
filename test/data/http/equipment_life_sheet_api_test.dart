// `EquipmentApiClient.fetchLifeSheet` contra un servidor HTTP local.
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/data/http/equipment_api_client.dart';

void main() {
  test('el cliente HTTP pide el PDF con el bearer y trata 404 o sin red como "sin documento"', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var status = 200;
    String? auth;
    String? path;
    server.listen((request) async {
      auth = request.headers.value('authorization');
      path = request.uri.path;
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType('application', 'pdf')
        ..add([0x25, 0x50, 0x44, 0x46, 0x2d]);
      await request.response.close();
    });
    final client = EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:${server.port}')),
      accessTokenProvider: () => 'tok',
    );

    expect(await client.fetchLifeSheet('e-1'), Uint8List.fromList([0x25, 0x50, 0x44, 0x46, 0x2d]));
    expect((auth, path), ('Bearer tok', '/v1/equipment/e-1/life-sheet'));
    status = 404;
    expect(await client.fetchLifeSheet('e-1'), isNull);

    final offline = EquipmentApiClient(
      dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1')),
      accessTokenProvider: () => 'tok',
    );
    expect(await offline.fetchLifeSheet('e-1'), isNull);
  });
}
