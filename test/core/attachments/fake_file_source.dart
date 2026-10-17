// `UploadFileSource` en memoria que **cuenta aperturas y cierres** (Paso 18,
// regresión de H-05): un archivo cuenta como abierto cuando alguien escucha su
// stream, y como cerrado cuando el stream termina o se cancela. Al final de
// cada test, [openNow] tiene que volver a 0.
import 'dart:async';

import 'package:visitacampo/core/attachments/upload_file_source.dart';

class FakeFileSource implements UploadFileSource {
  FakeFileSource([Map<String, List<int>>? files]) : files = files ?? {};

  final Map<String, List<int>> files;

  /// Tamaño de los trozos del stream (para forzar varios trozos por archivo).
  int chunkSize = 4;

  int opened = 0;
  int closed = 0;
  int get openNow => opened - closed;

  @override
  Future<int?> length(String path) async => files[path]?.length;

  @override
  Stream<List<int>> openRead(String path) {
    final bytes = files[path];
    if (bytes == null) return Stream.error(StateError('no existe: $path'));
    late StreamController<List<int>> controller;
    var isClosed = false;
    // Un solo cierre por apertura, termine leyendo todo o cancelado:
    // `StreamController` llama también a `onCancel` tras el evento de fin.
    void markClosed() {
      if (isClosed) return;
      isClosed = true;
      closed++;
    }

    controller = StreamController<List<int>>(
      onListen: () async {
        opened++;
        for (var i = 0; i < bytes.length && !isClosed; i += chunkSize) {
          controller.add(bytes.sublist(i, i + chunkSize > bytes.length ? bytes.length : i + chunkSize));
          await Future<void>.delayed(Duration.zero);
        }
        if (!isClosed) {
          markClosed();
          await controller.close();
        }
      },
      onCancel: markClosed,
    );
    return controller.stream;
  }
}
