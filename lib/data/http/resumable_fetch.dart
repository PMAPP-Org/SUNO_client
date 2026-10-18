// Descarga HTTP reanudable a un archivo (mapas base, capas).
//
// Con `Range: bytes=from-` y respuesta 206 se añade a lo que ya había; si el
// almacenamiento ignora el rango (200), se reescribe el archivo entero.
import 'dart:io';

import 'package:dio/dio.dart';

Future<void> fetchResumable(
  Dio dio,
  String url,
  String path, {
  int from = 0,
  void Function(int received, int total)? onProgress,
}) async {
  final response = await dio.get<ResponseBody>(
    url,
    options: Options(
      responseType: ResponseType.stream,
      headers: from > 0 ? {'Range': 'bytes=$from-'} : null,
    ),
  );
  final body = response.data!;
  final resumed = from > 0 && response.statusCode == 206;
  final start = resumed ? from : 0;
  final length = int.tryParse(response.headers.value(Headers.contentLengthHeader) ?? '') ?? -1;
  final total = length < 0 ? -1 : start + length;
  final sink = File(path).openWrite(mode: resumed ? FileMode.append : FileMode.write);
  var received = start;
  try {
    await for (final chunk in body.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
  } finally {
    await sink.close();
  }
}
