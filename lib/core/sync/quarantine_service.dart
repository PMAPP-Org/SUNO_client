// Revisión de la cuarentena (Paso 23): lo que el servidor rechazó o lo que
// chocó con un cambio hecho en el servidor, agrupado por visita, y las
// acciones para resolverlo.
//
// **Regla del paso (N-05, doc 08 §7.2): nada descarta el trabajo del agente
// sin que él lo pida.** Por eso:
// - un conflicto llega aquí con la fila del servidor guardada, sin aplicarla
//   (`SyncEngine`). El agente elige: [resendMine] (su versión gana, como
//   `update` sobre la versión actual del servidor) o [acceptServer];
// - un rechazo se puede [retry] (con `op_uuid` nuevo: el servidor recuerda el
//   rechazo de cada `op_uuid`), [correct] (corregir las respuestas y reenviar)
//   o [discard] (borra la visita del teléfono). Descartar y aceptar la del
//   servidor son las únicas acciones que pierden datos, y la UI las confirma.
//
// Una visita rechazada arrastra a sus adjuntos: el servidor también los
// rechaza (su visita no existe). Las acciones se aplican al grupo entero y
// conservan el orden (visita antes que adjuntos).
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:meta/meta.dart';

import '../../data/local/database.dart';
import 'sync_engine.dart';
import 'sync_transport.dart';

enum QuarantineKind { conflict, rejected }

/// Un campo que difiere entre la versión del agente y la del servidor.
typedef FieldDiff = ({String field, Object? mine, Object? server});

@immutable
class QuarantinedVisit {
  const QuarantinedVisit({
    required this.visit,
    required this.templateName,
    required this.kind,
    required this.code,
    required this.message,
    required this.violations,
    required this.serverData,
    required this.ops,
  });

  /// La visita tal como está en el teléfono (la versión del agente).
  final Visit visit;
  final String? templateName;
  final QuarantineKind kind;

  /// `code` del contrato (`validation_error`, `not_found`, `conflict`…).
  final String? code;
  final String message;

  /// Campos señalados por el servidor, tal cual (`answers.altura_cm`,
  /// `template_version_id`…).
  final List<FieldViolation> violations;

  /// Las violaciones que son de **respuestas**, por clave de campo
  /// (`altura_cm` → `out_of_range`): lo que el agente puede corregir.
  Map<String, String> get answerViolations => {
    for (final v in violations)
      if (v.field.startsWith('answers.')) v.field.substring('answers.'.length): v.reason,
  };

  /// `data` de la fila autoritativa, solo en conflictos.
  final Map<String, dynamic>? serverData;

  /// Las operaciones en cuarentena del grupo, en orden de envío.
  final List<OutboxOp> ops;

  Map<String, Object?> get localAnswers => (jsonDecode(visit.answersJson) as Map).cast<String, Object?>();

  /// ¿Tiene sentido abrir el formulario para corregir? Solo si el servidor
  /// señaló respuestas concretas.
  bool get canCorrect => kind == QuarantineKind.rejected && answerViolations.isNotEmpty;

  /// Diferencias campo a campo con el servidor (conflictos): respuestas y
  /// ubicación. Las claves de respuesta van tal cual (`altura_cm`).
  List<FieldDiff> get differences {
    final server = serverData;
    if (server == null) return const [];
    final mineAnswers = localAnswers;
    final serverAnswers = (server['answers'] as Map?)?.cast<String, Object?>() ?? const {};
    final diffs = <FieldDiff>[
      for (final key in {...mineAnswers.keys, ...serverAnswers.keys})
        if (!_sameJson(mineAnswers[key], serverAnswers[key]))
          (field: key, mine: mineAnswers[key], server: serverAnswers[key]),
    ];
    for (final (key, mine) in [('lat', visit.lat), ('lon', visit.lon)]) {
      if (!_sameJson(mine, server[key])) diffs.add((field: key, mine: mine, server: server[key]));
    }
    return diffs;
  }
}

bool _sameJson(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

class QuarantineService {
  QuarantineService({required this.db, required this.engine, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase db;
  final SyncEngine engine;
  final DateTime Function() _now;

  static const _quarantine = 'quarantine';
  static const _pending = 'pending';

  /// Las visitas de [orgId] con algo en cuarentena, la más reciente primero.
  Future<List<QuarantinedVisit>> list({required String orgId}) async {
    final ops =
        await (db.select(db.outboxOps)
              ..where((t) => t.state.equals(_quarantine))
              ..orderBy([
                (t) => OrderingTerm.asc(t.createdAt),
                (t) => OrderingTerm.asc(const CustomExpression<int>('rowid')),
              ]))
            .get();
    final byVisit = <String, List<OutboxOp>>{};
    for (final op in ops) {
      final visitId = _visitOf(op);
      if (visitId != null) byVisit.putIfAbsent(visitId, () => []).add(op);
    }
    if (byVisit.isEmpty) return const [];

    final visits =
        await (db.select(db.visits)
              ..where((t) => t.id.isIn(byVisit.keys) & t.orgId.equals(orgId))
              ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)]))
            .get();
    final names = {
      for (final row
          in await (db.select(
            db.formTemplateVersions,
          )..where((t) => t.id.isIn({for (final v in visits) v.templateVersionId}))).get())
        row.id: row.name,
    };

    return [
      for (final visit in visits) _describe(visit, names[visit.templateVersionId], byVisit[visit.id]!),
    ];
  }

  /// Cuántas visitas de [orgId] esperan revisión (para el aviso de la portada).
  Future<int> count({required String orgId}) async => (await list(orgId: orgId)).length;

  /// Reintenta el grupo tal cual, con `op_uuid` nuevos y en el mismo orden.
  /// Útil cuando la causa ya desapareció (p. ej. la plantilla llegó por fin).
  Future<void> retry(QuarantinedVisit item) => db.transaction(() async {
    for (final op in item.ops) {
      await engine.retryQuarantined(op.opUuid);
    }
  });

  /// Corrige las respuestas de una visita rechazada y reenvía el grupo.
  /// [answers] son las respuestas ya corregidas (solo campos visibles).
  Future<void> correct(QuarantinedVisit item, Map<String, Object?> answers) => db.transaction(() async {
    final answersJson = jsonEncode(answers);
    await (db.update(db.visits)..where((t) => t.id.equals(item.visit.id))).write(
      VisitsCompanion(answersJson: Value(answersJson)),
    );
    for (final op in item.ops) {
      if (op.entity == 'visit' && op.opType != 'delete') {
        final payload = (jsonDecode(op.payloadJson) as Map).cast<String, Object?>()..['answers'] = answers;
        await (db.update(db.outboxOps)..where((t) => t.opUuid.equals(op.opUuid))).write(
          OutboxOpsCompanion(payloadJson: Value(jsonEncode(payload))),
        );
      }
      await engine.retryQuarantined(op.opUuid);
    }
  });

  /// Conflicto: la versión del agente gana. Se envía como `update` sobre la
  /// versión **actual** del servidor (su `version` como `base_version`), con
  /// los campos en los que difieren. Si ya no difieren, es lo mismo que
  /// aceptar la del servidor.
  Future<void> resendMine(QuarantinedVisit item) => db.transaction(() async {
    final server = item.serverData;
    if (item.kind != QuarantineKind.conflict || server == null) {
      throw StateError('resendMine solo resuelve conflictos con fila del servidor.');
    }
    final changed = <String, Object?>{};
    if (!_sameJson(item.localAnswers, server['answers'])) changed['answers'] = item.localAnswers;
    final visit = item.visit;
    for (final (key, mine) in [
      ('lat', visit.lat),
      ('lon', visit.lon),
      ('accuracy_m', visit.accuracyM),
      ('altitude_m', visit.altitudeM),
    ]) {
      if (!_sameJson(mine, server[key])) changed[key] = mine;
    }
    if (changed.isEmpty) {
      await _acceptServer(item, server);
      return;
    }
    final serverVersion = server['version'] as int;
    await _deleteOps(item.ops);
    await (db.update(db.visits)..where((t) => t.id.equals(visit.id))).write(
      VisitsCompanion(version: Value(serverVersion)),
    );
    await db
        .into(db.outboxOps)
        .insert(
          OutboxOpsCompanion.insert(
            opUuid: engine.newOpUuid(),
            entity: 'visit',
            entityId: visit.id,
            opType: 'update',
            baseVersion: Value(serverVersion),
            payloadJson: jsonEncode({'id': visit.id, ...changed}),
            state: _pending,
            createdAt: _now().toUtc(),
          ),
        );
  });

  /// Conflicto: el agente se queda con la versión del servidor. **Pierde sus
  /// cambios**: la UI lo confirma antes de llamar aquí.
  Future<void> acceptServer(QuarantinedVisit item) => db.transaction(() async {
    final server = item.serverData;
    if (item.kind != QuarantineKind.conflict || server == null) {
      throw StateError('acceptServer solo resuelve conflictos con fila del servidor.');
    }
    await _acceptServer(item, server);
  });

  /// Rechazo: borra la visita del teléfono, sus adjuntos y sus operaciones.
  /// **Pierde la visita**: la UI lo confirma antes de llamar aquí. Las fotos
  /// que ninguna otra visita usa salen también de la cola de subida.
  Future<void> discard(QuarantinedVisit item) => db.transaction(() async {
    final visitId = item.visit.id;
    final attachments = await (db.select(db.visitAttachments)..where((t) => t.visitId.equals(visitId))).get();
    final attachmentIds = [for (final a in attachments) a.id];
    await (db.delete(db.outboxOps)..where((t) => t.entityId.isIn([visitId, ...attachmentIds]))).go();
    await (db.delete(db.visitAttachments)..where((t) => t.visitId.equals(visitId))).go();
    await (db.delete(db.visits)..where((t) => t.id.equals(visitId))).go();
    for (final sha in {for (final a in attachments) a.sha256}) {
      final stillUsed = await (db.select(db.visitAttachments)..where((t) => t.sha256.equals(sha))).get();
      if (stillUsed.isEmpty) {
        await (db.delete(
          db.attachmentQueue,
        )..where((t) => t.sha256.equals(sha) & t.state.isNotValue('uploaded'))).go();
      }
    }
  });

  Future<void> _acceptServer(QuarantinedVisit item, Map<String, dynamic> server) async {
    if (!await engine.applyServerRecord({'entity': 'visit', 'data': server})) {
      throw StateError('La fila del servidor guardada no tiene la forma del contrato.');
    }
    await _deleteOps(item.ops);
  }

  Future<void> _deleteOps(List<OutboxOp> ops) =>
      (db.delete(db.outboxOps)..where((t) => t.opUuid.isIn([for (final op in ops) op.opUuid]))).go();

  QuarantinedVisit _describe(Visit visit, String? templateName, List<OutboxOp> ops) {
    final visitOp = ops.where((op) => op.entity == 'visit').firstOrNull;
    final lead = visitOp ?? ops.first;
    final isConflict = lead.errorCode == 'conflict' && lead.serverRowJson != null;
    final serverRecord = isConflict ? jsonDecode(lead.serverRowJson!) : null;
    return QuarantinedVisit(
      visit: visit,
      templateName: templateName,
      kind: isConflict ? QuarantineKind.conflict : QuarantineKind.rejected,
      code: lead.errorCode,
      message: lead.errorMessage ?? '',
      violations: [for (final op in ops) ..._violations(op.errorFieldsJson)],
      serverData: serverRecord is Map && serverRecord['data'] is Map
          ? (serverRecord['data'] as Map).cast<String, dynamic>()
          : null,
      ops: ops,
    );
  }

  static List<FieldViolation> _violations(String? json) {
    if (json == null) return const [];
    final decoded = jsonDecode(json);
    return decoded is List ? fieldViolations({'errors': decoded}) : const [];
  }

  static String? _visitOf(OutboxOp op) {
    if (op.entity == 'visit') return op.entityId;
    if (op.entity == 'visit_attachment') {
      final payload = jsonDecode(op.payloadJson);
      return payload is Map && payload['visit_id'] is String ? payload['visit_id'] as String : null;
    }
    return null;
  }
}
