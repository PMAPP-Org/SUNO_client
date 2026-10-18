// Mapas base offline (Fase B): qué paquetes ofrece la organización, cuáles
// están en el teléfono, y descargarlos de forma verificable.
//
// - La lista viene de `GET /v1/basemaps`. Un paquete descargado que el
//   servidor ya no ofrece (retirado) se borra del teléfono al refrescar; si
//   no hay red, no se toca nada.
// - La descarga va a un archivo temporal y **solo se activa si su `sha256` y
//   su tamaño coinciden** con los que dio el servidor: un archivo cortado o
//   alterado nunca llega al mapa.
// - Lo descargado se recuerda en un índice JSON junto a los archivos
//   (`<dir>/index.json`). Son teselas de un mapa, no datos personales: no
//   necesitan la BD cifrada.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

@immutable
class BasemapInfo {
  const BasemapInfo({
    required this.id,
    required this.name,
    required this.sha256,
    required this.size,
    required this.tileFormat,
    required this.minZoom,
    required this.maxZoom,
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  });

  factory BasemapInfo.fromJson(Map<String, dynamic> json) {
    final bounds = json['bounds'] as Map<String, dynamic>;
    return BasemapInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      sha256: json['sha256'] as String,
      size: json['size'] as int,
      tileFormat: json['tile_format'] as String,
      minZoom: json['min_zoom'] as int,
      maxZoom: json['max_zoom'] as int,
      west: (bounds['west'] as num).toDouble(),
      south: (bounds['south'] as num).toDouble(),
      east: (bounds['east'] as num).toDouble(),
      north: (bounds['north'] as num).toDouble(),
    );
  }

  final String id;
  final String name;
  final String sha256;
  final int size;
  final String tileFormat;
  final int minZoom;
  final int maxZoom;
  final double west;
  final double south;
  final double east;
  final double north;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sha256': sha256,
    'size': size,
    'tile_format': tileFormat,
    'min_zoom': minZoom,
    'max_zoom': maxZoom,
    'bounds': {'west': west, 'south': south, 'east': east, 'north': north},
  };
}

/// Un paquete ofrecido, y si ya está en el teléfono.
@immutable
class BasemapEntry {
  const BasemapEntry({required this.info, this.localPath});

  final BasemapInfo info;

  /// Archivo verificado en el teléfono; `null` si no se ha descargado.
  final String? localPath;

  bool get downloaded => localPath != null;
}

/// `GET /v1/basemaps` y `GET /v1/basemaps/{id}/download`, y la descarga en sí.
abstract class BasemapTransport {
  /// `null` sin red o con error: la lista local no se toca.
  Future<List<BasemapInfo>?> list();

  /// URL prefirmada de descarga; `null` si no se pudo obtener.
  Future<String?> downloadUrl(String id);

  /// Descarga [url] a [path], **continuando** desde el byte [from] si ya hay
  /// una parte (`Range: bytes=from-`). Si el almacenamiento no admite
  /// rangos, reescribe el archivo desde el principio. Lanza si falla; lo ya
  /// escrito se conserva para el siguiente intento.
  Future<void> fetch(
    String url,
    String path, {
    int from = 0,
    void Function(int received, int total)? onProgress,
  });
}

sealed class BasemapDownloadResult {
  const BasemapDownloadResult();
}

final class BasemapDownloaded extends BasemapDownloadResult {
  const BasemapDownloaded();
}

/// Sin red o el servidor no dio la URL.
final class BasemapUnavailable extends BasemapDownloadResult {
  const BasemapUnavailable();
}

/// Lo descargado no coincide con el `sha256`/tamaño anunciado: se descartó.
final class BasemapCorrupted extends BasemapDownloadResult {
  const BasemapCorrupted();
}

/// No cupo o no se pudo escribir en el teléfono.
final class BasemapNoSpace extends BasemapDownloadResult {
  const BasemapNoSpace();
}

/// Descarga automática en curso: qué paquete y cuánto lleva (0–1; `null`
/// mientras no se sabe el total).
@immutable
class BasemapProgress {
  const BasemapProgress({required this.name, this.fraction});
  final String name;
  final double? fraction;
}

class BasemapManager {
  BasemapManager({required this.transport, required this.directory});

  final BasemapTransport transport;

  /// Carpeta propia de la app donde viven los paquetes y el índice.
  final Directory directory;

  /// La descarga automática en curso, para el aviso de la pantalla de inicio;
  /// `null` si no hay ninguna.
  final ValueNotifier<BasemapProgress?> progress = ValueNotifier(null);

  Future<void>? _autoSync;

  /// Paquetes (por `sha256`) que esta sesión ya no reintenta: llegaron
  /// corruptos o no cupieron. Volver a bajarlos cada pocos minutos gastaría
  /// el plan de datos del agente en bucle; se reintenta al reabrir la app.
  final Set<String> _gaveUp = {};

  /// Fase B: deja el teléfono con **todos** los mapas que ofrece la
  /// organización, sin que el agente tenga que pedirlos. Se llama tras cada
  /// sincronización; si ya hay una en curso, devuelve esa (un paquete grande
  /// no se baja dos veces a la vez). Con cualquier conexión: decisión de
  /// producto, el mapa debe llegar cuanto antes.
  Future<void> syncAll() => _autoSync ??= _syncAll().whenComplete(() => _autoSync = null);

  Future<void> _syncAll() async {
    final result = await refresh();
    if (!result.online) return;
    for (final entry in result.entries) {
      if (entry.downloaded || _gaveUp.contains(entry.info.sha256)) continue;
      final info = entry.info;
      progress.value = BasemapProgress(name: info.name);
      try {
        final outcome = await download(
          info,
          onProgress: (received, total) {
            if (total > 0) progress.value = BasemapProgress(name: info.name, fraction: received / total);
          },
        );
        switch (outcome) {
          case BasemapCorrupted() || BasemapNoSpace():
            _gaveUp.add(info.sha256);
          case BasemapUnavailable():
            // Sin red a mitad: el siguiente ciclo lo reintenta.
            return;
          case BasemapDownloaded():
            break;
        }
      } finally {
        progress.value = null;
      }
    }
  }

  File get _index => File(p.join(directory.path, 'index.json'));

  /// Los paquetes descargados y verificados, según el índice local. Los que
  /// el índice cita pero ya no están en disco no cuentan.
  Future<List<BasemapEntry>> downloaded() async {
    final entries = <BasemapEntry>[];
    for (final info in await _readIndex()) {
      final file = File(_pathFor(info));
      if (file.existsSync()) entries.add(BasemapEntry(info: info, localPath: file.path));
    }
    return entries;
  }

  /// Lo que ofrece el servidor, marcando lo ya descargado. Sin red, solo lo
  /// descargado. Borra del teléfono lo que el servidor retiró.
  Future<({List<BasemapEntry> entries, bool online})> refresh() async {
    final local = {for (final e in await downloaded()) e.info.id: e};
    final offered = await transport.list();
    if (offered == null) return (entries: local.values.toList(), online: false);

    final offeredIds = {for (final info in offered) info.id};
    for (final retired in local.values.where((e) => !offeredIds.contains(e.info.id))) {
      await _deleteFile(retired.localPath!);
    }
    // Un paquete que cambió de contenido (mismo id, otro sha256) se trata como
    // no descargado: su archivo es el viejo.
    final entries = [
      for (final info in offered)
        BasemapEntry(
          info: info,
          localPath: local[info.id]?.info.sha256 == info.sha256 ? local[info.id]!.localPath : null,
        ),
    ];
    await _writeIndex([for (final e in entries) if (e.downloaded) e.info]);
    return (entries: entries, online: true);
  }

  Future<BasemapDownloadResult> download(
    BasemapInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final url = await transport.downloadUrl(info.id);
    if (url == null) return const BasemapUnavailable();
    await directory.create(recursive: true);
    // Descarga **reanudable**: lo ya bajado de un intento cortado (mala
    // cobertura en campo) se conserva en `.part` y se pide solo lo que falta.
    // El nombre sale del sha256: una parte nunca se mezcla con otro paquete.
    final partial = File('${_pathFor(info)}.part');
    var have = partial.existsSync() ? partial.lengthSync() : 0;
    if (have > info.size) {
      await _deleteFile(partial.path);
      have = 0;
    }
    if (have < info.size) {
      try {
        await transport.fetch(url, partial.path, from: have, onProgress: onProgress);
      } on FileSystemException {
        // Sin espacio: la parte se libera, no tiene sentido guardarla.
        await _deleteFile(partial.path);
        return const BasemapNoSpace();
      } on Object {
        // Corte de red: la parte se queda para continuar en el próximo ciclo.
        return const BasemapUnavailable();
      }
    }
    if (!partial.existsSync() || await partial.length() != info.size || await _sha256(partial) != info.sha256) {
      await _deleteFile(partial.path);
      return const BasemapCorrupted();
    }
    await partial.rename(_pathFor(info));
    final index = [for (final i in await _readIndex()) if (i.id != info.id) i, info];
    await _writeIndex(index);
    return const BasemapDownloaded();
  }

  Future<void> remove(BasemapInfo info) async {
    await _deleteFile(_pathFor(info));
    await _writeIndex([for (final i in await _readIndex()) if (i.id != info.id) i]);
  }

  /// El nombre lo deriva el cliente del `sha256` validado, nunca del servidor:
  /// no hay ruta que inyectar.
  String _pathFor(BasemapInfo info) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(info.sha256)) {
      throw ArgumentError.value(info.sha256, 'sha256');
    }
    return p.join(directory.path, '${info.sha256}.mbtiles');
  }

  Future<List<BasemapInfo>> _readIndex() async {
    // Lectura síncrona a propósito: el índice son unos pocos cientos de bytes,
    // y así abrir el mapa no espera a la E/S asíncrona del sistema.
    try {
      if (!_index.existsSync()) return const [];
      final raw = jsonDecode(_index.readAsStringSync()) as List<dynamic>;
      return [for (final item in raw) BasemapInfo.fromJson(item as Map<String, dynamic>)];
    } on Object {
      // Sin índice o ilegible: no hay nada descargado que mostrar.
      return const [];
    }
  }

  Future<void> _writeIndex(List<BasemapInfo> infos) async {
    await directory.create(recursive: true);
    await _index.writeAsString(jsonEncode([for (final i in infos) i.toJson()]));
  }

  static Future<String> _sha256(File file) async => (await sha256.bind(file.openRead()).first).toString();

  static Future<void> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Ya no está o no se puede borrar: no impide seguir.
    }
  }
}
