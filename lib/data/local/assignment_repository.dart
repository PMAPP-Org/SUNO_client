// Asignaciones del agente (Fase B): el trabajo planificado que le toca, con
// si ya hizo el registro. Todo desde la BD local, sin red.
//
// El servidor no lleva un estado "hecha": una asignación está hecha en este
// teléfono cuando existe un registro (no borrado) que la referencia.
import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import '../../core/location/navigation_target.dart';

import 'database.dart';

@immutable
class AssignmentItem {
  const AssignmentItem({
    required this.id,
    required this.templateVersionId,
    required this.templateName,
    required this.title,
    required this.scheduledFor,
    required this.lat,
    required this.lon,
    required this.recordId,
  });

  final String id;
  final String templateVersionId;

  /// Nombre de la plantilla, si está en la caché local.
  final String? templateName;
  final String? title;
  final DateTime? scheduledFor;
  final double? lat;
  final double? lon;

  /// El registro que la cumplió, si ya se hizo.
  final String? recordId;

  bool get done => recordId != null;
  NavigationTarget? get navigationTarget => NavigationTarget.tryCreate(lat, lon);
  bool get hasPoint => navigationTarget != null;
}

class AssignmentRepository {
  const AssignmentRepository(this.db);

  final AppDatabase db;

  /// Las asignaciones de [userId] en [orgId]: primero las pendientes, por
  /// fecha programada (las que no tienen fecha al final), y luego las hechas.
  Future<List<AssignmentItem>> forUser({required String orgId, required String userId}) async {
    final rows =
        await (db.select(db.assignments)..where((t) => t.orgId.equals(orgId) & t.assignedTo.equals(userId))).get();
    final items = [...await _items(rows)];
    final far = DateTime.utc(9999);
    return items..sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      return (a.scheduledFor ?? far).compareTo(b.scheduledFor ?? far);
    });
  }

  Future<AssignmentItem?> byId({required String orgId, required String id}) async {
    final row =
        await (db.select(db.assignments)..where((t) => t.orgId.equals(orgId) & t.id.equals(id))).getSingleOrNull();
    return row == null ? null : (await _items([row])).single;
  }

  Future<List<AssignmentItem>> _items(List<Assignment> rows) async {
    if (rows.isEmpty) return const [];
    final ids = [for (final r in rows) r.id];
    final records =
        await (db.select(db.records)..where((t) => t.assignmentId.isIn(ids) & t.deletedAt.isNull())).get();
    final recordOf = {for (final v in records) v.assignmentId!: v.id};
    final names = {
      for (final t
          in await (db.select(
            db.formTemplateVersions,
          )..where((t) => t.id.isIn({for (final r in rows) r.templateVersionId}))).get())
        t.id: t.name,
    };
    return [
      for (final r in rows)
        AssignmentItem(
          id: r.id,
          templateVersionId: r.templateVersionId,
          templateName: names[r.templateVersionId],
          title: r.title,
          scheduledFor: r.scheduledFor,
          lat: r.lat,
          lon: r.lon,
          recordId: recordOf[r.id],
        ),
    ];
  }
}
