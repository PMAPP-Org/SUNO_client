// Fake de `AttachmentTransport` — mismo patrón que `FakeSyncTransport`
// (`test/core/sync/fake_sync_transport.dart`): cola de respuestas
// programables, sin red real.
//
// `upload()` **consume el stream** como lo haría un cliente HTTP real. Con
// `abandonUploadAfterFirstChunk` deja de leer tras el primer trozo y devuelve
// un error **sin cancelar la suscripción**: el caso de un cliente HTTP que se
// corta a mitad. Así se prueba que el servicio cierra el archivo igualmente.
import 'dart:async';

import 'package:visitacampo/core/attachments/attachment_result.dart';
import 'package:visitacampo/core/attachments/attachment_transport.dart';

class FakeAttachmentTransport implements AttachmentTransport {
  final List<AttachmentResult<PresignData>> presignResponses = [];
  final List<AttachmentResult<void>> uploadResponses = [];
  final List<AttachmentResult<void>> commitResponses = [];

  final List<String> presignedShas = [];
  final List<String> committedShas = [];

  /// Lo que llegó en cada `upload()`, ya leído del stream.
  final List<List<int>> uploadedBytes = [];
  final List<int> uploadedLengths = [];

  bool abandonUploadAfterFirstChunk = false;

  @override
  Future<AttachmentResult<PresignData>> presign({
    required String sha256,
    required int size,
    required String mime,
  }) async {
    presignedShas.add(sha256);
    if (presignResponses.isEmpty) {
      throw StateError('FakeAttachmentTransport.presign() sin respuesta programada.');
    }
    return presignResponses.removeAt(0);
  }

  @override
  Future<AttachmentResult<void>> upload({
    required String uploadUrl,
    required Map<String, String> headers,
    required Stream<List<int>> body,
    required int length,
  }) async {
    uploadedLengths.add(length);
    if (abandonUploadAfterFirstChunk) {
      final firstChunk = Completer<void>();
      // Se escucha y se deja la suscripción colgada a propósito.
      body.listen((_) {
        if (!firstChunk.isCompleted) firstChunk.complete();
      });
      await firstChunk.future;
      return const AttachmentResult.err(AttachmentError.network('conexión cortada a mitad'));
    }
    final bytes = <int>[];
    await for (final chunk in body) {
      bytes.addAll(chunk);
    }
    uploadedBytes.add(bytes);
    if (uploadResponses.isEmpty) {
      throw StateError('FakeAttachmentTransport.upload() sin respuesta programada.');
    }
    return uploadResponses.removeAt(0);
  }

  @override
  Future<AttachmentResult<void>> commit({
    required String sha256,
    required int size,
    required String mime,
  }) async {
    committedShas.add(sha256);
    if (commitResponses.isEmpty) {
      throw StateError('FakeAttachmentTransport.commit() sin respuesta programada.');
    }
    return commitResponses.removeAt(0);
  }
}
