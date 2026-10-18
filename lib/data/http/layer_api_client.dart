// `LayerApiClient` — implementación Dio de `LayerTransport` (Fase C). Igual
// que `BasemapApiClient`: lista y URL con el bearer del agente; la descarga a
// la URL prefirmada sin bearer y con la misma política TLS.
import 'package:dio/dio.dart';

import '../../core/layers/layer_manager.dart';
import 'resumable_fetch.dart';

class LayerApiClient implements LayerTransport {
  LayerApiClient({required this.dio, required this.accessTokenProvider, required this.downloadDio});

  final Dio dio;
  final String Function() accessTokenProvider;
  final Dio downloadDio;

  Options get _auth => Options(headers: {'Authorization': 'Bearer ${accessTokenProvider()}'});

  @override
  Future<List<LayerInfo>?> list() async {
    try {
      final response = await dio.get<Map<String, dynamic>>('/v1/layers', options: _auth);
      final items = response.data?['items'] as List<dynamic>?;
      if (items == null) return null;
      return [for (final item in items) LayerInfo.fromJson(item as Map<String, dynamic>)];
    } on DioException {
      return null;
    } on TypeError {
      return null;
    }
  }

  @override
  Future<String?> downloadUrl(String id) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        '/v1/layers/${Uri.encodeComponent(id)}/download',
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
  Future<void> fetch(
    String url,
    String path, {
    int from = 0,
    void Function(int received, int total)? onProgress,
  }) => fetchResumable(downloadDio, url, path, from: from, onProgress: onProgress);
}
