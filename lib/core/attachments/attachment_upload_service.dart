// `AttachmentUploadService` — la cola de subida de adjuntos (Paso 18).
//
// Sube el **blob** de cada fila de `AttachmentQueue` (presign → `PUT` en
// streaming → commit). La fila `visit_attachment` que lo enlaza con su visita
// viaja aparte, por el outbox de datos (Paso 22): las dos colas son
// **independientes** (doc 08 §4.2, ADR-003). Una foto atascada no bloquea el
// push de su visita, y una visita rechazada no impide subir sus fotos.
//
// Máquina de estados por fila:
//
//   pending ──(debida)──▶ uploading ──▶ uploaded
//      ▲                     │
//      └── fallo transitorio ┤  (red, 5xx, 408/429, 401/403)
//          + backoff         │
//                            └── fallo permanente ──▶ failed ──(reintento del agente)──▶ pending
//                               (archivo ausente, 4xx de validación o checksum)
//
// - El backoff (exponencial con jitter) se **persiste** en la fila
//   (`attempts`, `nextAttemptAt`): cerrar y abrir la app no lo reinicia.
// - Cada fila es independiente: un fallo en una no detiene el resto del lote.
// - El archivo se lee en streaming y se cierra **siempre** en un `finally`
//   (RD-05, corrige H-05 en el cliente).
// - No se envía `visit_id` al presign (contrato: opcional): la cuota por
//   visita exigiría que la visita ya estuviera en el servidor, y eso ataría
//   esta cola al push de datos.
import 'package:drift/drift.dart';

import '../../data/local/database.dart';
import '../sync/backoff.dart';
import 'attachment_result.dart';
import 'attachment_transport.dart';
import 'upload_file_source.dart';

class AttachmentDrainReport {
  const AttachmentDrainReport({required this.uploaded, required this.failed, this.deferred = 0});

  static const empty = AttachmentDrainReport(uploaded: 0, failed: 0);

  /// Subidos y confirmados en este drenaje.
  final int uploaded;

  /// Fallos permanentes: necesitan que el agente actúe (`retryFailed`).
  final int failed;

  /// Fallos transitorios: se reintentan solos tras su backoff.
  final int deferred;
}

/// Cómo terminó un intento de subida.
enum _Outcome { uploaded, transient, permanent }

class AttachmentUploadService {
  AttachmentUploadService({
    required this.db,
    required this.transport,
    UploadFileSource? files,
    BackoffPolicy? backoff,
    DateTime Function()? clock,
  }) : files = files ?? const IoUploadFileSource(),
       backoff =
           backoff ??
           const ExponentialBackoffWithJitter(
             base: Duration(seconds: 15),
             max: Duration(minutes: 30),
             jitterMax: Duration(seconds: 10),
           ),
       _now = clock ?? DateTime.now;

  final AppDatabase db;
  final AttachmentTransport transport;
  final UploadFileSource files;
  final BackoffPolicy backoff;
  final DateTime Function() _now;

  static const _pending = 'pending';
  static const _uploading = 'uploading';
  static const _uploaded = 'uploaded';
  static const _failed = 'failed';

  /// Sube las filas **debidas**: `pending` cuyo backoff ya venció. Las
  /// `failed` no se tocan; esperan a [retryFailed].
  ///
  /// [force]: el agente pulsó "Sincronizar". Es una petición explícita de
  /// intentarlo ya (acaba de recuperar señal, por ejemplo), así que se ignora
  /// el backoff y se reintentan también las `failed`. Los disparos
  /// automáticos nunca fuerzan.
  Future<AttachmentDrainReport> drainPending({bool force = false}) async {
    final now = _now();
    final due =
        await (db.select(db.attachmentQueue)
              ..where(
                (t) => force
                    ? t.state.isIn(const [_pending, _failed])
                    : t.state.equals(_pending) &
                          (t.nextAttemptAt.isNull() | t.nextAttemptAt.isSmallerOrEqualValue(now)),
              )
              ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
            .get();

    var uploaded = 0, failed = 0, deferred = 0;
    for (final row in due) {
      switch (await _drainOne(row)) {
        case _Outcome.uploaded:
          uploaded++;
        case _Outcome.transient:
          deferred++;
        case _Outcome.permanent:
          failed++;
      }
    }
    return AttachmentDrainReport(uploaded: uploaded, failed: failed, deferred: deferred);
  }

  /// Adjuntos que todavía no están en el servidor (por subir o fallidos).
  Future<int> outstanding() async =>
      (await (db.select(db.attachmentQueue)..where((t) => t.state.isNotValue(_uploaded))).get()).length;

  /// `uploading` huérfanos (la app murió a mitad de una subida) → `pending`.
  /// Se llama al arrancar, antes del primer drenaje. Devuelve cuántos hubo.
  Future<int> recoverInterrupted() =>
      (db.update(db.attachmentQueue)..where((t) => t.state.equals(_uploading))).write(
        const AttachmentQueueCompanion(state: Value(_pending)),
      );

  /// Reintento explícito del agente: `failed → pending`, sin esperar backoff.
  Future<void> retryFailed(String sha256) =>
      (db.update(db.attachmentQueue)..where((t) => t.sha256.equals(sha256) & t.state.equals(_failed))).write(
        const AttachmentQueueCompanion(
          state: Value(_pending),
          attempts: Value(0),
          nextAttemptAt: Value(null),
          lastError: Value(null),
        ),
      );

  Future<_Outcome> _drainOne(AttachmentQueueData row) async {
    await _setState(row.sha256, _uploading);

    final size = await files.length(row.localPath);
    if (size == null) {
      // Archivo borrado o ilegible: reintentar no lo traerá de vuelta.
      return _permanent(row, 'El archivo ya no está en el teléfono.');
    }

    final presign = await transport.presign(sha256: row.sha256, size: size, mime: row.mime);
    switch (presign) {
      case AttachmentErr(:final error):
        return _fail(row, error, 'presign');
      case AttachmentOk(value: final data) when data.alreadyPresent:
        // Dedup: el servidor ya tiene ese contenido. Se confirma sin subir bytes.
        break;
      case AttachmentOk(value: final data):
        final uploadUrl = data.uploadUrl;
        if (uploadUrl == null) {
          return _transient(row, 'El servidor no devolvió URL de subida.');
        }
        final body = GuardedUploadStream(files.openRead(row.localPath));
        final AttachmentResult<void> upload;
        try {
          upload = await transport.upload(
            uploadUrl: uploadUrl,
            headers: data.requiredHeaders ?? const {},
            body: body.stream,
            length: size,
          );
        } on Object {
          // Un fallo inesperado del cliente HTTP es transitorio: el archivo
          // sigue ahí y se volverá a intentar.
          return _transient(row, 'Fallo inesperado al subir.');
        } finally {
          await body.close();
        }
        if (upload case AttachmentErr(:final error)) {
          return _fail(row, error, 'upload');
        }
    }

    final commit = await transport.commit(sha256: row.sha256, size: size, mime: row.mime);
    if (commit case AttachmentErr(:final error)) {
      return _fail(row, error, 'commit');
    }
    await (db.update(db.attachmentQueue)..where((t) => t.sha256.equals(row.sha256))).write(
      const AttachmentQueueCompanion(state: Value(_uploaded), nextAttemptAt: Value(null), lastError: Value(null)),
    );
    return _Outcome.uploaded;
  }

  /// Transitorio o permanente según el error.
  Future<_Outcome> _fail(AttachmentQueueData row, AttachmentError error, String phase) => switch (error) {
    AttachmentNetworkError() => _transient(row, 'Sin conexión ($phase).'),
    AttachmentMalformedResponse() => _transient(row, 'Respuesta del servidor no reconocida ($phase).'),
    AttachmentUnexpectedStatus(:final statusCode) when isTransientStatus(statusCode) => _transient(
      row,
      'El servidor respondió $statusCode ($phase).',
    ),
    AttachmentUnexpectedStatus(:final statusCode) => _permanent(
      row,
      'El servidor rechazó el archivo ($statusCode, $phase).',
    ),
  };

  /// 5xx, 408 y 429 son transitorios. 401/403 también: en la API el token se
  /// renueva en el siguiente intento, y en el `PUT` la URL firmada pudo
  /// caducar (el siguiente intento pide otra). El resto de 4xx (validación,
  /// tamaño, MIME, checksum) no se arregla reintentando el mismo archivo.
  static bool isTransientStatus(int status) =>
      status >= 500 || status == 408 || status == 429 || status == 401 || status == 403;

  Future<_Outcome> _transient(AttachmentQueueData row, String reason) async {
    await (db.update(db.attachmentQueue)..where((t) => t.sha256.equals(row.sha256))).write(
      AttachmentQueueCompanion(
        state: const Value(_pending),
        attempts: Value(row.attempts + 1),
        nextAttemptAt: Value(_now().add(backoff.delayFor(row.attempts))),
        lastError: Value(reason),
      ),
    );
    return _Outcome.transient;
  }

  Future<_Outcome> _permanent(AttachmentQueueData row, String reason) async {
    await (db.update(db.attachmentQueue)..where((t) => t.sha256.equals(row.sha256))).write(
      AttachmentQueueCompanion(
        state: const Value(_failed),
        attempts: Value(row.attempts + 1),
        nextAttemptAt: const Value(null),
        lastError: Value(reason),
      ),
    );
    return _Outcome.permanent;
  }

  Future<void> _setState(String sha256, String state) =>
      (db.update(db.attachmentQueue)..where((t) => t.sha256.equals(sha256))).write(
        AttachmentQueueCompanion(state: Value(state)),
      );
}
