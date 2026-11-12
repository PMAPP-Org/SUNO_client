// Criterio de salida del Paso 18: la cola de adjuntos y el outbox de datos son
// **independientes** (doc 08 §4.2, ADR-003). Un registro con fotos que no
// suben se sincroniza igual, y un registro rechazado no impide subir sus fotos.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/attachments/attachment_result.dart';
import 'package:suno/core/attachments/attachment_transport.dart';
import 'package:suno/core/attachments/attachment_upload_service.dart';
import 'package:suno/core/capture/record_capture.dart';
import 'package:suno/core/forms/form_definition.dart';
import 'package:suno/core/sync/result.dart';
import 'package:suno/core/sync/sync_engine.dart';
import 'package:suno/core/sync/sync_transport.dart';
import 'package:suno/data/local/database.dart';
import 'package:suno/data/local/record_status_repository.dart';

import '../sync/fake_sync_transport.dart';
import 'fake_attachment_transport.dart';
import 'fake_file_source.dart';

FormDefinition _definition() =>
    (parseFormDefinition({
              'fields': [
                {
                  'key': 'foto',
                  'type': 'photo',
                  'label': {'es': 'Foto'},
                },
              ],
            })
            as DefinitionOk)
        .definition;

void main() {
  late AppDatabase db;
  late FakeSyncTransport sync;
  late FakeAttachmentTransport attachments;
  late SyncEngine engine;
  late AttachmentUploadService uploads;
  late String recordId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    sync = FakeSyncTransport();
    attachments = FakeAttachmentTransport();
    engine = SyncEngine(db: db, transport: sync, deviceId: 'device-1');
    uploads = AttachmentUploadService(
      db: db,
      transport: attachments,
      files: FakeFileSource({'/fotos/1.jpg': const [1, 2, 3, 4]}),
    );
    final photo = PendingAttachment(
      id: '0192f0e2-8a6b-7c3d-9e4f-5a6b7c8d9e0f',
      sha256: 'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00',
      localPath: '/fotos/1.jpg',
      mime: 'image/jpeg',
      role: 'foto',
      capturedAt: DateTime.utc(2026, 10, 17, 9),
    );
    recordId = await RecordCapture(db: db).save(
      identity: const CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1'),
      templateVersionId: 'tv-1',
      definition: _definition(),
      answers: {'foto': photo.id},
      captured: {photo.id: photo},
    );
  });
  tearDown(() => db.close());

  Future<PushResponse> allApplied() async {
    final ops = await db.select(db.outboxOps).get();
    return PushResponse(
      schemaVersion: 2,
      results: [for (final op in ops) PushOpOutcome(opUuid: op.opUuid, status: 'applied', serverVersion: 1)],
    );
  }

  test('el registro y su adjunto se sincronizan aunque la foto no pueda subirse', () async {
    // El object storage está caído: la foto no sube.
    attachments.presignResponses.add(const AttachmentResult.err(AttachmentError.unexpectedStatus(503, '')));
    expect((await uploads.drainPending()).deferred, 1);

    // El push de datos no espera a la foto: registro y `record_attachment` se aplican.
    sync.pushResponses.add(Result.ok(await allApplied()));
    final report = await engine.drainOutbox();
    expect(report.applied, 2);
    expect(await db.select(db.outboxOps).get(), isEmpty);

    // El agente ve el registro sincronizado, con la foto todavía por subir.
    final summary = (await RecordStatusRepository(db).recentRecords(orgId: 'org-1')).single;
    expect((summary.id, summary.status, summary.pendingUploads), (recordId, RecordSyncStatus.synced, 1));
  });

  test('la foto sube aunque el servidor rechace el registro', () async {
    final ops = await db.select(db.outboxOps).get();
    sync.pushResponses.add(
      Result.ok(
        PushResponse(
          schemaVersion: 2,
          results: [
            for (final op in ops)
              PushOpOutcome(
                opUuid: op.opUuid,
                status: 'rejected',
                error: const PushOpError(code: 'validation_error', message: 'Respuestas no válidas'),
              ),
          ],
        ),
      ),
    );
    expect((await engine.drainOutbox()).quarantined, 2);

    // La cola de adjuntos no sabe nada del rechazo: la foto se sube igual, y
    // estará en el servidor cuando el registro se corrija y reenvíe (Paso 23).
    attachments.presignResponses.add(const AttachmentResult.ok(PresignData(alreadyPresent: true)));
    attachments.commitResponses.add(const AttachmentResult.ok(null));
    expect((await uploads.drainPending()).uploaded, 1);

    final summary = (await RecordStatusRepository(db).recentRecords(orgId: 'org-1')).single;
    expect((summary.status, summary.pendingUploads), (RecordSyncStatus.rejected, 0));
  });

  test('un fallo permanente de la foto se muestra aparte del "por subir"', () async {
    attachments.presignResponses.add(const AttachmentResult.err(AttachmentError.unexpectedStatus(413, '')));
    expect((await uploads.drainPending()).failed, 1);

    final summary = (await RecordStatusRepository(db).recentRecords(orgId: 'org-1')).single;
    expect((summary.pendingUploads, summary.failedUploads), (0, 1));
  });
}

