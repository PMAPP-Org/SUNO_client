// Tareas del cronograma (costos, etapa 1) que el agente puede vincular a un
// registro: las vigentes de detalle de las que es responsable, con su último %
// validado y, desde la pieza 4b de costos, cómo se mide, sus ítems planeados, sus
// ubicaciones y el catálogo de ítems de sus proyectos.
//
// Mismo ciclo que las capas de referencia (`layers/layer_manager.dart`): el
// servidor entrega la lista **entera** (`GET /v1/projects/tasks`) y el
// teléfono la reemplaza, así que lo que ya no viene (tarea retirada,
// responsabilidad quitada) desaparece sin tombstones. Para no bajarla en cada
// ciclo se envía la `version` de la última lista: si no cambió, el servidor
// contesta `changed: false` sin ítems. Sin red no se toca nada: la captura
// sigue con la última lista descargada.
import 'package:drift/drift.dart' show Value;
import 'package:meta/meta.dart';

import '../../data/local/database.dart';
import '../auth/auth_models.dart';

/// Contrato `FieldPlannedItem` (costos, pieza 4).
@immutable
class PlannedItemInfo {
  const PlannedItemInfo({
    required this.itemId,
    required this.code,
    required this.description,
    required this.unit,
    required this.plannedQuantity,
    required this.validatedQuantity,
  });

  factory PlannedItemInfo.fromJson(Map<String, dynamic> json) => PlannedItemInfo(
    itemId: json['item_id'] as String,
    code: json['code'] as String,
    description: json['description'] as String,
    unit: json['unit'] as String,
    plannedQuantity: (json['planned_quantity'] as num).toDouble(),
    validatedQuantity: (json['executed_quantity'] as num).toDouble(),
  );

  final String itemId;
  final String code;
  final String description;
  final String unit;
  final double plannedQuantity;

  /// `executed_quantity`: lo de los registros validados.
  final double validatedQuantity;
}

/// Contrato `FieldLocation`.
@immutable
class LocationInfo {
  const LocationInfo({required this.id, required this.label});

  factory LocationInfo.fromJson(Map<String, dynamic> json) =>
      LocationInfo(id: json['id'] as String, label: json['label'] as String);

  final String id;
  final String label;
}

/// Contrato `FieldProjectItem` (costos, pieza 4b).
@immutable
class CatalogItemInfo {
  const CatalogItemInfo({required this.itemId, required this.code, required this.description, required this.unit});

  factory CatalogItemInfo.fromJson(Map<String, dynamic> json) => CatalogItemInfo(
    itemId: json['item_id'] as String,
    code: json['code'] as String,
    description: json['description'] as String,
    unit: json['unit'] as String,
  );

  final String itemId;
  final String code;
  final String description;
  final String unit;
}

/// Contrato `FieldProjectItems` (costos, pieza 4b).
@immutable
class ProjectCatalog {
  const ProjectCatalog({required this.projectId, required this.items});

  factory ProjectCatalog.fromJson(Map<String, dynamic> json) => ProjectCatalog(
    projectId: json['project_id'] as String,
    items: [for (final item in json['items'] as List<dynamic>) CatalogItemInfo.fromJson(item as Map<String, dynamic>)],
  );

  final String projectId;
  final List<CatalogItemInfo> items;
}

/// Contrato `FieldTask`.
@immutable
class ScheduleTaskInfo {
  const ScheduleTaskInfo({
    required this.id,
    required this.projectId,
    required this.projectName,
    required this.wbs,
    required this.outlineNumber,
    required this.name,
    this.lastValidatedPct,
    this.measuredBy = 'pct',
    this.location,
    this.locationOptions = const [],
    this.plannedItems = const [],
  });

  factory ScheduleTaskInfo.fromJson(Map<String, dynamic> json) => ScheduleTaskInfo(
    id: json['id'] as String,
    projectId: json['project_id'] as String,
    projectName: json['project_name'] as String,
    wbs: json['wbs'] as String,
    outlineNumber: json['outline_number'] as String,
    name: json['name'] as String,
    lastValidatedPct: (json['last_validated_pct'] as num?)?.toDouble(),
    measuredBy: json['measured_by'] as String? ?? 'pct',
    location: json['location'] == null ? null : LocationInfo.fromJson(json['location'] as Map<String, dynamic>),
    locationOptions: [
      for (final option in json['location_options'] as List<dynamic>? ?? const [])
        LocationInfo.fromJson(option as Map<String, dynamic>),
    ],
    plannedItems: [
      for (final item in json['planned_items'] as List<dynamic>? ?? const [])
        PlannedItemInfo.fromJson(item as Map<String, dynamic>),
    ],
  );

  final String id;
  final String projectId;
  final String projectName;
  final String wbs;
  final String outlineNumber;
  final String name;
  final double? lastValidatedPct;

  /// Costos, pieza 4: `quantities` o `pct`.
  final String measuredBy;
  final LocationInfo? location;
  final List<LocationInfo> locationOptions;
  final List<PlannedItemInfo> plannedItems;
}

/// Contrato `FieldTaskList`.
@immutable
class ScheduleTaskPage {
  const ScheduleTaskPage({
    required this.version,
    required this.changed,
    required this.items,
    this.projectItems = const [],
  });

  factory ScheduleTaskPage.fromJson(Map<String, dynamic> json) => ScheduleTaskPage(
    version: json['version'] as String,
    changed: json['changed'] as bool,
    items: [for (final item in json['items'] as List<dynamic>) ScheduleTaskInfo.fromJson(item as Map<String, dynamic>)],
    projectItems: [
      for (final project in json['project_items'] as List<dynamic>? ?? const [])
        ProjectCatalog.fromJson(project as Map<String, dynamic>),
    ],
  );

  final String version;
  final bool changed;
  final List<ScheduleTaskInfo> items;

  /// Costos, pieza 4b: el catálogo de ítems de cada proyecto de la lista.
  final List<ProjectCatalog> projectItems;
}

abstract class ScheduleTaskTransport {
  /// `null` sin red o ante una respuesta que no se entiende.
  Future<ScheduleTaskPage?> fetch({String? version});
}

class ScheduleTaskSync {
  ScheduleTaskSync({required this.db, required this.transport, required this.currentUser, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase db;
  final ScheduleTaskTransport transport;

  /// Quién tiene la sesión; `null` sin sesión.
  final UserProfile? Function() currentUser;
  final DateTime Function() _now;

  Future<bool>? _running;

  /// Trae la lista si cambió. `true` si el teléfono quedó al día. Una a la vez.
  Future<bool> refresh() => _running ??= _refresh().whenComplete(() => _running = null);

  Future<bool> _refresh() async {
    final user = currentUser();
    if (user == null) return false;
    final state = await db.readScheduleTaskState();
    // La versión guardada solo vale si la lista es de este usuario.
    final known = state != null && state.userId == user.id && state.orgId == user.orgId ? state.version : null;
    final page = await transport.fetch(version: known);
    if (page == null) return false;
    // Sin cambios no se toca nada; sin versión enviada no hay nada que dar por vigente.
    if (!page.changed) return known != null;
    await db.replaceScheduleTasks(
      orgId: user.orgId,
      userId: user.id,
      version: page.version,
      now: _now().toUtc(),
      rows: [
        for (final (position, task) in page.items.indexed)
          ScheduleTasksCompanion.insert(
            id: task.id,
            orgId: user.orgId,
            userId: user.id,
            projectId: task.projectId,
            projectName: task.projectName,
            wbs: task.wbs,
            outlineNumber: task.outlineNumber,
            name: task.name,
            lastValidatedPct: Value(task.lastValidatedPct),
            position: position,
            measuredBy: Value(task.measuredBy),
          ),
      ],
      planned: [
        for (final task in page.items)
          for (final (position, item) in task.plannedItems.indexed)
            TaskPlannedItemsCompanion.insert(
              taskId: task.id,
              itemId: item.itemId,
              code: item.code,
              description: item.description,
              unit: item.unit,
              plannedQuantity: item.plannedQuantity,
              validatedQuantity: item.validatedQuantity,
              position: position,
            ),
      ],
      locations: [
        for (final task in page.items)
          for (final (position, option) in task.locationOptions.indexed)
            TaskLocationOptionsCompanion.insert(
              taskId: task.id,
              locationId: option.id,
              label: option.label,
              isTaskLocation: option.id == task.location?.id,
              position: position,
            ),
      ],
      catalog: [
        for (final project in page.projectItems)
          for (final (position, item) in project.items.indexed)
            ProjectItemsCompanion.insert(
              projectId: project.projectId,
              itemId: item.itemId,
              code: item.code,
              description: item.description,
              unit: item.unit,
              position: position,
            ),
      ],
    );
    return true;
  }
}
