// De dónde lee la subida los bytes de un adjunto (Paso 18).
//
// La subida **no** carga el archivo entero en memoria: lo lee en streaming y
// lo envía por `PUT` a medida que se lee. Este puerto existe para dos cosas:
// que la implementación real sea `File.openRead` (sin buffers de 10 MB por
// foto), y que un test pueda contar aperturas y cierres del archivo, incluido
// el camino de error (regresión de H-05: en QFieldCloud un multipart armado
// en memoria dejaba recursos sin cerrar al fallar la subida).
import 'dart:async';
import 'dart:io';

abstract interface class UploadFileSource {
  /// Tamaño en bytes, o `null` si el archivo no existe o no se puede leer.
  Future<int?> length(String path);

  /// Contenido del archivo como stream. El archivo se abre al escucharlo y se
  /// cierra al terminar o al cancelar la suscripción.
  Stream<List<int>> openRead(String path);
}

class IoUploadFileSource implements UploadFileSource {
  const IoUploadFileSource();

  @override
  Future<int?> length(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Stream<List<int>> openRead(String path) => File(path).openRead();
}

/// Envuelve un stream de lectura para poder **garantizar** que se cierra.
///
/// Un cliente HTTP puede abandonar el cuerpo a mitad (timeout, conexión
/// cortada) sin cancelar la suscripción. [close] cancela la lectura si sigue
/// abierta y se llama siempre en un `finally`; es idempotente.
class GuardedUploadStream {
  GuardedUploadStream(Stream<List<int>> source) : _source = source {
    _controller = StreamController<List<int>>(
      onListen: _start,
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: close,
    );
  }

  final Stream<List<int>> _source;
  late final StreamController<List<int>> _controller;
  StreamSubscription<List<int>>? _subscription;
  bool _closed = false;

  Stream<List<int>> get stream => _controller.stream;

  void _start() {
    _subscription = _source.listen(
      _controller.add,
      onError: _controller.addError,
      onDone: () {
        _subscription = null;
        unawaited(_controller.close());
      },
      cancelOnError: true,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    // Sin `await`: `close()` también se llama desde `onCancel`, y esperar ahí
    // a que el propio controlador termine de cerrarse no acabaría nunca.
    if (!_controller.isClosed) unawaited(_controller.close());
  }
}
