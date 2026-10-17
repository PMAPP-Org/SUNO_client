// `AttachmentUploadService` (Paso 18): la cola de subida con reintento.
//
// Comandos de verificación del plan: (a) subida correcta → `uploaded`;
// (b) fallo de red → reintento con backoff sin bloquear el resto de la cola;
// (c) `already_present` → `uploaded` sin subir bytes. Y el test de recursos
// (regresión de H-05): todo archivo abierto se cierra, también si la subida
// se corta a mitad.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/attachments/attachment_result.dart';
import 'package:visitacampo/core/attachments/attachment_transport.dart';
import 'package:visitacampo/core/attachments/attachment_upload_service.dart';
import 'package:visitacampo/core/sync/backoff.dart';
import 'package:visitacampo/data/local/database.dart';

import 'fake_attachment_transport.dart';
import 'fake_file_source.dart';

/// Backoff determinista: 1 min × 2^intento, sin jitter.
class _FixedBackoff implements BackoffPolicy {
  @override
  Duration delayFor(int attempt) => Duration(minutes: 1 << attempt);
}

const _photo = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];

PresignData _uploadTo([String url = 'https://blob.test/put']) =>
    PresignData(alreadyPresent: false, uploadUrl: url, requiredHeaders: const {'x-amz-checksum-sha256': 'abc'});

void main() {
  late AppDatabase db;
  late FakeAttachmentTransport transport;
  late FakeFileSource files;
  late DateTime now;
  late AttachmentUploadService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = FakeAttachmentTransport();
    files = FakeFileSource({'/fotos/a.jpg': _photo, '/fotos/b.jpg': _photo.reversed.toList()});
    now = DateTime.utc(2026, 10, 17, 10);
    service = AttachmentUploadService(
      db: db,
      transport: transport,
      files: files,
      backoff: _FixedBackoff(),
      clock: () => now,
    );
  });

  tearDown(() async {
    expect(files.openNow, 0, reason: 'H-05: ningún archivo queda abierto');
    await db.close();
  });

  Future<void> enqueue(String sha, String path, {String state = 'pending'}) => db
      .into(db.attachmentQueue)
      .insert(
        AttachmentQueueCompanion.insert(sha256: sha, localPath: path, state: state, createdAt: DateTime.utc(2026, 10, 17)),
      );

  Future<AttachmentQueueData> row(String sha) =>
      (db.select(db.attachmentQueue)..where((t) => t.sha256.equals(sha))).getSingle();

  test('(a) sube en streaming, confirma y marca uploaded', () async {
    await enqueue('a' * 64, '/fotos/a.jpg');
    transport.presignResponses.add(AttachmentResult.ok(_uploadTo()));
    transport.uploadResponses.add(const AttachmentResult.ok(null));
    transport.commitResponses.add(const AttachmentResult.ok(null));

    final report = await service.drainPending();

    expect((report.uploaded, report.failed, report.deferred), (1, 0, 0));
    expect(transport.uploadedBytes.single, _photo, reason: 'llegó el contenido entero, por trozos');
    expect(transport.uploadedLengths.single, _photo.length, reason: 'Content-Length = tamaño del archivo');
    expect(files.opened, 1);
    final r = await row('a' * 64);
    expect((r.state, r.attempts, r.lastError), ('uploaded', 0, null));
  });

  test('(c) already_present: se confirma sin subir ni abrir el archivo', () async {
    await enqueue('a' * 64, '/fotos/a.jpg');
    transport.presignResponses.add(const AttachmentResult.ok(PresignData(alreadyPresent: true)));
    transport.commitResponses.add(const AttachmentResult.ok(null));

    final report = await service.drainPending();

    expect(report.uploaded, 1);
    expect(transport.uploadedBytes, isEmpty);
    expect(files.opened, 0, reason: 'dedup: ni un byte leído');
    expect(transport.committedShas, ['a' * 64]);
    expect((await row('a' * 64)).state, 'uploaded');
  });

  test('(b) fallo de red: backoff persistido y el resto de la cola sigue', () async {
    await enqueue('a' * 64, '/fotos/a.jpg');
    await enqueue('b' * 64, '/fotos/b.jpg');
    transport.presignResponses
      ..add(const AttachmentResult.err(AttachmentError.network('sin señal')))
      ..add(AttachmentResult.ok(_uploadTo()));
    transport.uploadResponses.add(const AttachmentResult.ok(null));
    transport.commitResponses.add(const AttachmentResult.ok(null));

    final report = await service.drainPending();
    expect((report.uploaded, report.deferred), (1, 1), reason: 'una foto atascada no frena a la otra');

    final failed = await row('a' * 64);
    expect(failed.state, 'pending', reason: 'transitorio: se reintentará solo');
    expect(failed.attempts, 1);
    expect(failed.nextAttemptAt!.toUtc(), now.add(const Duration(minutes: 1)));
    expect(failed.lastError, contains('Sin conexión'));
    expect((await row('b' * 64)).state, 'uploaded');

    // Antes de que venza el backoff no se reintenta (ni siquiera el presign).
    now = now.add(const Duration(seconds: 59));
    expect((await service.drainPending()).deferred, 0);
    expect(transport.presignedShas, hasLength(2));

    // Vencido: se reintenta; un segundo fallo dobla la espera.
    now = now.add(const Duration(seconds: 1));
    transport.presignResponses.add(const AttachmentResult.err(AttachmentError.unexpectedStatus(503, '')));
    await service.drainPending();
    final again = await row('a' * 64);
    expect(again.attempts, 2);
    expect(again.nextAttemptAt!.toUtc(), now.add(const Duration(minutes: 2)));
  });

  test('un backoff sobrevive a reiniciar la app (otra instancia del servicio)', () async {
    await enqueue('a' * 64, '/fotos/a.jpg');
    transport.presignResponses.add(const AttachmentResult.err(AttachmentError.network('sin señal')));
    await service.drainPending();

    final restarted = AttachmentUploadService(
      db: db,
      transport: transport,
      files: files,
      backoff: _FixedBackoff(),
      clock: () => now,
    );
    expect((await restarted.drainPending()).deferred, 0, reason: 'no reintenta en ráfaga al abrir la app');
    expect(transport.presignedShas, hasLength(1));
  });

  test('H-05: si la subida se corta a mitad, el archivo se cierra igual', () async {
    await enqueue('a' * 64, '/fotos/a.jpg');
    files.chunkSize = 2;
    transport
      ..abandonUploadAfterFirstChunk = true
      ..presignResponses.add(AttachmentResult.ok(_uploadTo()));

    final report = await service.drainPending();

    expect(report.deferred, 1);
    expect(files.opened, 1);
    expect(files.closed, 1, reason: 'cerrado en el finally aunque el cliente HTTP lo abandonó');
  });

  test('un fallo inesperado del cliente HTTP es transitorio y también cierra el archivo', () async {
    await enqueue('a' * 64, '/fotos/a.jpg');
    // Sin respuesta programada: el fake lanza tras leer el stream.
    transport.presignResponses.add(AttachmentResult.ok(_uploadTo()));

    final report = await service.drainPending();

    expect(report.deferred, 1);
    expect((await row('a' * 64)).state, 'pending');
  });

  test('archivo borrado del teléfono: fallo permanente, sin llamar al servidor', () async {
    await enqueue('a' * 64, '/fotos/borrada.jpg');

    final report = await service.drainPending();

    expect(report.failed, 1);
    expect(transport.presignedShas, isEmpty);
    final r = await row('a' * 64);
    expect(r.state, 'failed');
    expect(r.lastError, contains('ya no está'));
  });

  test('4xx de validación es permanente; 401, 403, 408, 429 y 5xx son transitorios', () {
    for (final status in [400, 404, 409, 413, 415, 422]) {
      expect(AttachmentUploadService.isTransientStatus(status), isFalse, reason: '$status');
    }
    for (final status in [401, 403, 408, 429, 500, 502, 503]) {
      expect(AttachmentUploadService.isTransientStatus(status), isTrue, reason: '$status');
    }
  });

  test('un checksum que no coincide en el commit deja la foto en failed', () async {
    await enqueue('a' * 64, '/fotos/a.jpg');
    transport.presignResponses.add(AttachmentResult.ok(_uploadTo()));
    transport.uploadResponses.add(const AttachmentResult.ok(null));
    transport.commitResponses.add(const AttachmentResult.err(AttachmentError.unexpectedStatus(422, 'checksum')));

    final report = await service.drainPending();

    expect(report.failed, 1);
    final r = await row('a' * 64);
    expect(r.state, 'failed');
    expect(r.lastError, isNot(contains('checksum')), reason: 'RD-12: no se guarda el cuerpo de la respuesta');
  });

  test('las failed no se reintentan solas; retryFailed las vuelve a pending', () async {
    await enqueue('a' * 64, '/fotos/a.jpg', state: 'failed');
    expect((await service.drainPending()).uploaded, 0);
    expect(transport.presignedShas, isEmpty);

    await service.retryFailed('a' * 64);
    final r = await row('a' * 64);
    expect((r.state, r.attempts, r.nextAttemptAt), ('pending', 0, null));

    transport.presignResponses.add(const AttachmentResult.ok(PresignData(alreadyPresent: true)));
    transport.commitResponses.add(const AttachmentResult.ok(null));
    expect((await service.drainPending()).uploaded, 1);
  });

  test('recoverInterrupted: un uploading que la app dejó a medias vuelve a pending', () async {
    await enqueue('a' * 64, '/fotos/a.jpg', state: 'uploading');
    await enqueue('b' * 64, '/fotos/b.jpg', state: 'uploaded');

    expect(await service.recoverInterrupted(), 1);
    expect((await row('a' * 64)).state, 'pending');
    expect((await row('b' * 64)).state, 'uploaded');
  });

  test('una fila con backoff futuro y otra debida: solo se intenta la debida', () async {
    await enqueue('a' * 64, '/fotos/a.jpg');
    await enqueue('b' * 64, '/fotos/b.jpg');
    await (db.update(db.attachmentQueue)..where((t) => t.sha256.equals('a' * 64))).write(
      AttachmentQueueCompanion(nextAttemptAt: Value(now.add(const Duration(hours: 1)))),
    );
    transport.presignResponses.add(const AttachmentResult.ok(PresignData(alreadyPresent: true)));
    transport.commitResponses.add(const AttachmentResult.ok(null));

    await service.drainPending();

    expect(transport.presignedShas, ['b' * 64]);
  });
}
