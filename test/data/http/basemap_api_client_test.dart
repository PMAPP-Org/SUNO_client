// `BasemapApiClient.fetch` contra un servidor HTTP local: con `Range` y
// respuesta 206 continúa el archivo; si el almacenamiento ignora el rango
// (200), lo reescribe entero.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/data/http/basemap_api_client.dart';

void main() {
  late HttpServer server;
  late Directory dir;
  final content = List<int>.generate(5000, (i) => i % 256);
  var honorRange = true;
  final ranges = <String?>[];

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('basemap-http');
    honorRange = true;
    ranges.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value('range');
      ranges.add(range);
      final match = range == null ? null : RegExp(r'^bytes=(\d+)-$').firstMatch(range);
      if (honorRange && match != null) {
        final from = int.parse(match.group(1)!);
        request.response
          ..statusCode = 206
          ..headers.contentLength = content.length - from
          ..add(content.sublist(from));
      } else {
        request.response
          ..statusCode = 200
          ..headers.contentLength = content.length
          ..add(content);
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  BasemapApiClient client() =>
      BasemapApiClient(dio: Dio(), accessTokenProvider: () => 't', downloadDio: Dio());

  String url() => 'http://127.0.0.1:${server.port}/basemaps/x.mbtiles';

  test('continúa desde el byte pedido cuando el servidor responde 206', () async {
    final path = '${dir.path}/x.part';
    File(path).writeAsBytesSync(content.sublist(0, 1200));
    int? lastReceived;
    int? lastTotal;

    await client().fetch(
      url(),
      path,
      from: 1200,
      onProgress: (received, total) {
        lastReceived = received;
        lastTotal = total;
      },
    );

    expect(ranges.single, 'bytes=1200-');
    expect(File(path).readAsBytesSync(), content);
    expect((lastReceived, lastTotal), (5000, 5000), reason: 'el progreso cuenta lo que ya había');
  });

  test('si el servidor ignora el rango, reescribe el archivo entero', () async {
    honorRange = false;
    final path = '${dir.path}/x.part';
    File(path).writeAsBytesSync(content.sublist(0, 1200));

    await client().fetch(url(), path, from: 1200);
    expect(File(path).readAsBytesSync(), content, reason: 'sin duplicar los primeros 1200 bytes');
  });

  test('sin parte previa no manda Range', () async {
    final path = '${dir.path}/x.part';
    await client().fetch(url(), path);
    expect(ranges.single, isNull);
    expect(File(path).readAsBytesSync(), content);
  });
}
