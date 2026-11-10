// Costos, pieza 4b: el detalle del registro, la tabla del PDF y el GeoJSON llevan las
// cantidades (ítem, ubicación, cantidad con unidad, nota).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/capture/record_capture.dart';
import 'package:suno/core/exports/record_export.dart';
import 'package:suno/core/forms/form_definition.dart';
import 'package:suno/data/local/database.dart';
import 'package:suno/data/local/record_status_repository.dart';

const _labels = QuantityTableLabels(
  title: 'Cantidades',
  item: 'Ítem',
  location: 'Ubicación',
  quantity: 'Cantidad',
  note: 'Nota',
  taskLocation: 'La de la tarea',
  refinedLocation: 'Ubicación precisada',
);

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('detalle, tabla del PDF y GeoJSON', () async {
    await db.replaceScheduleTasks(
      orgId: 'org',
      userId: 'user',
      version: 'v1',
      now: DateTime.utc(2026, 11, 9),
      rows: [
        ScheduleTasksCompanion.insert(
          id: 'task-1',
          orgId: 'org',
          userId: 'user',
          projectId: 'p-1',
          projectName: 'Obra',
          wbs: '1.2',
          outlineNumber: '1.2',
          name: 'Descapote',
          position: 0,
        ),
      ],
      locations: [
        TaskLocationOptionsCompanion.insert(
          taskId: 'task-1',
          locationId: 'loc-2',
          label: 'Tramo 2 / PR 1',
          isTaskLocation: false,
          position: 1,
        ),
      ],
      catalog: [
        ProjectItemsCompanion.insert(
          projectId: 'p-1',
          itemId: 'item-1',
          code: '2.1',
          description: 'Concreto zapatas',
          unit: 'm3',
          position: 0,
        ),
        ProjectItemsCompanion.insert(
          projectId: 'p-1',
          itemId: 'item-2',
          code: '2.2',
          description: 'Acero de refuerzo',
          unit: 'kg',
          position: 1,
        ),
      ],
    );
    final definition =
        (parseFormDefinition({
                  'fields': [
                    {
                      'key': 'notas',
                      'type': 'text',
                      'label': {'es': 'Notas'},
                    },
                  ],
                })
                as DefinitionOk)
            .definition;
    final id = await RecordCapture(db: db).save(
      identity: const CaptureIdentity(orgId: 'org', userId: 'user', deviceId: 'device'),
      templateVersionId: 'tv',
      definition: definition,
      answers: const {},
      captured: const {},
      progress: const TaskProgress(
        taskId: 'task-1',
        quantities: [
          {'item_id': 'item-1', 'location_id': null, 'quantity': 12.5, 'note': ''},
          {'item_id': 'item-2', 'location_id': 'loc-2', 'quantity': 3.0, 'note': 'sobrante'},
        ],
      ),
    );
    final detail = (await RecordStatusRepository(db).detail(orgId: 'org', recordId: id))!;
    expect(quantityTableRows(detail, _labels), [
      ['2.1 Concreto zapatas', 'La de la tarea', '12,5 m3', ''],
      ['2.2 Acero de refuerzo', 'Tramo 2 / PR 1', '3 kg', 'sobrante'],
    ]);

    final geo =
        jsonDecode(utf8.decode(recordGeoJson(detail, definition, roles: ['SUPERVISOR']))) as Map<String, dynamic>;
    final properties = ((geo['features'] as List).single as Map)['properties'] as Map;
    expect(properties['quantities'], [
      {'item_code': '2.1', 'item_id': 'item-1', 'location_id': null, 'quantity': 12.5, 'unit': 'm3', 'note': ''},
      {
        'item_code': '2.2',
        'item_id': 'item-2',
        'location_id': 'loc-2',
        'quantity': 3.0,
        'unit': 'kg',
        'note': 'sobrante',
      },
    ]);

    final pdf = await recordPdf(
      detail,
      definition,
      roles: ['ADMIN'],
      fontBytes: ByteData.sublistView(File('assets/fonts/Inter-Regular.ttf').readAsBytesSync()),
      locale: 'es',
      title: 'Informe de registro',
      sourceNote: 'Pendiente de sincronizar',
      locationLabel: 'Ubicación',
      noLocation: 'Sin ubicación.',
      answersLabel: 'Respuestas',
      attachmentsNote: 'Adjuntos por referencia',
      authorLabel: 'Autor',
      versionLabel: 'Versión del formulario',
      quantityLabels: _labels,
    );
    expect(ascii.decode(pdf.take(5).toList()), '%PDF-');
  });
}
