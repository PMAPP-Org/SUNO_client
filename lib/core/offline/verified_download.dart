// Descarga verificable y reanudable de un archivo del servidor (mapas base,
// capas de referencia).
//
// - Lo recibido va a `<destino>.part`; si la red se corta, el siguiente
//   intento continúa desde ahí (`from`), sin empezar de cero.
// - El archivo **solo se activa** (se renombra al destino) si su tamaño y su
//   `sha256` coinciden con lo que anunció el servidor; si no, se descarta.
// - Una parte más grande de lo anunciado se descarta; una completa solo se
//   verifica; sin espacio, la parte se libera.
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Descarga [url] en [path] desde el byte [from]. Lanza si falla.
typedef ResumableFetch =
    Future<void> Function(String url, String path, {int from, void Function(int received, int total)? onProgress});

sealed class OfflineDownloadResult {
  const OfflineDownloadResult();
}

final class OfflineDownloaded extends OfflineDownloadResult {
  const OfflineDownloaded();
}

/// Sin red, o el servidor no dio la URL.
final class OfflineUnavailable extends OfflineDownloadResult {
  const OfflineUnavailable();
}

/// Lo descargado no coincide con el `sha256`/tamaño anunciado: se descartó.
final class OfflineCorrupted extends OfflineDownloadResult {
  const OfflineCorrupted();
}

/// No cupo o no se pudo escribir en el teléfono.
final class OfflineNoSpace extends OfflineDownloadResult {
  const OfflineNoSpace();
}

/// El `sha256` como nombre de archivo, validado: no hay ruta que inyectar.
String checkedSha256(String sha256) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) throw ArgumentError.value(sha256, 'sha256');
  return sha256;
}

Future<OfflineDownloadResult> downloadVerified({
  required String? url,
  required File target,
  required int size,
  required String sha256,
  required ResumableFetch fetch,
  void Function(int received, int total)? onProgress,
}) async {
  if (url == null) return const OfflineUnavailable();
  await target.parent.create(recursive: true);
  final partial = File('${target.path}.part');
  var have = partial.existsSync() ? partial.lengthSync() : 0;
  if (have > size) {
    await deleteQuietly(partial.path);
    have = 0;
  }
  if (have < size) {
    try {
      await fetch(url, partial.path, from: have, onProgress: onProgress);
    } on FileSystemException {
      await deleteQuietly(partial.path);
      return const OfflineNoSpace();
    } on Object {
      // Corte de red: la parte se queda para continuar en el próximo intento.
      return const OfflineUnavailable();
    }
  }
  if (!partial.existsSync() || await partial.length() != size || await sha256Of(partial) != sha256) {
    await deleteQuietly(partial.path);
    return const OfflineCorrupted();
  }
  await partial.rename(target.path);
  return const OfflineDownloaded();
}

Future<String> sha256Of(File file) async => (await sha256.bind(file.openRead()).first).toString();

Future<void> deleteQuietly(String path) async {
  try {
    final file = File(path);
    if (file.existsSync()) await file.delete();
  } on FileSystemException {
    // Ya no está o no se puede borrar: no impide seguir.
  }
}
