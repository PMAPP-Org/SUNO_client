// `BasemapApiClient` — implementación Dio de `BasemapTransport` (Fase B).
//
// La lista y la URL van a la API con el bearer del agente. La descarga en sí
// va a la URL prefirmada del almacenamiento con [downloadDio]: **sin**
// cabecera de autorización (la firma ya está en la URL, y un bearer de más
// haría que el almacenamiento la rechazara) pero con la misma política TLS
// que la API (Paso 16).
import 'package:dio/dio.dart';

import '../../core/basemaps/basemap_manager.dart';

class BasemapApiClient implements BasemapTransport {
  BasemapApiClient({required this.dio, required this.accessTokenProvider, required this.downloadDio});

  final Dio dio;
  final String Function() accessTokenProvider;
  final Dio downloadDio;

  Options get _auth => Options(headers: {'Authorization': 'Bearer ${accessTokenProvider()}'});

  @override
  Future<List<BasemapInfo>?> list() async {
    try {
      final response = await dio.get<Map<String, dynamic>>('/v1/basemaps', options: _auth);
      final items = response.data?['items'] as List<dynamic>?;
      if (items == null) return null;
      return [for (final item in items) BasemapInfo.fromJson(item as Map<String, dynamic>)];
    } on DioException {
      return null;
    } on TypeError {
      // Respuesta que no cumple el contrato: como sin red.
      return null;
    }
  }

  @override
  Future<String?> downloadUrl(String id) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        '/v1/basemaps/${Uri.encodeComponent(id)}/download',
        options: _auth,
      );
      return response.data?['url'] as String?;
    } on DioException {
      return null;
    } on TypeError {
      return null;
    }
  }

  @override
  Future<void> fetch(String url, String path, {void Function(int received, int total)? onProgress}) =>
      downloadDio.download(url, path, onReceiveProgress: onProgress);
}
