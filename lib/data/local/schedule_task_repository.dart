// Tareas del cronograma del agente (costos, etapa 1), desde la BD local: lo
// que ofrece el selector "Tarea del cronograma" de la captura, sin red. Desde la
// pieza 4b de costos, también lo que la captura de cantidades necesita de cada tarea.
import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import '../../core/schedule/quantity_rows.dart';
import 'database.dart';

@immutable
class ScheduleTaskItem {
  const ScheduleTaskItem({
    required this.id,
    required this.projectName,
    required this.code,
    required this.name,
    required this.lastValidatedPct,
    this.projectId = '',
    this.measuredBy = 'pct',
    this.searchKey = '',
  });

  factory ScheduleTaskItem.fromRow(ScheduleTaskRow row) => ScheduleTaskItem(
    id: row.id,
    projectId: row.projectId,
    projectName: row.projectName,
    // La EDT del Project; si viene vacía, el número de esquema.
    code: row.wbs.isEmpty ? row.outlineNumber : row.wbs,
    name: row.name,
    lastValidatedPct: row.lastValidatedPct,
    measuredBy: row.measuredBy,
    searchKey: _keyOf(row.wbs.isEmpty ? row.outlineNumber : row.wbs, row.name, row.projectName),
  );

  final String id;
  final String projectId;
  final String projectName;
  final String code;
  final String name;
  final double? lastValidatedPct;

  /// Costos, pieza 4b: `quantities` o `pct`.
  final String measuredBy;

  /// EDT, nombre y proyecto sin mayúsculas ni tildes, calculado una vez al leer
  /// la fila; vacío si el ítem se armó a mano (la búsqueda lo calcula entonces).
  final String searchKey;

  String get label => '$code $name';

  /// La captura pide cantidades por ítem en vez del %.
  bool get measuredByQuantities => measuredBy == 'quantities';
}

class ScheduleTaskRepository {
  const ScheduleTaskRepository(this.db);

  final AppDatabase db;

  /// Las tareas de [userId] en [orgId], en el orden en que llegaron.
  Future<List<ScheduleTaskItem>> forUser({required String orgId, required String userId}) async {
    final rows =
        await (db.select(db.scheduleTasks)
              ..where((t) => t.orgId.equals(orgId) & t.userId.equals(userId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get();
    return [for (final row in rows) ScheduleTaskItem.fromRow(row)];
  }

  /// La tarea [id] de la lista guardada, o `null` si ya no está.
  Future<ScheduleTaskItem?> byId(String id) async {
    final row = await (db.select(db.scheduleTasks)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : ScheduleTaskItem.fromRow(row);
  }

  /// Costos, pieza 4b: lo que la captura de cantidades necesita de la tarea [taskId]:
  /// sus ítems planeados, sus ubicaciones y el catálogo del proyecto [projectId]
  /// (vacío si no se conoce el proyecto). Tres consultas.
  Future<QuantityTaskContext> quantityContext({required String taskId, String? projectId}) async {
    final planned =
        await (db.select(db.taskPlannedItems)
              ..where((t) => t.taskId.equals(taskId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get();
    final locations =
        await (db.select(db.taskLocationOptions)
              ..where((t) => t.taskId.equals(taskId))
              ..orderBy([(t) => OrderingTerm.asc(t.position)]))
            .get();
    final catalog = projectId == null
        ? const <ProjectItemRow>[]
        : await (db.select(db.projectItems)
                ..where((t) => t.projectId.equals(projectId))
                ..orderBy([(t) => OrderingTerm.asc(t.position)]))
              .get();
    return QuantityTaskContext(
      taskId: taskId,
      planned: [
        for (final p in planned)
          PlannedQuantity(
            item: QuantityItem(itemId: p.itemId, code: p.code, description: p.description, unit: p.unit),
            planned: p.plannedQuantity,
            validated: p.validatedQuantity,
          ),
      ],
      locations: [
        for (final l in locations) LocationChoice(id: l.locationId, label: l.label, isTaskLocation: l.isTaskLocation),
      ],
      catalog: [
        for (final c in catalog) QuantityItem(itemId: c.itemId, code: c.code, description: c.description, unit: c.unit),
      ],
    );
  }

  /// Código, descripción y unidad de los ítems [itemIds] que el teléfono vio alguna vez.
  Future<Map<String, QuantityItem>> knownItems(Iterable<String> itemIds) async {
    final ids = itemIds.toSet();
    if (ids.isEmpty) return const {};
    final rows = await (db.select(db.knownItems)..where((t) => t.itemId.isIn(ids))).get();
    return {
      for (final r in rows)
        r.itemId: QuantityItem(itemId: r.itemId, code: r.code, description: r.description, unit: r.unit),
    };
  }

  /// La etiqueta ("Tramo 2 / PR 1") de las ubicaciones [locationIds] que están en la
  /// lista guardada.
  Future<Map<String, String>> locationLabels(Iterable<String> locationIds) async {
    final ids = locationIds.toSet();
    if (ids.isEmpty) return const {};
    final rows = await (db.select(db.taskLocationOptions)..where((t) => t.locationId.isIn(ids))).get();
    return {for (final r in rows) r.locationId: r.label};
  }
}

/// Filtra por EDT, nombre o proyecto, sin distinguir mayúsculas ni tildes.
List<ScheduleTaskItem> searchScheduleTasks(List<ScheduleTaskItem> items, String query) {
  final needle = foldForSearch(query.trim());
  if (needle.isEmpty) return items;
  return [
    for (final task in items)
      if ((task.searchKey.isEmpty ? _keyOf(task.code, task.name, task.projectName) : task.searchKey).contains(needle))
        task,
  ];
}

String _keyOf(String code, String name, String project) => foldForSearch('$code $name $project');

String foldForSearch(String text) {
  const from = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const to = 'aaaaaeeeeiiiiooooouuuunc';
  final buffer = StringBuffer();
  for (final char in text.toLowerCase().split('')) {
    final index = from.indexOf(char);
    buffer.write(index < 0 ? char : to[index]);
  }
  return buffer.toString();
}
