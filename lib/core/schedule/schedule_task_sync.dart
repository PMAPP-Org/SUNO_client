// Tareas del cronograma (costos, etapa 1) que el agente puede vincular a una
// visita: las vigentes de detalle de las que es responsable, con su último %
// validado.
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
  });

  factory ScheduleTaskInfo.fromJson(Map<String, dynamic> json) => ScheduleTaskInfo(
    id: json['id'] as String,
    projectId: json['project_id'] as String,
    projectName: json['project_name'] as String,
    wbs: json['wbs'] as String,
    outlineNumber: json['outline_number'] as String,
    name: json['name'] as String,
    lastValidatedPct: (json['last_validated_pct'] as num?)?.toDouble(),
  );

  final String id;
  final String projectId;
  final String projectName;
  final String wbs;
  final String outlineNumber;
  final String name;
  final double? lastValidatedPct;
}

/// Contrato `FieldTaskList`.
@immutable
class ScheduleTaskPage {
  const ScheduleTaskPage({required this.version, required this.changed, required this.items});

  factory ScheduleTaskPage.fromJson(Map<String, dynamic> json) => ScheduleTaskPage(
    version: json['version'] as String,
    changed: json['changed'] as bool,
    items: [
      for (final item in json['items'] as List<dynamic>) ScheduleTaskInfo.fromJson(item as Map<String, dynamic>),
    ],
  );

  final String version;
  final bool changed;
  final List<ScheduleTaskInfo> items;
}

abstract class ScheduleTaskTransport {
  /// `null` sin red o ante una respuesta que no se entiende.
  Future<ScheduleTaskPage?> fetch({String? version});
}

class ScheduleTaskSync {
  ScheduleTaskSync({
    required this.db,
    required this.transport,
    required this.currentUser,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

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
          ),
      ],
    );
    return true;
  }
}
