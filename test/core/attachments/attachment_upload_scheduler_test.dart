// `AttachmentUploadScheduler` (Paso 18): cuándo se drena la cola, sin dos
// drenajes a la vez y sin perder un disparo que llega a mitad.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/attachments/attachment_result.dart';
import 'package:visitacampo/core/attachments/attachment_transport.dart';
import 'package:visitacampo/core/attachments/attachment_upload_scheduler.dart';
import 'package:visitacampo/core/attachments/attachment_upload_service.dart';
import 'package:visitacampo/data/local/database.dart';

import 'fake_attachment_transport.dart';
import 'fake_file_source.dart';

/// Transporte cuyo presign se queda esperando hasta que el test lo suelta.
class _GatedTransport extends FakeAttachmentTransport {
  Completer<void> gate = Completer<void>();
  int presignCalls = 0;

  @override
  Future<AttachmentResult<PresignData>> presign({
    required String sha256,
    required int size,
    required String mime,
  }) async {
    presignCalls++;
    await gate.future;
    return const AttachmentResult.ok(PresignData(alreadyPresent: true));
  }

  @override
  Future<AttachmentResult<void>> commit({required String sha256, required int size, required String mime}) async =>
      const AttachmentResult.ok(null);
}

/// Servicio cuyo primer drenaje falla como fallaría la BD local.
class _ThrowingOnceService extends AttachmentUploadService {
  _ThrowingOnceService(AppDatabase db, AttachmentTransport transport)
    : super(db: db, transport: transport, files: FakeFileSource({'/f/1.jpg': [1, 2, 3]}));

  var _thrown = false;

  @override
  Future<AttachmentDrainReport> drainPending({bool force = false}) {
    if (!_thrown) {
      _thrown = true;
      throw StateError('disco lleno');
    }
    return super.drainPending(force: force);
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.callback);
  final void Function(Timer) callback;
  bool cancelled = false;

  void fire() => callback(this);

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

void main() {
  late AppDatabase db;
  late _GatedTransport transport;
  late AttachmentUploadService service;
  late bool authenticated;
  _FakeTimer? timer;
  late AttachmentUploadScheduler scheduler;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    transport = _GatedTransport();
    service = AttachmentUploadService(
      db: db,
      transport: transport,
      files: FakeFileSource({'/f/1.jpg': [1, 2, 3], '/f/2.jpg': [4, 5, 6]}),
    );
    authenticated = true;
    timer = null;
    scheduler = AttachmentUploadScheduler(
      service: service,
      isAuthenticated: () => authenticated,
      periodic: (interval, callback) => timer = _FakeTimer(callback),
    );
  });
  tearDown(() async {
    scheduler.stop();
    await db.close();
  });

  Future<void> enqueue(String sha, String path, {String state = 'pending'}) => db
      .into(db.attachmentQueue)
      .insert(AttachmentQueueCompanion.insert(sha256: sha, localPath: path, state: state, createdAt: DateTime.utc(2026)));

  test('dos disparos a la vez: un solo drenaje, y otro encadenado al terminar', () async {
    await enqueue('a' * 64, '/f/1.jpg');
    final first = scheduler.nudge();
    // Mientras el primero espera al servidor, llega una foto nueva y otro disparo.
    await Future<void>.delayed(Duration.zero);
    await enqueue('b' * 64, '/f/2.jpg');
    final second = scheduler.nudge();
    expect(identical(first, second), isTrue, reason: 'el segundo disparo se une al drenaje en curso');

    transport.gate.complete();
    final report = await second;

    expect(transport.presignCalls, 2, reason: 'cada foto una vez; nunca dos drenajes solapados');
    expect(report.uploaded, 1, reason: 'el encadenado subió la foto que llegó a mitad');
    final states = (await db.select(db.attachmentQueue).get()).map((r) => r.state).toSet();
    expect(states, {'uploaded'});
  });

  test('sin sesión no se intenta nada', () async {
    authenticated = false;
    await enqueue('a' * 64, '/f/1.jpg');
    transport.gate.complete();

    await scheduler.nudge();

    expect(transport.presignCalls, 0);
  });

  test('start: recupera las subidas interrumpidas, drena, y programa el periódico', () async {
    await enqueue('a' * 64, '/f/1.jpg', state: 'uploading');
    transport.gate.complete();
    final drained = <AttachmentDrainReport>[];
    final sub = scheduler.drained.listen(drained.add);

    await scheduler.start();
    await Future<void>.delayed(Duration.zero);

    expect(transport.presignCalls, 1, reason: 'el uploading huérfano volvió a pending y se subió');
    expect(scheduler.isStarted, isTrue);
    expect(drained.single.uploaded, 1);

    // El temporizador periódico dispara otro drenaje.
    await enqueue('b' * 64, '/f/2.jpg');
    timer!.fire();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(transport.presignCalls, 2);

    scheduler.stop();
    expect(timer!.cancelled, isTrue);
    await sub.cancel();
  });

  test('un drenaje que lanza no escapa como error no controlado y el siguiente funciona', () async {
    final errors = <Object>[];
    final broken = AttachmentUploadScheduler(
      service: _ThrowingOnceService(db, transport),
      isAuthenticated: () => true,
      periodic: (interval, callback) => _FakeTimer(callback),
    )..onError = (error, _) => errors.add(error);
    transport.gate.complete();
    await enqueue('a' * 64, '/f/1.jpg');

    expect((await broken.nudge()).uploaded, 0, reason: 'informe vacío, sin excepción');
    expect(errors.single, isA<StateError>());

    expect((await broken.nudge()).uploaded, 1, reason: 'el siguiente disparo reintenta');
  });

  test('start es idempotente', () async {
    transport.gate.complete();
    await scheduler.start();
    final firstTimer = timer;
    await scheduler.start();
    expect(identical(timer, firstTimer), isTrue);
  });
}
