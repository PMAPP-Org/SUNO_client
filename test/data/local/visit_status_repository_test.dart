// Fase A: buscar visitas (por plantilla y por lo respondido) y abrir su
// detalle, todo desde la BD local.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/data/local/form_template_repository.dart';
import 'package:visitacampo/data/local/visit_status_repository.dart';

const _identity = CaptureIdentity(orgId: 'org-1', userId: 'user-1', deviceId: 'device-1');

Map<String, dynamic> _templateRow(String id, String name) => {
  'id': id,
  'org_id': 'org-1',
  'version': 1,
  'change_seq': 1,
  'deleted_at': null,
  'template_id': 'tpl-$id',
  'name': name,
  'version_number': 1,
  'published_at': '2026-10-01T00:00:00Z',
  'definition': {
    'fields': [
      {
        'key': 'altura_cm',
        'type': 'number',
        'label': {'es': 'Altura (cm)'},
      },
      {
        'key': 'observaciones',
        'type': 'text',
        'label': {'es': 'Observaciones'},
      },
      {
        'key': 'foto',
        'type': 'photo',
        'label': {'es': 'Foto'},
      },
    ],
  },
};

FormDefinition _definition() =>
    (parseFormDefinition(_templateRow('x', 'x')['definition'] as Map<String, dynamic>) as DefinitionOk).definition;

void main() {
  late AppDatabase db;
  late VisitStatusRepository repository;
  var clock = DateTime.utc(2026, 10, 18, 8);

  Future<String> capture(
    String templateVersionId,
    Map<String, Object?> answers, {
    Map<String, PendingAttachment> captured = const {},
  }) {
    clock = clock.add(const Duration(minutes: 1));
    return VisitCapture(db: db, clock: () => clock).save(
      identity: _identity,
      templateVersionId: templateVersionId,
      definition: _definition(),
      answers: answers,
      captured: captured,
    );
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = VisitStatusRepository(db);
    final templates = FormTemplateRepository(db);
    await templates.upsertFromServerRow(_templateRow('tv-poda', 'Poda de árboles'));
    await templates.upsertFromServerRow(_templateRow('tv-riego', 'Riego'));
  });
  tearDown(() => db.close());

  group('búsqueda', () {
    test('por nombre de la plantilla, sin distinguir mayúsculas ni tildes', () async {
      final poda = await capture('tv-poda', {'altura_cm': 10});
      await capture('tv-riego', {'altura_cm': 20});

      final found = await repository.recentVisits(orgId: 'org-1', query: 'ARBOLES');
      expect(found.map((v) => v.id), [poda]);
    });

    test('por lo respondido, no por el nombre de los campos', () async {
      final pena = await capture('tv-riego', {'observaciones': 'Finca La Peña, lote 3'});
      await capture('tv-riego', {'observaciones': 'sin novedad'});

      expect((await repository.recentVisits(orgId: 'org-1', query: 'pena')).map((v) => v.id), [pena]);
      expect(
        await repository.recentVisits(orgId: 'org-1', query: 'observaciones'),
        isEmpty,
        reason: 'la clave del campo no es una respuesta',
      );
    });

    test('respeta el límite y el orden (lo más reciente primero)', () async {
      final ids = [for (var i = 0; i < 4; i++) await capture('tv-riego', {'altura_cm': i})];

      final page = await repository.recentVisits(orgId: 'org-1', query: 'riego', limit: 2);
      expect(page.map((v) => v.id), [ids[3], ids[2]]);
    });

    test('sin texto, la lista normal', () async {
      await capture('tv-riego', {});
      expect(await repository.recentVisits(orgId: 'org-1', query: '  '), hasLength(1));
    });
  });

  group('detalle', () {
    test('trae la visita, su estado y sus adjuntos con el archivo local', () async {
      final photo = PendingAttachment(
        id: 'att-1',
        sha256: 'a' * 64,
        localPath: '/fotos/1.jpg',
        mime: 'image/jpeg',
        role: 'foto',
        capturedAt: DateTime.utc(2026, 10, 18, 8),
      );
      final id = await capture('tv-poda', {'altura_cm': 35, 'foto': photo.id}, captured: {photo.id: photo});

      final detail = await repository.detail(orgId: 'org-1', visitId: id);
      expect(detail!.answers['altura_cm'], 35);
      expect(detail.summary.templateName, 'Poda de árboles');
      expect(detail.summary.status, VisitSyncStatus.pending);
      expect(detail.attachments.single.localPath, '/fotos/1.jpg');
      expect(detail.attachments.single.uploadState, 'pending');
    });

    test('de otra organización o borrada no existe', () async {
      final id = await capture('tv-poda', {});
      expect(await repository.detail(orgId: 'org-2', visitId: id), isNull);

      await (db.update(db.visits)..where((t) => t.id.equals(id))).write(
        VisitsCompanion(deletedAt: Value(DateTime.utc(2026, 10, 18))),
      );
      expect(await repository.detail(orgId: 'org-1', visitId: id), isNull);
    });
  });
}
