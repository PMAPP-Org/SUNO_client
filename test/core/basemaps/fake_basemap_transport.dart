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

  /// Bytes que se entregan antes de "cortarse" la red; `null` = sin corte.
  int? cutAfter;

  /// El `from` de cada llamada, para comprobar que se reanuda.
  final List<int> froms = [];

  @override
  Future<void> fetch(
    String url,
    String path, {
    int from = 0,
    void Function(int received, int total)? onProgress,
  }) async {
    fetches++;
    froms.add(from);
    if (failFetch) throw const SocketException('sin red');
    final bytes = contents[url.split('/').last]!;
    final rest = bytes.sublist(from);
    final limit = cutAfter;
    final sent = limit == null ? rest : rest.sublist(0, limit.clamp(0, rest.length));
    await File(path).writeAsBytes(sent, mode: from > 0 ? FileMode.append : FileMode.write);
    onProgress?.call(from + sent.length, bytes.length);
    if (limit != null && sent.length < rest.length) throw const SocketException('se cortó');
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
