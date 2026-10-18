// Captura de visita (Paso 22): plantilla → formulario dinámico (Paso 21) →
// ubicación, fotos y firma → guardado offline en una sola transacción.
//
// - La plantilla sale de la caché local (`FormTemplateRepository`), la versión
//   vigente para una visita **nueva**; sin plantillas, se pide sincronizar.
// - Foto, firma y ubicación de los campos de la plantilla se capturan aquí
//   (`FormMediaDelegate`) y el formulario guarda solo el `id` del adjunto.
// - Aparte del formulario: la ubicación de la visita (`Visit.lat/lon`, con su
//   precisión) y fotos adicionales.
// - Guardar es local e inmediato (`VisitCapture.save`): la visita aparece en
//   la pantalla de inicio sin esperar a la red.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/capture/visit_capture.dart';
import '../../core/location/coordinate_system.dart';
import '../../core/location/geo.dart';
import '../../core/forms/form_definition.dart';
import '../../core/forms/geometry.dart';
import '../../core/location/location_source.dart';
import '../../core/providers.dart';
import '../../data/local/assignment_repository.dart';
import '../../data/local/form_template_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/forms/dynamic_form.dart';
import '../../ui/forms/form_controller.dart';
import '../../ui/forms/template_status.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import 'geometry_capture_screen.dart';
import 'location_capture_sheet.dart';
import 'signature_screen.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key, this.editVisitId, this.assignmentId})
    : assert(editVisitId == null || assignmentId == null);

  /// Fase A: editar esta visita en vez de crear una. Se abre con su misma
  /// versión de plantilla y sus respuestas; solo viaja lo que cambie.
  final String? editVisitId;

  /// Fase B: la visita nueva cumple esta asignación. Se abre con la versión
  /// de plantilla de la asignación y muestra su punto y la distancia a él.
  final String? assignmentId;

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> implements FormMediaDelegate {
  List<TemplateVersionInfo>? _templates;
  String? _templateId;
  TemplateLookup? _lookup;
  FormController? _form;

  /// Ubicación tomada **en esta pantalla**; al editar, `null` conserva la de
  /// la visita ([_originalFix]).
  LocationFix? _fix;
  LocationFix? _originalFix;
  bool _saving = false;

  bool get _editing => widget.editVisitId != null;

  /// Sistema en que se muestran las coordenadas (Fase C).
  CoordinateSystem get _crs => ref.read(appDependenciesProvider).coordinates.current.value;

  /// La asignación que esta visita cumple (Fase B), ya cargada.
  AssignmentItem? _assignment;

  /// Adjuntos de los campos foto/firma, por `id` (lo que guarda `answers`).
  final Map<String, PendingAttachment> _captured = {};
  final List<PendingAttachment> _extraPhotos = [];

  @override
  void initState() {
    super.initState();
    if (_editing) {
      _loadForEdit(widget.editVisitId!);
    } else if (widget.assignmentId != null) {
      _loadForAssignment(widget.assignmentId!);
    } else {
      _loadTemplates();
    }
  }

  Future<void> _loadForAssignment(String assignmentId) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final dependencies = ref.read(appDependenciesProvider);
    final assignment = await dependencies.assignments.byId(orgId: orgId, id: assignmentId);
    if (assignment == null) {
      if (mounted) setState(() => _templates = const []);
      return;
    }
    // La versión exacta de la asignación: es contra la que el servidor
    // validará las respuestas.
    final lookup = await dependencies.formTemplates.forVisit(
      orgId: orgId,
      templateVersionId: assignment.templateVersionId,
    );
    if (!mounted) return;
    setState(() {
      _assignment = assignment;
      _lookup = lookup;
      _templates = lookup is TemplateReady ? [lookup.info] : const [];
      _form = lookup is TemplateReady ? FormController(lookup.definition) : null;
    });
  }

  Future<void> _loadForEdit(String visitId) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final dependencies = ref.read(appDependenciesProvider);
    final detail = await dependencies.visitStatus.detail(orgId: orgId, visitId: visitId);
    if (detail == null) {
      if (mounted) setState(() => _templates = const []);
      return;
    }
    final lookup = await dependencies.formTemplates.forVisit(
      orgId: orgId,
      templateVersionId: detail.visit.templateVersionId,
    );
    if (!mounted) return;
    final visit = detail.visit;
    setState(() {
      _lookup = lookup;
      _templates = lookup is TemplateReady ? [lookup.info] : const [];
      _form = lookup is TemplateReady ? FormController(lookup.definition, initialAnswers: detail.answers) : null;
      _originalFix = visit.lat == null || visit.lon == null
          ? null
          : LocationFix(lat: visit.lat!, lon: visit.lon!, accuracyM: visit.accuracyM ?? 0, altitudeM: visit.altitudeM);
    });
  }

  @override
  void dispose() {
    _form?.dispose();
    super.dispose();
  }

  String? get _orgId => switch (ref.read(appDependenciesProvider).authController.state) {
    Authenticated(:final user) => user.orgId,
    _ => null,
  };

  Future<void> _loadTemplates() async {
    final orgId = _orgId;
    if (orgId == null) return;
    final templates = await ref.read(appDependenciesProvider).formTemplates.availableTemplates(orgId: orgId);
    if (!mounted) return;
    setState(() => _templates = templates);
    if (templates.length == 1) await _selectTemplate(templates.single.templateId);
  }

  Future<void> _selectTemplate(String? templateId) async {
    final orgId = _orgId;
    if (templateId == null || orgId == null) return;
    final lookup = await ref
        .read(appDependenciesProvider)
        .formTemplates
        .latestForNewVisit(orgId: orgId, templateId: templateId);
    if (!mounted) return;
    setState(() {
      _templateId = templateId;
      _lookup = lookup;
      _form?.dispose();
      _form = lookup is TemplateReady ? FormController(lookup.definition) : null;
      _captured.clear();
    });
  }

  // --- FormMediaDelegate -----------------------------------------------------

  @override
  Future<String?> capturePhoto(String fieldKey) async {
    final photo = await _takePhoto();
    if (photo == null) return null;
    _captured[photo.id] = photo;
    return photo.id;
  }

  @override
  Future<String?> captureSignature(String fieldKey) async {
    final dependencies = ref.read(appDependenciesProvider);
    final field = _form?.definition.fields.where((f) => f.key == fieldKey).firstOrNull;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final png = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => SignatureScreen(title: field?.label.resolve(locale) ?? context.l10n.signatureTitle),
      ),
    );
    if (png == null) return null;
    final stored = await dependencies.signatureStore.save(png);
    final signature = PendingAttachment(
      id: dependencies.visitCapture.newAttachmentId(),
      sha256: stored.sha256,
      localPath: stored.path,
      mime: 'image/png',
      role: 'firma',
      capturedAt: DateTime.now(),
    );
    _captured[signature.id] = signature;
    return signature.id;
  }

  @override
  Future<Map<String, double>?> captureLocation(String fieldKey) async {
    final fix = await _sampleLocation();
    return fix == null ? null : {'lat': fix.lat, 'lon': fix.lon};
  }

  /// Misma hoja para la ubicación de la visita y para los campos de
  /// ubicación del formulario (Fase A: precisión, promedio, tiempo máximo).
  Future<LocationFix?> _sampleLocation() {
    final dependencies = ref.read(appDependenciesProvider);
    return showLocationCaptureSheet(
      context,
      source: dependencies.locationSource,
      policy: dependencies.gpsPolicy,
      coordinateSystem: dependencies.coordinates.current.value,
    );
  }

  @override
  Future<Map<String, Object?>?> captureGeometry(FormFieldDef field, GeometryKind kind, Object? current) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    return Navigator.of(context).push<Map<String, Object?>>(
      MaterialPageRoute(
        builder: (_) => GeometryCaptureScreen(kind: kind, title: field.label.resolve(locale), initial: verticesOf(current)),
      ),
    );
  }

  // ---------------------------------------------------------------------------

  Future<PendingAttachment?> _takePhoto() async {
    final dependencies = ref.read(appDependenciesProvider);
    final photo = await dependencies.photoCapture.takePhoto();
    if (photo == null) return null;
    return PendingAttachment(
      id: dependencies.visitCapture.newAttachmentId(),
      sha256: photo.sha256,
      localPath: photo.file.path,
      mime: photo.mime,
      role: 'foto',
      capturedAt: DateTime.now(),
    );
  }

  Future<void> _addExtraPhoto() async {
    final photo = await _takePhoto();
    if (photo == null || !mounted) return;
    setState(() => _extraPhotos.add(photo));
  }

  Future<void> _getLocation() async {
    // Sin estado "cargando": la hoja modal ya muestra el progreso.
    final fix = await _sampleLocation();
    if (!mounted) return;
    // Cancelar no borra una ubicación ya tomada.
    setState(() => _fix = fix ?? _fix);
    if ((_fix ?? _originalFix) == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.captureLocationUnavailable)));
    }
  }

  Future<void> _save() async {
    final dependencies = ref.read(appDependenciesProvider);
    final authState = dependencies.authController.state;
    final form = _form;
    final lookup = _lookup;
    if (authState is! Authenticated || form == null || lookup is! TemplateReady) return;

    final l10n = context.l10n;
    if (!form.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.captureFixErrors)));
      return;
    }

    final identity = CaptureIdentity(
      orgId: authState.user.orgId,
      userId: authState.user.id,
      deviceId: dependencies.deviceId,
      roles: authState.user.roles,
    );
    setState(() => _saving = true);
    VisitChange change;
    try {
      if (_editing) {
        change = await dependencies.visitCapture.update(
          identity: identity,
          visitId: widget.editVisitId!,
          definition: lookup.definition,
          answers: form.answers,
          captured: Map.of(_captured),
          extraPhotos: List.of(_extraPhotos),
          fix: _fix,
        );
      } else {
        await dependencies.visitCapture.save(
          identity: identity,
          templateVersionId: lookup.info.id,
          definition: lookup.definition,
          answers: form.answers,
          captured: Map.of(_captured),
          extraPhotos: List.of(_extraPhotos),
          fix: _fix,
          assignmentId: _assignment?.id,
        );
        change = VisitChange.saved;
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    // La visita y sus fotos salen ya si hay red, sin esperar al siguiente
    // ciclo (Paso 18, Fase A). Sin `await`: no retiene la pantalla ni el
    // guardado; sin red queda en la outbox para el próximo disparo.
    if (change == VisitChange.saved) unawaited(dependencies.syncCoordinator.syncNow());
    if (!mounted) return;
    final message = switch (change) {
      VisitChange.saved => _editing ? l10n.captureUpdated : l10n.captureSaved,
      VisitChange.unchanged => l10n.visitUnchanged,
      VisitChange.notAllowed => l10n.visitNotEditable,
      VisitChange.needsReview => l10n.visitNeedsReview,
      VisitChange.notFound => l10n.visitNotFound,
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    Navigator.of(context).pop(change == VisitChange.saved);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final templates = _templates;
    final lookup = _lookup;
    final form = _form;
    final fix = _fix ?? _originalFix;

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? l10n.captureEditTitle : l10n.captureTitle)),
      body: AppPageBody(
        children: [
          if (templates == null)
            const Center(child: CircularProgressIndicator())
          else if (templates.isEmpty)
            Text(l10n.captureNoTemplates, key: const Key('capture_no_templates'))
          else ...[
            if (templates.length > 1)
              DropdownButtonFormField<String>(
                key: const Key('capture_template_picker'),
                initialValue: _templateId,
                decoration: InputDecoration(labelText: l10n.captureTemplateLabel),
                items: [
                  for (final t in templates) DropdownMenuItem(value: t.templateId, child: Text(t.name ?? t.templateId)),
                ],
                onChanged: _selectTemplate,
              ),
            if (lookup != null && templateLookupMessage(l10n, lookup) != null) ...[
              const AppGap.sm(),
              Text(templateLookupMessage(l10n, lookup)!, key: const Key('capture_template_problem')),
            ],
            if (_assignment case final assignment?) ...[
              Text(
                l10n.captureForAssignment(assignment.title ?? assignment.templateName ?? l10n.homeVisitUntitled),
                key: const Key('capture_assignment'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (assignment.hasPoint)
                Text(
                  fix == null
                      ? l10n.captureAssignmentPointIn(_crs.format(assignment.lat!, assignment.lon!))
                      : l10n.captureAssignmentDistance(
                          distanceM(fix.lat, fix.lon, assignment.lat!, assignment.lon!).round(),
                        ),
                  key: const Key('capture_assignment_point'),
                ),
            ],
            if (form != null) ...[
              const AppGap.lg(),
              DynamicForm(controller: form, mediaDelegate: this, formatLocation: _crs.format),
              const AppGap.sm(),
              Text(l10n.captureVisitLocation, style: Theme.of(context).textTheme.titleSmall),
              if (fix != null)
                Text(
                  l10n.coordinatesWithAccuracy(_crs.format(fix.lat, fix.lon), fix.accuracyM.round()),
                ),
              if (fix != null && fix.accuracyM > ref.read(appDependenciesProvider).gpsPolicy.targetAccuracyM)
                Text(l10n.captureLocationLowAccuracy, key: const Key('capture_location_low_accuracy')),
              AppButton(
                key: const Key('capture_get_location_button'),
                label: fix == null ? l10n.captureGetLocation : l10n.formUpdateLocation,
                onPressed: _getLocation,
              ),
              const AppGap.lg(),
              Text(l10n.captureExtraPhotos(_extraPhotos.length), style: Theme.of(context).textTheme.titleSmall),
              OutlinedButton(
                key: const Key('capture_add_photo_button'),
                onPressed: _addExtraPhoto,
                child: Text(l10n.captureAddPhoto),
              ),
              const AppGap.lg(),
              AppButton(
                key: const Key('capture_save_button'),
                label: l10n.captureSave,
                loadingLabel: l10n.captureSaving,
                isLoading: _saving,
                onPressed: _save,
              ),
            ],
          ],
        ],
      ),
    );
  }
}
