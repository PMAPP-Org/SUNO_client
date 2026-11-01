// Tareas del cronograma del agente (costos, etapa 1), desde la BD local: lo
// que ofrece el selector "Tarea del cronograma" de la captura, sin red.
import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import 'database.dart';

@immutable
class ScheduleTaskItem {
  const ScheduleTaskItem({
    required this.id,
    required this.projectName,
    required this.code,
    required this.name,
    required this.lastValidatedPct,
    this.searchKey = '',
  });

  factory ScheduleTaskItem.fromRow(ScheduleTaskRow row) => ScheduleTaskItem(
    id: row.id,
    projectName: row.projectName,
    // La EDT del Project; si viene vacía, el número de esquema.
    code: row.wbs.isEmpty ? row.outlineNumber : row.wbs,
    name: row.name,
    lastValidatedPct: row.lastValidatedPct,
    searchKey: _keyOf(row.wbs.isEmpty ? row.outlineNumber : row.wbs, row.name, row.projectName),
  );

  final String id;
  final String projectName;
  final String code;
  final String name;
  final double? lastValidatedPct;

  /// EDT, nombre y proyecto sin mayúsculas ni tildes, calculado una vez al leer
  /// la fila; vacío si el ítem se armó a mano (la búsqueda lo calcula entonces).
  final String searchKey;

  String get label => '$code $name';
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
}

/// Filtra por EDT, nombre o proyecto, sin distinguir mayúsculas ni tildes.
List<ScheduleTaskItem> searchScheduleTasks(List<ScheduleTaskItem> items, String query) {
  final needle = foldForSearch(query.trim());
  if (needle.isEmpty) return items;
  return [
    for (final task in items)
      if ((task.searchKey.isEmpty ? _keyOf(task.code, task.name, task.projectName) : task.searchKey).contains(needle)) task,
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
