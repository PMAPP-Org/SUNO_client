// `AttachmentApiClient.upload()` (Paso 18): el `PUT` al object storage envía
// el archivo **en streaming**, sin pasar por el transformer de texto/JSON de
// Dio. Se comprueba sobre lo que Dio entrega de verdad al adaptador HTTP
// (`requestStream`), no sobre `RequestOptions.data`: así un cambio que
// volviera a serializar el cuerpo (y corrompiera el checksum firmado en el
// presign) haría fallar el test.
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/attachments/attachment_result.dart';
import 'package:visitacampo/data/http/attachment_api_client.dart';

/// Adaptador que lee el cuerpo enviado, como lo haría el socket.
class _WireAdapter implements HttpClientAdapter {
  _WireAdapter(this.status);
  final int status;
  final List<int> received = [];
  RequestOptions? options;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    this.options = options;
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        received.addAll(chunk);
      }
    }
    return ResponseBody.fromString('', status);
  }

  @override
  void close({bool force = false}) {}
}

AttachmentApiClient _client(_WireAdapter adapter) => AttachmentApiClient(
  dio: Dio(BaseOptions(baseUrl: 'https://api.test')),
  accessTokenProvider: () => 'unused',
  uploadDio: Dio()..httpClientAdapter = adapter,
);

Stream<List<int>> _chunks(List<int> bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

void main() {
  test('upload() envía el stream byte a byte, con Content-Length y las cabeceras firmadas', () async {
    final adapter = _WireAdapter(200);
    // Todos los valores de byte, incluidos los que una serialización como
    // texto (UTF-8, JSON) alteraría.
    final bytes = List<int>.generate(256, (i) => i);

    final result = await _client(adapter).upload(
      uploadUrl: 'https://blob.test/put',
      headers: const {'x-amz-checksum-sha256': 'abc'},
      body: _chunks(bytes, 7),
      length: bytes.length,
    );

    expect(result.isOk, isTrue);
    expect(adapter.received, orderedEquals(bytes));
    final headers = adapter.options!.headers;
    expect(headers[Headers.contentLengthHeader], '256');
    expect(headers['x-amz-checksum-sha256'], 'abc');
    expect(headers.containsKey('Authorization'), isFalse, reason: 'la URL firmada no lleva el bearer de la API');
  });

  test('upload() traduce un 403 del object storage (URL caducada) a error con su código', () async {
    final result = await _client(_WireAdapter(403)).upload(
      uploadUrl: 'https://blob.test/put',
      headers: const {},
      body: _chunks([1, 2, 3], 2),
      length: 3,
    );

    expect(result, isA<AttachmentErr<void>>());
    final error = (result as AttachmentErr<void>).error;
    expect(error, isA<AttachmentUnexpectedStatus>().having((e) => e.statusCode, 'statusCode', 403));
  });
}
