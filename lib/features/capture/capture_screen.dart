// Captura de registro (Paso 22): plantilla → formulario dinámico (Paso 21) →
// ubicación, fotos y firma → guardado offline en una sola transacción.
//
// - La plantilla sale de la caché local (`FormTemplateRepository`), la versión
//   vigente para un registro **nuevo**; sin plantillas, se pide sincronizar.
// - Foto, firma y ubicación de los campos de la plantilla se capturan aquí
//   (`FormMediaDelegate`) y el formulario guarda solo el `id` del adjunto.
// - Aparte del formulario: la ubicación del registro (`Record.lat/lon`, con su
//   precisión) y fotos adicionales.
// - Guardar es local e inmediato (`RecordCapture.save`): el registro aparece en
//   la pantalla de inicio sin esperar a la red.
// - Costos, pieza 4b: en una tarea medida por cantidades, las cantidades por ítem en
//   lugar del % (`QuantityCaptureSection`).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/capture/record_capture.dart';
import '../../core/location/coordinate_system.dart';
import '../../core/location/geo.dart';
import '../../core/forms/form_definition.dart';
import '../../core/forms/geometry.dart';
import '../../core/location/location_source.dart';
import '../../core/providers.dart';
import '../../core/schedule/progress_input.dart';
import '../../core/schedule/quantity_rows.dart';
import '../../data/local/assignment_repository.dart';
import '../../data/local/form_template_repository.dart';
import '../../data/local/schedule_task_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/forms/dynamic_form.dart';
import '../../ui/forms/form_controller.dart';
import '../../ui/forms/template_status.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import 'geometry_capture_screen.dart';
import 'location_capture_sheet.dart';
import 'signature_screen.dart';
import 'qr_capture_screen.dart';
import 'quantity_capture_section.dart';
import 'task_progress_section.dart';

class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key, this.editRecordId, this.assignmentId})
    : assert(editRecordId == null || assignmentId == null);

  /// Fase A: editar este registro en vez de crear uno. Se abre con su misma
  /// versión de plantilla y sus respuestas; solo viaja lo que cambie.
  final String? editRecordId;

  /// Fase B: el registro nuevo cumple esta asignación. Se abre con la versión
  /// de plantilla de la asignación y muestra su punto y la distancia a él.
  final String? assignmentId;

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen> implements FormMediaDelegate, FormQrDelegate {
  @override
  Future<String?> scanQr() =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrCaptureScreen()));
  List<TemplateVersionInfo>? _templates;
  String? _templateId;
  TemplateLookup? _lookup;
  FormController? _form;

  /// Ubicación tomada **en esta pantalla**; al editar, `null` conserva la de
  /// el registro ([_originalFix]).
  LocationFix? _fix;
  LocationFix? _originalFix;
  bool _saving = false;

  bool get _editing => widget.editRecordId != null;

  /// Sistema en que se muestran las coordenadas (Fase C).
  CoordinateSystem get _crs => ref.read(appDependenciesProvider).coordinates.current.value;

  /// La asignación que este registro cumple (Fase B), ya cargada.
  AssignmentItem? _assignment;

  /// Adjuntos de los campos foto/firma, por `id` (lo que guarda `answers`).
  final Map<String, PendingAttachment> _captured = {};
  final List<PendingAttachment> _extraPhotos = [];

  /// Costos, etapa 1: tareas del cronograma del agente y la elegida.
  List<ScheduleTaskItem> _tasks = const [];
  bool _tasksLoaded = false;
  String? _taskId;
  final _progressController = TextEditingController();
  String? _progressError;

  /// Costos, pieza 4b: la tarea elegida se mide por cantidades.
  bool _quantityTask = false;
  late final QuantityCaptureController _quantities;

  /// Las tareas leídas de la BD (la edición las espera para saber cómo se mide la suya).
  late final Future<void> _tasksReady;

  @override
  void initState() {
    super.initState();
    // En `initState` y no perezoso: `dispose` no puede usar `ref` para crearlo.
    _quantities = QuantityCaptureController(
      newId: ref.read(appDependenciesProvider).recordCapture.newAttachmentId,
      readGps: _spotGps,
    );
    _tasksReady = _loadTasks();
    if (_editing) {
      _loadForEdit(widget.editRecordId!);
    } else if (widget.assignmentId != null) {
      _loadForAssignment(widget.assignmentId!);
    } else {
      _loadTemplates();
    }
  }

  Future<void> _loadTasks() async {
    final dependencies = ref.read(appDependenciesProvider);
    final state = dependencies.authController.state;
    if (state is! Authenticated) return;
    final tasks = await dependencies.scheduleTaskRepository.forUser(orgId: state.user.orgId, userId: state.user.id);
    if (mounted) {
      setState(() {
        _tasks = tasks;
        _tasksLoaded = true;
      });
    }
  }

  Future<GpsReading?> _spotGps() async {
    final fix = await ref.read(appDependenciesProvider).spotLocation.read();
    return fix == null ? null : GpsReading(lat: fix.lat, lon: fix.lon, accuracyM: fix.accuracyM);
  }

  /// Elegir otra tarea. Si había cantidades escritas, se confirma antes de descartarlas;
  /// una tarea por cantidades carga sus ítems, ubicaciones y catálogo.
  Future<void> _selectTask(String? id) async {
    if (id == _taskId) return;
    if (_quantityTask && _quantities.hasCaptured) {
      final discard = await _confirmDiscardQuantities();
      if (!discard || !mounted) return;
    }
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    final byQuantities = task?.measuredByQuantities ?? false;
    if (byQuantities) {
      final quantityContext = await ref
          .read(appDependenciesProvider)
          .scheduleTaskRepository
          .quantityContext(taskId: task!.id, projectId: task.projectId);
      if (!mounted) return;
      _quantities.load(quantityContext);
    } else {
      _quantities.clear();
    }
    setState(() {
      // Otra tarea, otro avance: el % de la anterior no vale.
      _progressController.clear();
      _taskId = id;
      _progressError = null;
      _quantityTask = byQuantities;
    });
  }

  Future<bool> _confirmDiscardQuantities() async {
    final l10n = context.l10n;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.quantityDiscardTitle),
        content: Text(l10n.quantityDiscardBody),
        actions: [
          TextButton(
            key: const Key('quantity_discard_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.reviewConfirmCancel),
          ),
          FilledButton(
            key: const Key('quantity_discard_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.quantityDiscardConfirm),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Sin tarea: `ok` y nada que enviar. Con tarea: el % o las cantidades leídas, o el
  /// error en pantalla. Un registro validado (cantidades de solo lectura) no envía nada.
  ({bool ok, TaskProgress? value}) _readProgress(AppLocalizations l10n) {
    final taskId = _taskId;
    if (taskId == null) {
      setState(() => _progressError = null);
      return (ok: true, value: null);
    }
    if (_quantityTask) {
      if (_quantities.readOnly) return (ok: true, value: null);
      return _quantities.validate()
          ? (ok: true, value: TaskProgress(taskId: taskId, quantities: _quantities.payload()))
          : (ok: false, value: null);
    }
    final text = _progressController.text.trim();
    final pct = parseProgressPct(text);
    final error = text.isEmpty
        ? l10n.captureProgressRequired
        : pct == null
        ? l10n.captureProgressInvalid
        : null;
    setState(() => _progressError = error);
    return error == null ? (ok: true, value: TaskProgress(taskId: taskId, pct: pct)) : (ok: false, value: null);
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
    final lookup = await dependencies.formTemplates.forRecord(
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

  Future<void> _loadForEdit(String recordId) async {
    final orgId = _orgId;
    if (orgId == null) return;
    final dependencies = ref.read(appDependenciesProvider);
    final detail = await dependencies.recordStatus.detail(orgId: orgId, recordId: recordId);
    if (detail == null) {
      if (mounted) setState(() => _templates = const []);
      return;
    }
    final lookup = await dependencies.formTemplates.forRecord(
      orgId: orgId,
      templateVersionId: detail.record.templateVersionId,
    );
    if (!mounted) return;
    final record = detail.record;
    setState(() {
      _lookup = lookup;
      _templates = lookup is TemplateReady ? [lookup.info] : const [];
      _form = lookup is TemplateReady ? FormController(lookup.definition, initialAnswers: detail.answers) : null;
      _originalFix = record.lat == null || record.lon == null
          ? null
          : LocationFix(lat: record.lat!, lon: record.lon!, accuracyM: record.accuracyM ?? 0, altitudeM: record.altitudeM);
      _taskId = record.taskId;
      if (record.progressPct != null) _progressController.text = formatProgressPct(record.progressPct!);
    });

    // Costos, pieza 4b: las cantidades del registro, sobre su tarea si sigue en la lista.
    await _tasksReady;
    final stored = decodeQuantities(record.quantitiesJson);
    final taskId = record.taskId;
    final task = _tasks.where((t) => t.id == taskId).firstOrNull;
    if (taskId == null || !mounted || (stored.isEmpty && !(task?.measuredByQuantities ?? false))) return;
    final schedule = dependencies.scheduleTaskRepository;
    final quantityContext = await schedule.quantityContext(taskId: taskId, projectId: task?.projectId);
    final known = await schedule.knownItems({for (final row in stored) row['item_id']! as String});
    if (!mounted) return;
    _quantities.load(quantityContext, stored: stored, known: known, readOnly: record.knownValidated);
    setState(() => _quantityTask = true);
  }

  @override
  void dispose() {
    _form?.dispose();
    _progressController.dispose();
    _quantities.dispose();
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
        .latestForNewRecord(orgId: orgId, templateId: templateId);
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
      id: dependencies.recordCapture.newAttachmentId(),
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

  /// Misma hoja para la ubicación del registro y para los campos de
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
        builder: (_) =>
            GeometryCaptureScreen(kind: kind, title: field.label.resolve(locale), initial: verticesOf(current)),
      ),
    );
  }

  // ---------------------------------------------------------------------------

  Future<PendingAttachment?> _takePhoto() async {
    final dependencies = ref.read(appDependenciesProvider);
    final photo = await dependencies.photoCapture.takePhoto();
    if (photo == null) return null;
    return PendingAttachment(
      id: dependencies.recordCapture.newAttachmentId(),
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
    final formOk = form.validate();
    final progress = _readProgress(l10n);
    if (!formOk || !progress.ok) {
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
    RecordChange change;
    try {
      if (_editing) {
        change = await dependencies.recordCapture.update(
          identity: identity,
          recordId: widget.editRecordId!,
          definition: lookup.definition,
          answers: form.answers,
          captured: Map.of(_captured),
          extraPhotos: List.of(_extraPhotos),
          fix: _fix,
          // Un registro validado no toca su tarea ni sus cantidades.
          progress: _quantityTask && _quantities.readOnly ? null : (value: progress.value),
        );
      } else {
        await dependencies.recordCapture.save(
          identity: identity,
          templateVersionId: lookup.info.id,
          definition: lookup.definition,
          answers: form.answers,
          captured: Map.of(_captured),
          extraPhotos: List.of(_extraPhotos),
          fix: _fix,
          assignmentId: _assignment?.id,
          progress: progress.value,
        );
        change = RecordChange.saved;
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    // El registro y sus fotos salen ya si hay red, sin esperar al siguiente
    // ciclo (Paso 18, Fase A). Sin `await`: no retiene la pantalla ni el
    // guardado; sin red queda en la outbox para el próximo disparo.
    if (change == RecordChange.saved) unawaited(dependencies.syncCoordinator.syncNow());
    if (!mounted) return;
    final message = switch (change) {
      RecordChange.saved => _editing ? l10n.captureUpdated : l10n.captureSaved,
      RecordChange.unchanged => l10n.recordUnchanged,
      RecordChange.notAllowed => l10n.recordNotEditable,
      RecordChange.needsReview => l10n.recordNeedsReview,
      RecordChange.notFound => l10n.recordNotFound,
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    Navigator.of(context).pop(change == RecordChange.saved);
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
                l10n.captureForAssignment(assignment.title ?? assignment.templateName ?? l10n.homeRecordUntitled),
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
              if (_tasks.isNotEmpty || _taskId != null) ...[
                const AppGap.sm(),
                TaskProgressSection(
                  tasks: _tasks,
                  tasksLoaded: _tasksLoaded,
                  selectedId: _taskId,
                  controller: _progressController,
                  errorText: _progressError,
                  locked: _quantityTask && _quantities.readOnly,
                  quantities: _quantityTask ? QuantityCaptureSection(controller: _quantities) : null,
                  onSelected: _selectTask,
                ),
              ],
              const AppGap.sm(),
              Text(l10n.captureRecordLocation, style: Theme.of(context).textTheme.titleSmall),
              if (fix != null) Text(l10n.coordinatesWithAccuracy(_crs.format(fix.lat, fix.lon), fix.accuracyM.round())),
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
