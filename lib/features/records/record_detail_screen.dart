// Detalle de un registro (Fase A): lo que el agente capturó, con las etiquetas
// de la plantilla, su ubicación y precisión, sus fotos y firma, y en qué punto
// de la sincronización está. Las propias se pueden editar y eliminar.
//
// Todo sale de la BD local: funciona sin red. Si la plantilla no está en la
// caché (registro traída por pull de una plantilla que este teléfono no
// descargó), se muestran las claves tal cual en vez de no mostrar nada.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/auth/auth_state.dart';
import '../../core/capture/record_capture.dart';
import '../../core/exports/record_export.dart';
import '../../core/forms/form_definition.dart';
import '../../core/forms/geometry.dart';
import '../../core/location/coordinate_system.dart';
import '../../core/providers.dart';
import '../../data/local/form_template_repository.dart';
import '../../data/local/record_status_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_page_body.dart';
import '../capture/capture_screen.dart';
import '../home/record_status_list.dart';

class RecordDetailScreen extends ConsumerStatefulWidget {
  const RecordDetailScreen({super.key, required this.recordId});

  final String recordId;

  @override
  ConsumerState<RecordDetailScreen> createState() => _RecordDetailScreenState();
}

class _RecordDetailScreenState extends ConsumerState<RecordDetailScreen> {
  bool _exporting = false;

  Future<void> _export(String format) async {
    final loaded = _loaded;
    final detail = loaded?.detail;
    final identity = _identity;
    if (detail == null || identity == null || !canExportRecords(identity.roles) || _exporting) return;
    final l10n = context.l10n;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final renderBox = context.findRenderObject() as RenderBox?;
    final origin = renderBox == null ? null : renderBox.localToGlobal(Offset.zero) & renderBox.size;
    setState(() => _exporting = true);
    try {
      final bytes = format == 'pdf'
          ? await recordPdf(
              detail,
              loaded!.definition,
              roles: identity.roles,
              fontBytes: await rootBundle.load('assets/fonts/Inter-Regular.ttf'),
              locale: locale,
              title: l10n.recordExportPdf,
              sourceNote: l10n.recordExportLocal(switch (detail.summary.status) {
                RecordSyncStatus.pending => l10n.recordExportPending,
                RecordSyncStatus.synced => l10n.recordExportSynced,
                RecordSyncStatus.rejected => l10n.recordExportRejected,
              }),
              locationLabel: l10n.captureRecordLocation,
              noLocation: l10n.recordNoLocation,
              answersLabel: l10n.recordAnswers,
              attachmentsNote: l10n.recordExportAttachments,
              authorLabel: l10n.recordExportAuthor,
              versionLabel: l10n.recordExportVersion,
            )
          : recordGeoJson(detail, loaded!.definition, roles: identity.roles);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: format == 'pdf' ? 'application/pdf' : 'application/geo+json')],
          fileNameOverrides: ['registro-${detail.record.id}.$format'],
          sharePositionOrigin: origin,
        ),
      );
    } on Exception {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.recordExportFailed)));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// `null` mientras carga.
  ({RecordDetail? detail, FormDefinition? definition})? _loaded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dependencies = ref.read(appDependenciesProvider);
    final auth = dependencies.authController.state;
    if (auth is! Authenticated) return;
    final orgId = auth.user.orgId;
    final detail = await dependencies.recordStatus.detail(orgId: orgId, recordId: widget.recordId);
    FormDefinition? definition;
    if (detail != null) {
      final lookup = await dependencies.formTemplates.forRecord(
        orgId: orgId,
        templateVersionId: detail.record.templateVersionId,
      );
      if (lookup is TemplateReady) definition = lookup.definition;
    }
    if (mounted) setState(() => _loaded = (detail: detail, definition: definition));
  }

  CaptureIdentity? get _identity {
    final dependencies = ref.read(appDependenciesProvider);
    final auth = dependencies.authController.state;
    return auth is Authenticated
        ? CaptureIdentity(
            orgId: auth.user.orgId,
            userId: auth.user.id,
            deviceId: dependencies.deviceId,
            roles: auth.user.roles,
          )
        : null;
  }

  Future<void> _edit() async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => CaptureScreen(editRecordId: widget.recordId)));
    if (saved ?? false) await _load();
  }

  Future<void> _delete() async {
    final identity = _identity;
    if (identity == null) return;
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.recordDeleteTitle),
        content: Text(l10n.recordDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.reviewConfirmCancel)),
          FilledButton(
            key: const Key('record_delete_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.recordDeleteConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final dependencies = ref.read(appDependenciesProvider);
    final change = await dependencies.recordCapture.delete(identity: identity, recordId: widget.recordId);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (change == RecordChange.saved) {
      unawaited(dependencies.syncCoordinator.syncNow());
      messenger.showSnackBar(SnackBar(content: Text(l10n.recordDeleted)));
      Navigator.of(context).pop();
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text(change == RecordChange.needsReview ? l10n.recordNeedsReview : l10n.recordNotEditable)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final loaded = _loaded;
    final detail = loaded?.detail;
    final identity = _identity;
    // Solo las propias, y sin nada en revisión (`RecordCapture._editable`).
    final editable =
        detail != null &&
        identity != null &&
        canEdit(detail.record, userId: identity.userId, roles: identity.roles) &&
        detail.summary.status != RecordSyncStatus.rejected;
    return Scaffold(
      appBar: AppBar(
        title: Text(detail?.summary.templateName ?? l10n.homeRecordUntitled),
        actions: [
          if (detail != null && identity != null && canExportRecords(identity.roles))
            PopupMenuButton<String>(
              key: const Key('record_export'),
              tooltip: l10n.recordExport,
              enabled: !_exporting,
              icon: const Icon(Icons.ios_share),
              onSelected: _export,
              itemBuilder: (_) => [
                PopupMenuItem(value: 'pdf', child: Text(l10n.recordExportPdf)),
                PopupMenuItem(value: 'geojson', child: Text(l10n.recordExportGeoJson)),
              ],
            ),
          if (editable) ...[
            IconButton(
              key: const Key('record_edit'),
              tooltip: l10n.recordEdit,
              icon: const Icon(Icons.edit_outlined),
              onPressed: loaded?.definition == null ? null : _edit,
            ),
            IconButton(
              key: const Key('record_delete'),
              tooltip: l10n.recordDelete,
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
          ],
        ],
      ),
      body: loaded == null
          ? const Center(child: CircularProgressIndicator())
          : detail == null
          ? AppPageBody(children: [Text(l10n.recordNotFound, key: const Key('record_not_found'))])
          : _Body(
              detail: detail,
              definition: loaded.definition,
              crs: ref.read(appDependenciesProvider).coordinates.current.value,
            ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.detail, required this.definition, required this.crs});

  final RecordDetail detail;
  final FormDefinition? definition;

  /// Sistema en que se muestran las coordenadas (Fase C).
  final CoordinateSystem crs;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final localizations = MaterialLocalizations.of(context);
    final record = detail.record;
    final answers = detail.answers;
    final attachments = {for (final a in detail.attachments) a.id: a};
    final captured = record.capturedAt.toLocal();

    return AppPageBody(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${localizations.formatFullDate(captured)} '
                '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(captured))}',
              ),
            ),
            RecordStatusChip(status: detail.summary.status),
          ],
        ),
        const AppGap.lg(),
        Text(l10n.captureRecordLocation, style: theme.textTheme.titleSmall),
        if (record.lat == null || record.lon == null)
          Text(l10n.recordNoLocation, key: const Key('record_no_location'))
        else ...[
          Text(
            l10n.coordinatesWithAccuracy(crs.format(record.lat!, record.lon!), (record.accuracyM ?? 0).round()),
            key: const Key('record_location'),
          ),
          if (record.altitudeM != null) Text(l10n.recordAltitude(record.altitudeM!.round())),
        ],
        const AppGap.lg(),
        Text(l10n.recordAnswers, style: theme.textTheme.titleSmall),
        const AppGap.sm(),
        if (definition == null)
          for (final entry in answers.entries) _Answer(label: entry.key, value: Text(_plain(l10n, entry.value)))
        else
          for (final field in definition!.fields)
            if (answers.containsKey(field.key))
              _Answer(
                label: field.label.resolve(locale),
                value: _value(context, field, answers[field.key], attachments, locale),
              ),
        if (_extraPhotos(answers, attachments).isNotEmpty) ...[
          const AppGap.lg(),
          Text(l10n.recordExtraPhotos, style: theme.textTheme.titleSmall),
          const AppGap.sm(),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [for (final a in _extraPhotos(answers, attachments)) _Thumbnail(attachment: a)],
          ),
        ],
        const AppGap.lg(),
        // Para soporte: con este identificador se encuentra el registro en el
        // servidor.
        SelectableText(l10n.recordId(record.id), style: theme.textTheme.bodySmall),
      ],
    );
  }

  /// Adjuntos que no son la respuesta de ningún campo: las fotos adicionales.
  static List<RecordAttachmentView> _extraPhotos(
    Map<String, dynamic> answers,
    Map<String, RecordAttachmentView> attachments,
  ) {
    Iterable<String> references(Object? node) sync* {
      if (node is String) yield node;
      if (node is Map<String, Object?>) {
        for (final value in node.values) {
          yield* references(value);
        }
      }
      if (node is List<Object?>) {
        for (final value in node) {
          yield* references(value);
        }
      }
    }

    final referenced = references(answers).toSet();
    return [
      for (final a in attachments.values)
        if (!referenced.contains(a.id)) a,
    ];
  }

  Widget _value(
    BuildContext context,
    FormFieldDef field,
    Object? value,
    Map<String, RecordAttachmentView> attachments,
    String locale,
  ) {
    final l10n = context.l10n;
    final localizations = MaterialLocalizations.of(context);
    return switch (field) {
      RepeatFieldDef(:final definition) when value is List<Object?> => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, row) in value.indexed)
            if (row is Map<String, Object?>)
              _Answer(
                label: l10n.formRepeatRow(index + 1),
                value: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final child in definition.fields)
                      if (row.containsKey(child.key))
                        _Answer(
                          label: child.label.resolve(locale),
                          value: _value(context, child, row[child.key], attachments, locale),
                        ),
                  ],
                ),
              ),
        ],
      ),
      AttachmentRefFieldDef() when value is String && attachments[value] != null => Align(
        alignment: Alignment.centerLeft,
        child: _Thumbnail(attachment: attachments[value]!),
      ),
      SingleChoiceFieldDef(:final options) => Text(_option(options, value, locale) ?? _plain(l10n, value)),
      MultiChoiceFieldDef(:final options) when value is List => Text(
        [for (final v in value) _option(options, v, locale) ?? '$v'].join(', '),
      ),
      LineFieldDef() || PolygonFieldDef() when kindOf(value) != null => () {
        final kind = kindOf(value)!;
        final vertices = verticesOf(value);
        final measured = formatMeasure(kind, measure(kind, vertices));
        return Text(
          kind == GeometryKind.line
              ? l10n.geometryLineSummary(vertices.length, measured)
              : l10n.geometryPolygonSummary(vertices.length, measured),
        );
      }(),
      DateTimeFieldDef() when value is String && DateTime.tryParse(value) != null => Text(() {
        final local = DateTime.parse(value).toLocal();
        return '${localizations.formatShortDate(local)} '
            '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
      }()),
      _ => Text(_plain(l10n, value)),
    };
  }

  static String? _option(List<ChoiceOption> options, Object? value, String locale) {
    for (final option in options) {
      if (option.value == value) return option.label.resolve(locale);
    }
    return null;
  }

  static String _plain(AppLocalizations l10n, Object? value) => switch (value) {
    null => l10n.reviewNoValue,
    true => l10n.reviewYes,
    false => l10n.reviewNo,
    final List<Object?> list => list.join(', '),
    final Map<Object?, Object?> map when map.containsKey('lat') => l10n.captureLocation(
      '${map['lat']}',
      '${map['lon']}',
    ),
    _ => '$value',
  };
}

class _Answer extends StatelessWidget {
  const _Answer({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        value,
      ],
    ),
  );
}

/// Miniatura de una foto o firma si el archivo sigue en el teléfono; si no,
/// solo su estado.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.attachment});

  final RecordAttachmentView attachment;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final path = attachment.localPath;
    final state = switch (attachment.uploadState) {
      'uploaded' => l10n.recordAttachmentUploaded,
      'failed' => l10n.recordAttachmentFailed,
      'pending' || 'uploading' => l10n.recordAttachmentPending,
      _ => l10n.recordAttachmentRemote,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (path != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Image.file(
              File(path),
              key: ValueKey('record-attachment-${attachment.id}'),
              width: AppSizes.thumbnail,
              height: AppSizes.thumbnail,
              fit: BoxFit.cover,
              // El archivo pudo borrarse tras subirse: no es un error.
              errorBuilder: (_, _, _) =>
                  const SizedBox.square(dimension: AppSizes.thumbnail, child: Icon(Icons.image_not_supported_outlined)),
            ),
          ),
        Text(state, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
