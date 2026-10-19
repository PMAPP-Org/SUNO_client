import 'dart:convert';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/local/visit_status_repository.dart';
import '../capture/visit_capture.dart';
import '../forms/form_definition.dart';

bool canExportVisits(List<String> roles) => roles.any(supervisionRoles.contains);

void _authorize(List<String> roles) {
  if (!canExportVisits(roles)) throw StateError('Export requires supervision');
}

Iterable<(String, Map<String, Object?>)> _geometries(
  FormDefinition definition,
  Map<String, Object?> answers, [
  String prefix = '',
]) sync* {
  for (final field in definition.fields) {
    final value = answers[field.key];
    final path = '$prefix${field.key}';
    if (field is RepeatFieldDef && value is List<Object?>) {
      for (final (i, row) in value.indexed) {
        if (row is Map<String, Object?>) yield* _geometries(field.definition, row, '$path.$i.');
      }
    } else if (field.checkAnswer(value) == null && value is Map<String, Object?>) {
      if (field is LocationFieldDef) {
        yield (
          path,
          {
            'type': 'Point',
            'coordinates': [value['lon'], value['lat']],
          },
        );
      } else if (field is LineFieldDef || field is PolygonFieldDef) {
        yield (path, value);
      }
    }
  }
}

Uint8List visitGeoJson(VisitDetail detail, FormDefinition? definition, {required List<String> roles}) {
  _authorize(roles);
  final visit = detail.visit;
  final geometries = <(String, Map<String, Object?>?)>[
    if (visit.lat != null && visit.lon != null)
      (
        'visit',
        {
          'type': 'Point',
          'coordinates': [visit.lon, visit.lat],
        },
      ),
    if (definition != null) ..._geometries(definition, detail.answers),
  ];
  if (geometries.isEmpty) geometries.add(('visit', null));
  return Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          for (final (path, geometry) in geometries)
            {
              'type': 'Feature',
              'id': '${visit.id}:$path',
              'geometry': geometry,
              'properties': {
                'visit_id': visit.id,
                'field': path,
                'captured_at': visit.capturedAt.toIso8601String(),
                'template': detail.summary.templateName,
                'template_version_id': visit.templateVersionId,
                'created_by': visit.createdBy,
                'accuracy_m': visit.accuracyM,
                'answers': detail.answers,
                'source': 'device',
                'sync_status': detail.summary.status.name,
              },
            },
        ],
      }),
    ),
  );
}

Iterable<(String, Object?)> reportAnswers(
  FormDefinition? definition,
  Map<String, Object?> answers,
  String locale, [
  String prefix = '',
]) sync* {
  final declared = <String>{};
  for (final field in definition?.fields ?? <FormFieldDef>[]) {
    declared.add(field.key);
    if (!answers.containsKey(field.key)) continue;
    final value = answers[field.key];
    final label = '$prefix${field.label.resolve(locale)}';
    if (field is RepeatFieldDef && value is List<Object?>) {
      for (final (i, row) in value.indexed) {
        if (row is Map<String, Object?>) yield* reportAnswers(field.definition, row, locale, '$label / ${i + 1} / ');
      }
    } else {
      yield (label, value);
    }
  }
  for (final entry in answers.entries) {
    if (!declared.contains(entry.key)) yield ('$prefix${entry.key}', entry.value);
  }
}

Future<Uint8List> visitPdf(
  VisitDetail detail,
  FormDefinition? definition, {
  required List<String> roles,
  required ByteData fontBytes,
  required String locale,
  required String title,
  required String sourceNote,
  required String locationLabel,
  required String answersLabel,
  required String attachmentsNote,
  required String authorLabel,
  required String versionLabel,
}) async {
  _authorize(roles);
  final font = pw.Font.ttf(fontBytes);
  final document = pw.Document(title: title, author: 'SUNO');
  final visit = detail.visit;
  final lines = reportAnswers(definition, detail.answers, locale).toList();
  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(36),
      maxPages: 200,
      theme: pw.ThemeData.withFont(base: font, bold: font),
      footer: (ctx) =>
          pw.Text('${visit.id} · ${ctx.pageNumber}/${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
      build: (_) => [
        pw.Text('SUNO · $title', style: const pw.TextStyle(fontSize: 20)),
        pw.SizedBox(height: 12),
        pw.Text(detail.summary.templateName ?? visit.templateVersionId),
        pw.Text(visit.capturedAt.toIso8601String()),
        pw.Text(visit.id),
        pw.Text('$authorLabel: ${visit.createdBy}'),
        pw.Text('$versionLabel: ${visit.templateVersionId}'),
        pw.Text(sourceNote, style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 12),
        pw.Text('$locationLabel · EPSG:4326: ${visit.lat}, ${visit.lon} (±${visit.accuracyM ?? 0} m)'),
        pw.SizedBox(height: 12),
        pw.Text(answersLabel, style: const pw.TextStyle(fontSize: 14)),
        for (final (label, value) in lines) ...[
          pw.SizedBox(height: 10), pw.Text(label, style: const pw.TextStyle(fontSize: 11)),
          // Short chunks allow long answers and geometries to cross page boundaries.
          for (final chunk in _chunks(value is String ? value : jsonEncode(value)))
            pw.Text(chunk, style: const pw.TextStyle(fontSize: 9)),
        ],
        pw.SizedBox(height: 16),
        pw.Text(attachmentsNote, style: const pw.TextStyle(fontSize: 8)),
      ],
    ),
  );
  return document.save();
}

Iterable<String> _chunks(String text) sync* {
  // Code points, so an emoji cannot be split into malformed UTF-16.
  final runes = text.runes.toList();
  var start = 0;
  while (start < runes.length) {
    var end = (start + 700).clamp(0, runes.length);
    if (end < runes.length) {
      var boundary = end;
      while (boundary > start && ![32, 9, 10, 13].contains(runes[boundary - 1])) {
        boundary--;
      }
      if (boundary > start) end = boundary;
    }
    yield String.fromCharCodes(runes.sublist(start, end));
    start = end;
  }
}
