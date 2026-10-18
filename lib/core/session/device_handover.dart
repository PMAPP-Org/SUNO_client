// Cambio de usuario en un teléfono compartido (Fase A, ajustes y sesión).
//
// En campo, un mismo teléfono pasa de un agente a otro. Dos riesgos:
//
// 1. **Atribución.** La outbox se envía con el token de quien tenga la sesión,
//    y el servidor pone `created_by` = ese usuario. Si el agente A cierra
//    sesión con visitas sin enviar y entra B, las visitas de A llegarían como
//    de B. Por eso B no puede entrar mientras haya datos sin enviar de otro:
//    que A vuelva a entrar y sincronice (o resuelva su revisión).
// 2. **Datos de otra organización.** El cursor del pull y las cachés son de
//    la organización anterior; seguir con ellos mezclaría datos (y dejaría a
//    la vista los de otra organización, Ley 1581). Si cambia la
//    organización, se borran del teléfono antes de entrar.
//
// Mismo usuario y misma organización: no se toca nada.
import 'dart:io';

import 'package:drift/drift.dart';

import '../../data/local/database.dart';
import '../auth/auth_models.dart';

sealed class HandoverResult {
  const HandoverResult();
}

/// Puede entrar. [wiped]: se borraron datos de otra organización.
final class HandoverReady extends HandoverResult {
  const HandoverReady({this.wiped = false});
  final bool wiped;
}

/// Hay [visits] visitas sin enviar de otro usuario (u otra organización).
final class HandoverBlocked extends HandoverResult {
  const HandoverBlocked(this.visits);
  final int visits;
}

class DeviceHandover {
  DeviceHandover(this.db, {Future<void> Function(String path)? deleteFile})
    : _deleteFile = deleteFile ?? _deleteIfExists;

  final AppDatabase db;
  final Future<void> Function(String path) _deleteFile;

  /// Antes de dejar entrar a [user] con este teléfono.
  Future<HandoverResult> prepare(UserProfile user) async {
    final foreign = await _visitsWithUnsentDataOfOthers(user);
    if (foreign > 0) return HandoverBlocked(foreign);

    final otherOrg = await (db.select(db.visits)..where((t) => t.orgId.equals(user.orgId).not())..limit(1)).get();
    final otherOrgTemplates =
        await (db.select(db.formTemplateVersions)..where((t) => t.orgId.equals(user.orgId).not())..limit(1)).get();
    if (otherOrg.isEmpty && otherOrgTemplates.isEmpty) return const HandoverReady();

    final files = [for (final row in await db.select(db.attachmentQueue).get()) row.localPath];
    await db.transaction(() async {
      await db.delete(db.outboxOps).go();
      await db.delete(db.visitAttachments).go();
      await db.delete(db.visits).go();
      await db.delete(db.formTemplateVersions).go();
      await db.delete(db.attachmentQueue).go();
      // El cursor es de la organización anterior: el pull empieza de cero.
      await db.delete(db.syncCursor).go();
    });
    for (final path in files) {
      await _deleteFile(path);
    }
    return const HandoverReady(wiped: true);
  }

  /// Visitas con algo en la outbox (ellas o sus adjuntos, en cualquier
  /// estado) que no son de [user] en su organización.
  Future<int> _visitsWithUnsentDataOfOthers(UserProfile user) async {
    final ops = await db.select(db.outboxOps).get();
    if (ops.isEmpty) return 0;
    final attachmentIds = [for (final op in ops) if (op.entity == 'visit_attachment') op.entityId];
    final visitOfAttachment = {
      for (final a in await (db.select(db.visitAttachments)..where((t) => t.id.isIn(attachmentIds))).get())
        a.id: a.visitId,
    };
    final visitIds = {
      for (final op in ops) op.entity == 'visit' ? op.entityId : visitOfAttachment[op.entityId] ?? op.entityId,
    };
    final visits = {
      for (final v in await (db.select(db.visits)..where((t) => t.id.isIn(visitIds))).get()) v.id: v,
    };
    // Una op cuya visita ya no está en el teléfono no se puede atribuir a
    // nadie: cuenta como ajena, del lado seguro.
    return visitIds.where((id) {
      final visit = visits[id];
      return visit == null || visit.createdBy != user.id || visit.orgId != user.orgId;
    }).length;
  }

  /// Cuántas visitas de [user] tienen algo sin enviar (aviso al cerrar sesión).
  Future<int> unsentVisitsOf(UserProfile user) async {
    final ops = await db.select(db.outboxOps).get();
    if (ops.isEmpty) return 0;
    final total = {
      for (final op in ops)
        if (op.entity == 'visit') op.entityId,
    };
    final own = await (db.select(db.visits)..where((t) => t.id.isIn(total) & t.createdBy.equals(user.id))).get();
    return own.length;
  }

  static Future<void> _deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Sin archivo o sin permiso: no impide entrar.
    }
  }
}
