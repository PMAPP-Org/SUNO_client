import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/capture/visit_capture.dart';
import 'package:visitacampo/core/exports/visit_export.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/data/local/visit_status_repository.dart';

void main() {
  late AppDatabase db;
  late VisitCapture capture;
  late VisitStatusRepository repository;
  final definition =
      (parseFormDefinition({
                'fields': [
                  {
                    'key': 'rows',
                    'type': 'repeat',
                    'label': {'es': 'Activos'},
                    'fields': [
                      {
                        'key': 'code',
                        'type': 'qr',
                        'label': {'es': 'Código'},
                      },
                      {
                        'key': 'photo',
                        'type': 'photo',
                        'label': {'es': 'Foto'},
                      },
                      {
                        'key': 'line',
                        'type': 'line',
                        'label': {'es': 'Línea'},
                      },
                      {
                        'key': 'point',
                        'type': 'location',
                        'label': {'es': 'Punto'},
                      },
                      {
                        'key': 'secret',
                        'type': 'text',
                        'label': {'es': 'Oculto'},
                        'visible_if': {'op': 'eq', 'field': 'code', 'value': 'show'},
                      },
                    ],
                  },
                ],
              })
              as DefinitionOk)
          .definition;
  const identity = CaptureIdentity(orgId: 'org', userId: 'user', deviceId: 'device');
  const line = {
    'type': 'LineString',
    'coordinates': [
      [-74.1, 4.6],
      [-74.0, 4.7],
    ],
  };

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    capture = VisitCapture(db: db);
    repository = VisitStatusRepository(db);
  });
  tearDown(() => db.close());

  test('repeat media is queued, hidden answers removed and nested geometry exported', () async {
    final photo = PendingAttachment(
      id: 'photo-id',
      sha256: 'a' * 64,
      localPath: '/local/photo',
      mime: 'image/jpeg',
      role: 'foto',
      capturedAt: DateTime.utc(2026),
    );
    final id = await capture.save(
      identity: identity,
      templateVersionId: 'tv',
      definition: definition,
      answers: {
        'rows': [
          {
            'code': 'A-1',
            'photo': photo.id,
            'line': line,
            'point': {'lat': 4.5, 'lon': -74.2},
            'secret': 'hidden',
          },
        ],
      },
      captured: {photo.id: photo},
      fix: const LocationFix(lat: 4.6, lon: -74.08, accuracyM: 3),
    );
    expect((await db.select(db.attachmentQueue).get()).length, 1);
    final detail = (await repository.detail(orgId: 'org', visitId: id))!;
    expect(detail.answers.toString(), isNot(contains('hidden')));
    expect((await repository.mapVisits(orgId: 'org')).single.geometries.single, line);
    final geo =
        jsonDecode(utf8.decode(visitGeoJson(detail, definition, roles: ['SUPERVISOR']))) as Map<String, dynamic>;
    final features = (geo['features'] as List).cast<Map<String, dynamic>>();
    expect(features.length, 3);
    expect((features[0]['geometry'] as Map)['coordinates'], [-74.08, 4.6]);
    expect((features[1]['properties'] as Map)['field'], 'rows.0.line');
    expect((features[1]['geometry'] as Map)['type'], 'LineString');
    expect((features[2]['geometry'] as Map)['coordinates'], [-74.2, 4.5]);
    expect((features[0]['properties'] as Map)['sync_status'], 'pending');
    expect(() => visitGeoJson(detail, definition, roles: ['FIELD_AGENT']), throwsStateError);
    expect(await repository.detail(orgId: 'other', visitId: id), isNull);
    expect(reportAnswers(definition, detail.answers, 'es').first.$1, 'Activos / 1 / Código');
    final pdf = await visitPdf(
      detail,
      definition,
      roles: ['ADMIN'],
      fontBytes: ByteData.sublistView(File('assets/fonts/Inter-Regular.ttf').readAsBytesSync()),
      locale: 'es',
      title: 'Informe de visita',
      sourceNote: 'Pendiente de sincronizar',
      locationLabel: 'Ubicación',
      answersLabel: 'Respuestas',
      attachmentsNote: 'Adjuntos por referencia',
      authorLabel: 'Autor',
      versionLabel: 'Versión del formulario',
    );
    expect(ascii.decode(pdf.take(5).toList()), '%PDF-');
    // Disposable QA artifact; parsed and rendered by the verification workflow.
    Directory('.git/c56-qa').createSync(recursive: true);
    File('.git/c56-qa/app-visit.pdf').writeAsBytesSync(pdf);
  });

  test('a visit without GPS is preserved with null geometry, defaults do not rewrite it', () async {
    final id = await capture.save(
      identity: identity,
      templateVersionId: 'tv',
      definition: definition,
      answers: {
        'rows': [
          {'code': 'A-1'},
        ],
      },
      captured: const {},
    );
    final detail = (await repository.detail(orgId: 'org', visitId: id))!;
    final geo = jsonDecode(utf8.decode(visitGeoJson(detail, null, roles: ['OWNER']))) as Map<String, dynamic>;
    expect(((geo['features'] as List).single as Map<String, dynamic>)['geometry'], isNull);
    expect(reportAnswers(null, detail.answers, 'es').single.$1, 'rows');
    expect(canExportVisits([]), isFalse);
  });
}
