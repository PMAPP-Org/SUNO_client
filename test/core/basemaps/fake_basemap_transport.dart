// Doble de `BasemapTransport` para los tests de mapas offline (Fase B).
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:visitacampo/core/basemaps/basemap_manager.dart';

class FakeBasemapTransport implements BasemapTransport {
  List<BasemapInfo>? offered = [];
  final Map<String, List<int>> contents = {};
  bool failFetch = false;
  int fetches = 0;

  @override
  Future<List<BasemapInfo>?> list() async => offered;

  @override
  Future<String?> downloadUrl(String id) async => contents.containsKey(id) ? 'https://store.example/$id' : null;

  @override
  Future<void> fetch(String url, String path, {void Function(int received, int total)? onProgress}) async {
    fetches++;
    if (failFetch) throw const SocketException('sin red');
    final bytes = contents[url.split('/').last]!;
    await File(path).writeAsBytes(bytes);
    onProgress?.call(bytes.length, bytes.length);
  }
}

BasemapInfo info(String id, List<int> bytes, {String? sha}) => BasemapInfo(
  id: id,
  name: 'Mapa $id',
  sha256: sha ?? sha256.convert(bytes).toString(),
  size: bytes.length,
  tileFormat: 'png',
  minZoom: 10,
  maxZoom: 16,
  west: -74.2,
  south: 4.5,
  east: -74,
  north: 4.7,
);
