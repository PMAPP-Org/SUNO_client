// Equipos de campo (Maquinaria y equipos, fase 1): caché local de la lista de
// equipos visibles, búsqueda por QR o por código/placa, y cola de lecturas de
// medidor con envío idempotente.
//
// **Offline-first**: la lista se guarda en el teléfono y se consulta sin red.
// Una lectura de medidor se valida con lo que el teléfono sabe (el servidor
// decide en última instancia), se encola con un `id` propio y se envía en el
// siguiente ciclo de sincronización; reenviarla tras un corte no la duplica.
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../data/local/database.dart';
import 'equipment_models.dart';
import 'equipment_transport.dart';

/// Prefijo del contenido de los QR de equipo (`suno:eq:<uuid>`).
const kEquipmentQrPrefix = 'suno:eq:';

final _uuidPattern = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

enum ReadingProblem {
  equipmentNotFound,
  unitNotConfigured,
  invalidValue,

  /// Los medidores solo avanzan.
  backwards,
}

class ReadingOutcome {
  const ReadingOutcome.queued(this.id) : problem = null, baseline = null;
  const ReadingOutcome.rejected(this.problem, {this.baseline}) : id = null;

  /// Id de la lectura encolada; `null` si se rechazó.
  final String? id;
  final ReadingProblem? problem;

  /// En `backwards`: la lectura anterior que no se puede bajar.
  final double? baseline;

  bool get ok => problem == null;
}

class PendingMeterReading {
  const PendingMeterReading({
    required this.id,
    required this.equipmentId,
    required this.unit,
    required this.value,
    required this.readAt,
    required this.notes,
    required this.rejected,
    required this.lastError,
  });

  final String id;
  final String equipmentId;
  final MeterUnit unit;
  final double value;
  final DateTime readAt;
  final String notes;

  /// El servidor la rechazó: no se reintenta; [lastError] dice por qué.
  final bool rejected;
  final String? lastError;
}

enum InspectionProblem {
  equipmentNotFound,
  noChecklist,

  /// Falta responder algún ítem de la lista.
  incomplete,

  /// Un ítem con novedad sin descripción.
  faultWithoutNote,
  meterRequired,
  invalidMeter,
  meterBackwards,
}

class InspectionOutcome {
  const InspectionOutcome.queued(this.id) : problem = null, detail = null;
  const InspectionOutcome.rejected(this.problem, {this.detail}) : id = null;

  final String? id;
  final InspectionProblem? problem;

  /// Depende del problema: el ítem sin responder o sin descripción, o la lectura anterior.
  final String? detail;

  bool get ok => problem == null;
}

/// Respuesta a un ítem de la lista de chequeo.
class InspectionAnswer {
  const InspectionAnswer({required this.itemId, required this.ok, this.note = ''});

  final String itemId;
  final bool ok;
  final String note;
}

class PendingInspection {
  const PendingInspection({
    required this.id,
    required this.equipmentId,
    required this.capturedAt,
    required this.hasFaults,
    required this.rejected,
    required this.lastError,
  });

  final String id;
  final String equipmentId;
  final DateTime capturedAt;
  final bool hasFaults;
  final bool rejected;
  final String? lastError;
}

enum FuelProblem {
  equipmentNotFound,

  /// No se eligió estación o tanque, o no existe en el catálogo del teléfono.
  sourceMissing,
  voucherRequired,
  invalidGallons,
  meterRequired,
  invalidMeter,
  meterBackwards,
}

class FuelOutcome {
  const FuelOutcome.queued(this.id) : problem = null, detail = null;
  const FuelOutcome.rejected(this.problem, {this.detail}) : id = null;

  final String? id;
  final FuelProblem? problem;

  /// En `meterBackwards`: la lectura anterior.
  final String? detail;

  bool get ok => problem == null;
}

class PendingFuelFill {
  const PendingFuelFill({
    required this.id,
    required this.equipmentId,
    required this.filledAt,
    required this.gallons,
    required this.voucherNumber,
    required this.rejected,
    required this.lastError,
  });

  final String id;
  final String equipmentId;
  final DateTime filledAt;
  final double gallons;
  final String voucherNumber;
  final bool rejected;
  final String? lastError;
}

enum TripProblem {
  /// Ni equipo propio ni vehículo de terceros, o los dos, o no existen.
  vehicleMissing,
  routeMissing,
  materialMissing,
  invalidVolume,

  /// El volumen supera la capacidad del vehículo de terceros.
  overCapacity,

  /// Falta alguna de las tres personas, no existe, o quien despacha es quien recibe.
  peopleMissing,
  sameDispatcherAndReceiver,
}

class TripOutcome {
  const TripOutcome.queued(this.id) : problem = null, detail = null;
  const TripOutcome.rejected(this.problem, {this.detail}) : id = null;

  final String? id;
  final TripProblem? problem;

  /// En `overCapacity`: la capacidad del vehículo.
  final String? detail;

  bool get ok => problem == null;
}

class PendingTrip {
  const PendingTrip({
    required this.id,
    required this.recordedAt,
    required this.volumeM3,
    required this.vehicleLabel,
    required this.rejected,
    required this.lastError,
  });

  final String id;
  final DateTime recordedAt;
  final double volumeM3;

  /// Código del equipo o placa del vehículo, tal como se eligió.
  final String vehicleLabel;
  final bool rejected;
  final String? lastError;
}

enum UsageProblem {
  equipmentNotFound,

  /// El proyecto no es uno de los que el servidor ofrece para este equipo hoy.
  projectMissing,
  activityRequired,

  /// La hora final no es posterior a la inicial.
  invalidTimes,
  futureTime,
  meterRequired,
  invalidMeter,

  /// La lectura inicial es menor que la última conocida del medidor.
  meterBackwards,

  /// Se cruza con otro uso del equipo ya reportado o pendiente de envío.
  overlap,
}

class UsageOutcome {
  const UsageOutcome.queued(this.id) : problem = null, detail = null;
  const UsageOutcome.rejected(this.problem, {this.detail}) : id = null;

  final String? id;
  final UsageProblem? problem;

  /// Según el problema: la lectura anterior o el uso con el que se cruza.
  final String? detail;

  bool get ok => problem == null;
}

class PendingUsageReport {
  const PendingUsageReport({
    required this.id,
    required this.equipmentId,
    required this.usageDate,
    required this.startMinutes,
    required this.endMinutes,
    required this.activity,
    required this.rejected,
    required this.lastError,
  });

  final String id;
  final String equipmentId;
  final DateTime usageDate;
  final int startMinutes;
  final int endMinutes;
  final String activity;
  final bool rejected;
  final String? lastError;
}

class EquipmentManager {
  EquipmentManager({
    required this.db,
    required this.transport,
    required this.session,
    DateTime Function()? clock,
    String Function()? newId,
  }) : _now = clock ?? DateTime.now,
       _newId = newId ?? (() => const Uuid().v4());

  final AppDatabase db;
  final EquipmentTransport transport;

  /// Organización y usuario con sesión; `null` si no hay (no se sincroniza).
  final ({String orgId, String userId})? Function() session;
  final DateTime Function() _now;
  final String Function() _newId;

  /// Extrae el id de un QR `suno:eq:<uuid>` (primera línea); `null` si no lo es.
  static String? parseQr(String scan) {
    final firstLine = scan.split(RegExp(r'\r?\n')).first.trim();
    if (!firstLine.startsWith(kEquipmentQrPrefix)) return null;
    final id = firstLine.substring(kEquipmentQrPrefix.length).toLowerCase();
    return _uuidPattern.hasMatch(id) ? id : null;
  }

  // ---------------------------------------------------------------- lista

  /// Descarga la lista si cambió y reemplaza la caché. `false` si no se pudo
  /// (sin sesión o sin red): la caché anterior queda intacta.
  Future<bool> refresh() async {
    final who = session();
    if (who == null) return false;
    final meta = await (db.select(db.equipmentCatalogMeta)..where((t) => t.id.equals(0))).getSingleOrNull();
    final known = meta != null && meta.orgId == who.orgId ? meta.version : null;
    final result = await transport.fetchList(version: known);
    switch (result) {
      case EquipmentUnchanged():
        return true;
      case EquipmentFetchFailed():
        return false;
      case EquipmentFetched(:final version, :final items):
        await db.transaction(() async {
          await db.delete(db.equipmentCache).go();
          for (final item in items) {
            await db
                .into(db.equipmentCache)
                .insert(
                  EquipmentCacheCompanion.insert(
                    id: item.id,
                    orgId: who.orgId,
                    code: item.code,
                    qrIdentifier: item.qrIdentifier,
                    dataJson: jsonEncode(item.raw),
                  ),
                );
          }
          await db
              .into(db.equipmentCatalogMeta)
              .insertOnConflictUpdate(
                EquipmentCatalogMetaCompanion.insert(orgId: who.orgId, version: version, fetchedAt: _now()),
              );
        });
        return true;
    }
  }

  Future<List<FieldEquipment>> list() async {
    final rows = await (db.select(db.equipmentCache)..orderBy([(t) => OrderingTerm.asc(t.code)])).get();
    return [for (final row in rows) FieldEquipment.fromJson(jsonDecode(row.dataJson) as Map<String, dynamic>)];
  }

  Future<FieldEquipment?> byId(String id) async {
    final row = await (db.select(db.equipmentCache)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : FieldEquipment.fromJson(jsonDecode(row.dataJson) as Map<String, dynamic>);
  }

  /// Resuelve lo leído de un QR: primero `suno:eq:<uuid>`; si no, coincidencia
  /// exacta (sin distinguir mayúsculas) con el código interno o la placa.
  Future<FieldEquipment?> findByScan(String scan) async {
    final id = parseQr(scan);
    if (id != null) return byId(id);
    final needle = scan.trim().toLowerCase();
    if (needle.isEmpty) return null;
    for (final item in await list()) {
      if (item.code.toLowerCase() == needle ||
          (item.licensePlate.isNotEmpty && item.licensePlate.toLowerCase() == needle)) {
        return item;
      }
    }
    return null;
  }

  // ------------------------------------------------------------- lecturas

  /// Valida una lectura con lo que el teléfono sabe y la encola. Los medidores
  /// solo avanzan: se compara con la última lectura conocida (caché) y con las
  /// pendientes del mismo medidor. El servidor sigue siendo quien decide.
  Future<ReadingOutcome> recordReading({
    required String equipmentId,
    required MeterUnit unit,
    required double value,
    DateTime? readAt,
    String notes = '',
  }) async {
    final who = session();
    final equipment = await byId(equipmentId);
    if (who == null || equipment == null) return const ReadingOutcome.rejected(ReadingProblem.equipmentNotFound);
    if (!equipment.meterUnits.contains(unit)) return const ReadingOutcome.rejected(ReadingProblem.unitNotConfigured);
    if (value.isNaN || value.isInfinite || value < 0) {
      return const ReadingOutcome.rejected(ReadingProblem.invalidValue);
    }
    final baseline = await _baseline(equipment, unit);
    if (baseline != null && value < baseline) {
      return ReadingOutcome.rejected(ReadingProblem.backwards, baseline: baseline);
    }
    final id = _newId();
    await db
        .into(db.meterReadingOutbox)
        .insert(
          MeterReadingOutboxCompanion.insert(
            id: id,
            orgId: who.orgId,
            userId: who.userId,
            equipmentId: equipmentId,
            meterUnit: unit.name,
            value: value,
            readAt: (readAt ?? _now()).toUtc(),
            notes: Value(notes.trim()),
          ),
        );
    return ReadingOutcome.queued(id);
  }

  Future<double?> _baseline(FieldEquipment equipment, MeterUnit unit) async {
    var best = equipment.meter(unit)?.value;
    final pending =
        await (db.select(db.meterReadingOutbox)..where(
              (t) => t.equipmentId.equals(equipment.id) & t.meterUnit.equals(unit.name) & t.state.equals('pending'),
            ))
            .get();
    for (final row in pending) {
      if (best == null || row.value > best) best = row.value;
    }
    // Un uso todavía sin enviar también fija la lectura más alta conocida.
    final usages =
        await (db.select(db.usageReportOutbox)
              ..where((t) => t.equipmentId.equals(equipment.id) & t.state.equals('pending')))
            .get();
    if (unit == equipment.meterUnits.firstOrNull) {
      for (final row in usages) {
        final value = row.endMeter;
        if (value != null && (best == null || value > best)) best = value;
      }
    }
    // Un tanqueo todavía sin enviar también fija la lectura más alta conocida.
    final fills =
        await (db.select(db.fuelFillOutbox)..where(
              (t) => t.equipmentId.equals(equipment.id) & t.meterUnit.equals(unit.name) & t.state.equals('pending'),
            ))
            .get();
    for (final row in fills) {
      final value = row.meterValue;
      if (value != null && (best == null || value > best)) best = value;
    }
    return best;
  }

  /// Lecturas aún sin confirmar (pendientes y rechazadas) de un equipo.
  Future<List<PendingMeterReading>> pendingFor(String equipmentId) async {
    final rows =
        await (db.select(db.meterReadingOutbox)
              ..where((t) => t.equipmentId.equals(equipmentId))
              ..orderBy([(t) => OrderingTerm.desc(t.readAt)]))
            .get();
    return [for (final row in rows) _pending(row)];
  }

  Future<int> pendingCount() async {
    final rows = await (db.select(db.meterReadingOutbox)..where((t) => t.state.equals('pending'))).get();
    return rows.length;
  }

  PendingMeterReading _pending(MeterReadingOutboxRow row) => PendingMeterReading(
    id: row.id,
    equipmentId: row.equipmentId,
    unit: MeterUnit.values.byName(row.meterUnit),
    value: row.value,
    readAt: row.readAt,
    notes: row.notes,
    rejected: row.state == 'rejected',
    lastError: row.lastError,
  );

  /// Descarta una lectura rechazada que la persona ya revisó.
  Future<void> dismissRejected(String id) =>
      (db.delete(db.meterReadingOutbox)..where((t) => t.id.equals(id) & t.state.equals('rejected'))).go();

  /// Envía las lecturas del usuario con sesión en orden cronológico. Se detiene
  /// en el primer error transitorio (sin red no tiene sentido seguir). Devuelve
  /// cuántas confirmó el servidor.
  Future<int> flushReadings() async {
    final who = session();
    if (who == null) return 0;
    final rows =
        await (db.select(db.meterReadingOutbox)
              ..where((t) => t.state.equals('pending') & t.userId.equals(who.userId) & t.orgId.equals(who.orgId))
              ..orderBy([(t) => OrderingTerm.asc(t.readAt)]))
            .get();
    var sent = 0;
    for (final row in rows) {
      final result = await transport.sendMeterReading(
        OutgoingMeterReading(
          id: row.id,
          equipmentId: row.equipmentId,
          meterUnit: MeterUnit.values.byName(row.meterUnit),
          value: row.value,
          readAt: row.readAt,
          notes: row.notes,
        ),
      );
      switch (result.status) {
        case ReadingSendStatus.sent:
          await (db.delete(db.meterReadingOutbox)..where((t) => t.id.equals(row.id))).go();
          sent++;
        case ReadingSendStatus.rejected:
          await (db.update(db.meterReadingOutbox)..where((t) => t.id.equals(row.id))).write(
            MeterReadingOutboxCompanion(
              state: const Value('rejected'),
              attempts: Value(row.attempts + 1),
              lastError: Value(result.message),
            ),
          );
        case ReadingSendStatus.retry:
          await (db.update(db.meterReadingOutbox)..where((t) => t.id.equals(row.id))).write(
            MeterReadingOutboxCompanion(attempts: Value(row.attempts + 1), lastError: Value(result.message)),
          );
          return sent;
      }
    }
    return sent;
  }

  /// Descarga la Hoja de Vida (PDF). Es un documento oficial generado por el
  /// servidor con lo que quien consulta puede ver; no se guarda en el teléfono.
  Future<Uint8List?> lifeSheet(String equipmentId) {
    if (session() == null) return Future.value();
    return transport.fetchLifeSheet(equipmentId);
  }

  // -------------------------------------------------------- preoperacional

  /// Valida el preoperacional con lo que el teléfono sabe y lo encola. Exige
  /// una respuesta por cada ítem de la lista, la descripción de cada novedad y
  /// la lectura inicial del medidor si el equipo se controla por medidor. El
  /// servidor sigue siendo quien decide (todo o nada).
  Future<InspectionOutcome> submitInspection({
    required String equipmentId,
    required List<InspectionAnswer> answers,
    double? meterValue,
    String notes = '',
    DateTime? capturedAt,
  }) async {
    final who = session();
    final equipment = await byId(equipmentId);
    if (who == null || equipment == null) return const InspectionOutcome.rejected(InspectionProblem.equipmentNotFound);
    if (equipment.checklist.isEmpty) return const InspectionOutcome.rejected(InspectionProblem.noChecklist);
    final byItem = {for (final answer in answers) answer.itemId: answer};
    for (final item in equipment.checklist) {
      final answer = byItem[item.id];
      if (answer == null) return InspectionOutcome.rejected(InspectionProblem.incomplete, detail: item.label);
      if (!answer.ok && answer.note.trim().isEmpty) {
        return InspectionOutcome.rejected(InspectionProblem.faultWithoutNote, detail: item.label);
      }
    }
    MeterUnit? unit;
    if (equipment.needsMeterForInspection) {
      unit = equipment.meterUnits.first;
      if (meterValue == null) return const InspectionOutcome.rejected(InspectionProblem.meterRequired);
      if (meterValue.isNaN || meterValue.isInfinite || meterValue < 0) {
        return const InspectionOutcome.rejected(InspectionProblem.invalidMeter);
      }
      final baseline = await _baseline(equipment, unit);
      if (baseline != null && meterValue < baseline) {
        return InspectionOutcome.rejected(InspectionProblem.meterBackwards, detail: baseline.toString());
      }
    }
    final id = _newId();
    await db
        .into(db.inspectionOutbox)
        .insert(
          InspectionOutboxCompanion.insert(
            id: id,
            orgId: who.orgId,
            userId: who.userId,
            equipmentId: equipmentId,
            capturedAt: (capturedAt ?? _now()).toUtc(),
            meterUnit: Value(unit?.name),
            meterValue: Value(meterValue),
            itemsJson: jsonEncode([
              for (final item in equipment.checklist)
                {'item_id': item.id, 'ok': byItem[item.id]!.ok, 'note': byItem[item.id]!.note.trim()},
            ]),
            notes: Value(notes.trim()),
          ),
        );
    return InspectionOutcome.queued(id);
  }

  Future<List<PendingInspection>> pendingInspectionsFor(String equipmentId) async {
    final rows =
        await (db.select(db.inspectionOutbox)
              ..where((t) => t.equipmentId.equals(equipmentId))
              ..orderBy([(t) => OrderingTerm.desc(t.capturedAt)]))
            .get();
    return [
      for (final row in rows)
        PendingInspection(
          id: row.id,
          equipmentId: row.equipmentId,
          capturedAt: row.capturedAt,
          hasFaults: (jsonDecode(row.itemsJson) as List<dynamic>).any((i) => (i as Map<String, dynamic>)['ok'] == false),
          rejected: row.state == 'rejected',
          lastError: row.lastError,
        ),
    ];
  }

  Future<int> pendingInspectionCount() async =>
      (await (db.select(db.inspectionOutbox)..where((t) => t.state.equals('pending'))).get()).length;

  Future<void> dismissRejectedInspection(String id) =>
      (db.delete(db.inspectionOutbox)..where((t) => t.id.equals(id) & t.state.equals('rejected'))).go();

  /// Envía los preoperacionales del usuario con sesión, del más antiguo al más
  /// nuevo; se detiene en el primer error transitorio. Devuelve cuántos confirmó
  /// el servidor.
  Future<int> flushInspections() async {
    final who = session();
    if (who == null) return 0;
    final rows =
        await (db.select(db.inspectionOutbox)
              ..where((t) => t.state.equals('pending') & t.userId.equals(who.userId) & t.orgId.equals(who.orgId))
              ..orderBy([(t) => OrderingTerm.asc(t.capturedAt)]))
            .get();
    var sent = 0;
    for (final row in rows) {
      final result = await transport.sendInspection(
        OutgoingInspection(
          id: row.id,
          equipmentId: row.equipmentId,
          capturedAt: row.capturedAt,
          meterUnit: MeterUnit.tryParse(row.meterUnit),
          meterValue: row.meterValue,
          items: [
            for (final item in jsonDecode(row.itemsJson) as List<dynamic>)
              OutgoingInspectionItem(
                itemId: (item as Map<String, dynamic>)['item_id'] as String,
                ok: item['ok'] as bool,
                note: item['note'] as String,
              ),
          ],
          notes: row.notes,
        ),
      );
      switch (result.status) {
        case ReadingSendStatus.sent:
          await (db.delete(db.inspectionOutbox)..where((t) => t.id.equals(row.id))).go();
          sent++;
        case ReadingSendStatus.rejected:
          await (db.update(db.inspectionOutbox)..where((t) => t.id.equals(row.id))).write(
            InspectionOutboxCompanion(
              state: const Value('rejected'),
              attempts: Value(row.attempts + 1),
              lastError: Value(result.message),
            ),
          );
        case ReadingSendStatus.retry:
          await (db.update(db.inspectionOutbox)..where((t) => t.id.equals(row.id))).write(
            InspectionOutboxCompanion(attempts: Value(row.attempts + 1), lastError: Value(result.message)),
          );
          return sent;
      }
    }
    return sent;
  }

  // ---------------------------------------------------------- combustibles

  /// Trae el catálogo de combustible (estaciones y tanques) si cambió. `false`
  /// sin sesión o sin red: el catálogo anterior queda intacto.
  Future<bool> refreshFuelCatalog() async {
    final who = session();
    if (who == null) return false;
    final row = await (db.select(db.fuelCatalogCache)..where((t) => t.id.equals(0))).getSingleOrNull();
    final known = row != null && row.orgId == who.orgId ? row.version : null;
    final result = await transport.fetchFuelCatalog(version: known);
    switch (result) {
      case FuelCatalogUnchanged():
        return true;
      case FuelCatalogFailed():
        return false;
      case FuelCatalogFetched(:final version, :final catalog):
        await db
            .into(db.fuelCatalogCache)
            .insertOnConflictUpdate(
              FuelCatalogCacheCompanion.insert(orgId: who.orgId, version: version, dataJson: jsonEncode(catalog.toJson())),
            );
        return true;
    }
  }

  Future<FuelCatalogInfo> fuelCatalog() async {
    final row = await (db.select(db.fuelCatalogCache)..where((t) => t.id.equals(0))).getSingleOrNull();
    if (row == null) return FuelCatalogInfo.empty;
    return FuelCatalogInfo.fromJson(jsonDecode(row.dataJson) as Map<String, dynamic>);
  }

  /// Valida el tanqueo con lo que el teléfono sabe y lo encola: vale y galones
  /// obligatorios, un origen que exista en el catálogo y, en equipos con
  /// medidor, la lectura (que no puede bajar). El servidor decide en última
  /// instancia (vale repetido, stock del tanque…).
  Future<FuelOutcome> submitFuelFill({
    required String equipmentId,
    required FuelSource source,
    String? stationId,
    String? storeId,
    required String voucherNumber,
    required double gallons,
    double? meterValue,
    String workFront = '',
    String driverName = '',
    String driverDocument = '',
    String notes = '',
    String fuelType = 'acpm',
    DateTime? filledAt,
  }) async {
    final who = session();
    final equipment = await byId(equipmentId);
    if (who == null || equipment == null) return const FuelOutcome.rejected(FuelProblem.equipmentNotFound);
    final catalog = await fuelCatalog();
    final originOk = switch (source) {
      FuelSource.station => stationId != null && catalog.stations.any((s) => s.id == stationId),
      FuelSource.store => storeId != null && catalog.stores.any((s) => s.id == storeId),
    };
    if (!originOk) return const FuelOutcome.rejected(FuelProblem.sourceMissing);
    if (voucherNumber.trim().isEmpty) return const FuelOutcome.rejected(FuelProblem.voucherRequired);
    if (gallons.isNaN || gallons.isInfinite || gallons <= 0) return const FuelOutcome.rejected(FuelProblem.invalidGallons);
    MeterUnit? unit;
    if (equipment.needsMeterForInspection) {
      unit = equipment.meterUnits.first;
      if (meterValue == null) return const FuelOutcome.rejected(FuelProblem.meterRequired);
      if (meterValue.isNaN || meterValue.isInfinite || meterValue < 0) {
        return const FuelOutcome.rejected(FuelProblem.invalidMeter);
      }
      final baseline = await _baseline(equipment, unit);
      if (baseline != null && meterValue < baseline) {
        return FuelOutcome.rejected(FuelProblem.meterBackwards, detail: baseline.toString());
      }
    }
    final id = _newId();
    await db
        .into(db.fuelFillOutbox)
        .insert(
          FuelFillOutboxCompanion.insert(
            id: id,
            orgId: who.orgId,
            userId: who.userId,
            equipmentId: equipmentId,
            source: source.name,
            stationId: Value(source == FuelSource.station ? stationId : null),
            storeId: Value(source == FuelSource.store ? storeId : null),
            fuelType: Value(fuelType),
            voucherNumber: voucherNumber.trim(),
            filledAt: (filledAt ?? _now()).toUtc(),
            gallons: gallons,
            meterUnit: Value(unit?.name),
            meterValue: Value(meterValue),
            workFront: Value(workFront.trim()),
            driverName: Value(driverName.trim()),
            driverDocument: Value(driverDocument.trim()),
            notes: Value(notes.trim()),
          ),
        );
    return FuelOutcome.queued(id);
  }

  Future<List<PendingFuelFill>> pendingFuelFillsFor(String equipmentId) async {
    final rows =
        await (db.select(db.fuelFillOutbox)
              ..where((t) => t.equipmentId.equals(equipmentId))
              ..orderBy([(t) => OrderingTerm.desc(t.filledAt)]))
            .get();
    return [
      for (final row in rows)
        PendingFuelFill(
          id: row.id,
          equipmentId: row.equipmentId,
          filledAt: row.filledAt,
          gallons: row.gallons,
          voucherNumber: row.voucherNumber,
          rejected: row.state == 'rejected',
          lastError: row.lastError,
        ),
    ];
  }

  Future<int> pendingFuelFillCount() async =>
      (await (db.select(db.fuelFillOutbox)..where((t) => t.state.equals('pending'))).get()).length;

  Future<void> dismissRejectedFuelFill(String id) =>
      (db.delete(db.fuelFillOutbox)..where((t) => t.id.equals(id) & t.state.equals('rejected'))).go();

  /// Envía los tanqueos del usuario con sesión, del más antiguo al más nuevo;
  /// se detiene en el primer error transitorio. Devuelve cuántos confirmó el servidor.
  Future<int> flushFuelFills() async {
    final who = session();
    if (who == null) return 0;
    final rows =
        await (db.select(db.fuelFillOutbox)
              ..where((t) => t.state.equals('pending') & t.userId.equals(who.userId) & t.orgId.equals(who.orgId))
              ..orderBy([(t) => OrderingTerm.asc(t.filledAt)]))
            .get();
    var sent = 0;
    for (final row in rows) {
      final result = await transport.sendFuelFill(
        OutgoingFuelFill(
          id: row.id,
          equipmentId: row.equipmentId,
          source: FuelSource.tryParse(row.source) ?? FuelSource.station,
          stationId: row.stationId,
          storeId: row.storeId,
          fuelType: row.fuelType,
          voucherNumber: row.voucherNumber,
          filledAt: row.filledAt,
          gallons: row.gallons,
          meterUnit: MeterUnit.tryParse(row.meterUnit),
          meterValue: row.meterValue,
          workFront: row.workFront,
          driverName: row.driverName,
          driverDocument: row.driverDocument,
          notes: row.notes,
        ),
      );
      switch (result.status) {
        case ReadingSendStatus.sent:
          await (db.delete(db.fuelFillOutbox)..where((t) => t.id.equals(row.id))).go();
          sent++;
        case ReadingSendStatus.rejected:
          await (db.update(db.fuelFillOutbox)..where((t) => t.id.equals(row.id))).write(
            FuelFillOutboxCompanion(
              state: const Value('rejected'),
              attempts: Value(row.attempts + 1),
              lastError: Value(result.message),
            ),
          );
        case ReadingSendStatus.retry:
          await (db.update(db.fuelFillOutbox)..where((t) => t.id.equals(row.id))).write(
            FuelFillOutboxCompanion(attempts: Value(row.attempts + 1), lastError: Value(result.message)),
          );
          return sent;
      }
    }
    return sent;
  }

  // ------------------------------------------------------------- transporte

  /// Trae el catálogo de transporte si cambió. `false` sin sesión o sin red:
  /// el catálogo anterior queda intacto.
  Future<bool> refreshTransportCatalog() async {
    final who = session();
    if (who == null) return false;
    final row = await (db.select(db.transportCatalogCache)..where((t) => t.id.equals(0))).getSingleOrNull();
    final known = row != null && row.orgId == who.orgId ? row.version : null;
    final result = await transport.fetchTransportCatalog(version: known);
    switch (result) {
      case TransportCatalogUnchanged():
        return true;
      case TransportCatalogFailed():
        return false;
      case TransportCatalogFetched(:final version, :final catalog):
        await db
            .into(db.transportCatalogCache)
            .insertOnConflictUpdate(
              TransportCatalogCacheCompanion.insert(
                orgId: who.orgId,
                version: version,
                dataJson: jsonEncode(catalog.toJson()),
              ),
            );
        return true;
    }
  }

  Future<TransportCatalogInfo> transportCatalog() async {
    final row = await (db.select(db.transportCatalogCache)..where((t) => t.id.equals(0))).getSingleOrNull();
    if (row == null) return TransportCatalogInfo.empty;
    return TransportCatalogInfo.fromJson(jsonDecode(row.dataJson) as Map<String, dynamic>);
  }

  /// Valida el viaje con lo que el teléfono sabe y lo encola: exactamente un
  /// vehículo (equipo propio o de terceros), tramo y material del catálogo,
  /// volumen mayor que cero y dentro de la capacidad, y tres personas de las
  /// cuales quien despacha no es quien recibe. El servidor decide en última
  /// instancia.
  Future<TripOutcome> submitTrip({
    String? equipmentId,
    String? vehicleId,
    required String routeId,
    required String materialId,
    required double volumeM3,
    required String requestedBy,
    required String dispatchedBy,
    required String receivedBy,
    String driverName = '',
    String driverDocument = '',
    String notes = '',
    DateTime? recordedAt,
  }) async {
    final who = session();
    if (who == null || (equipmentId == null) == (vehicleId == null)) {
      return const TripOutcome.rejected(TripProblem.vehicleMissing);
    }
    final catalog = await transportCatalog();
    if (equipmentId != null && await byId(equipmentId) == null) {
      return const TripOutcome.rejected(TripProblem.vehicleMissing);
    }
    TransportVehicleInfo? vehicle;
    if (vehicleId != null) {
      vehicle = catalog.vehicles.where((v) => v.id == vehicleId).firstOrNull;
      if (vehicle == null) return const TripOutcome.rejected(TripProblem.vehicleMissing);
    }
    if (!catalog.routes.any((r) => r.id == routeId)) return const TripOutcome.rejected(TripProblem.routeMissing);
    if (!catalog.materials.any((m) => m.id == materialId)) {
      return const TripOutcome.rejected(TripProblem.materialMissing);
    }
    if (volumeM3.isNaN || volumeM3.isInfinite || volumeM3 <= 0) {
      return const TripOutcome.rejected(TripProblem.invalidVolume);
    }
    final capacity = vehicle?.capacityM3;
    if (capacity != null && volumeM3 > capacity) {
      return TripOutcome.rejected(TripProblem.overCapacity, detail: formatCapacity(capacity));
    }
    final known = {for (final p in catalog.people) p.id};
    if (![requestedBy, dispatchedBy, receivedBy].every(known.contains)) {
      return const TripOutcome.rejected(TripProblem.peopleMissing);
    }
    if (dispatchedBy == receivedBy) return const TripOutcome.rejected(TripProblem.sameDispatcherAndReceiver);
    final id = _newId();
    await db
        .into(db.tripOutbox)
        .insert(
          TripOutboxCompanion.insert(
            id: id,
            orgId: who.orgId,
            userId: who.userId,
            equipmentId: Value(equipmentId),
            vehicleId: Value(vehicleId),
            routeId: routeId,
            materialId: materialId,
            volumeM3: volumeM3,
            recordedAt: (recordedAt ?? _now()).toUtc(),
            requestedBy: requestedBy,
            dispatchedBy: dispatchedBy,
            receivedBy: receivedBy,
            driverName: Value(driverName.trim()),
            driverDocument: Value(driverDocument.trim()),
            notes: Value(notes.trim()),
          ),
        );
    return TripOutcome.queued(id);
  }

  /// Capacidad sin ceros sobrantes: 14.0 → "14".
  static String formatCapacity(double value) => value == value.roundToDouble() ? value.toStringAsFixed(0) : '$value';

  /// Viajes aún sin confirmar (pendientes y rechazados) de esta sesión.
  Future<List<PendingTrip>> pendingTrips() async {
    final rows = await (db.select(db.tripOutbox)..orderBy([(t) => OrderingTerm.desc(t.recordedAt)])).get();
    final catalog = await transportCatalog();
    final plates = {for (final v in catalog.vehicles) v.id: v.plate};
    final codes = {for (final e in await list()) e.id: e.code};
    return [
      for (final row in rows)
        PendingTrip(
          id: row.id,
          recordedAt: row.recordedAt,
          volumeM3: row.volumeM3,
          vehicleLabel: plates[row.vehicleId] ?? codes[row.equipmentId] ?? '',
          rejected: row.state == 'rejected',
          lastError: row.lastError,
        ),
    ];
  }

  Future<int> pendingTripCount() async =>
      (await (db.select(db.tripOutbox)..where((t) => t.state.equals('pending'))).get()).length;

  Future<void> dismissRejectedTrip(String id) =>
      (db.delete(db.tripOutbox)..where((t) => t.id.equals(id) & t.state.equals('rejected'))).go();

  /// Envía los viajes del usuario con sesión, del más antiguo al más nuevo; se
  /// detiene en el primer error transitorio. Devuelve cuántos confirmó el servidor.
  Future<int> flushTrips() async {
    final who = session();
    if (who == null) return 0;
    final rows =
        await (db.select(db.tripOutbox)
              ..where((t) => t.state.equals('pending') & t.userId.equals(who.userId) & t.orgId.equals(who.orgId))
              ..orderBy([(t) => OrderingTerm.asc(t.recordedAt)]))
            .get();
    var sent = 0;
    for (final row in rows) {
      final result = await transport.sendTrip(
        OutgoingTrip(
          id: row.id,
          equipmentId: row.equipmentId,
          vehicleId: row.vehicleId,
          routeId: row.routeId,
          materialId: row.materialId,
          volumeM3: row.volumeM3,
          recordedAt: row.recordedAt,
          requestedBy: row.requestedBy,
          dispatchedBy: row.dispatchedBy,
          receivedBy: row.receivedBy,
          driverName: row.driverName,
          driverDocument: row.driverDocument,
          notes: row.notes,
        ),
      );
      switch (result.status) {
        case ReadingSendStatus.sent:
          await (db.delete(db.tripOutbox)..where((t) => t.id.equals(row.id))).go();
          sent++;
        case ReadingSendStatus.rejected:
          await (db.update(db.tripOutbox)..where((t) => t.id.equals(row.id))).write(
            TripOutboxCompanion(
              state: const Value('rejected'),
              attempts: Value(row.attempts + 1),
              lastError: Value(result.message),
            ),
          );
        case ReadingSendStatus.retry:
          await (db.update(db.tripOutbox)..where((t) => t.id.equals(row.id))).write(
            TripOutboxCompanion(attempts: Value(row.attempts + 1), lastError: Value(result.message)),
          );
          return sent;
      }
    }
    return sent;
  }

  // -------------------------------------------------------- uso del equipo

  static String _day(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// Valida el reporte de uso con lo que el teléfono sabe y lo encola: proyecto
  /// de los ofrecidos para el equipo, actividad, horas coherentes y no futuras,
  /// lecturas del medidor (en equipos con medidor) que no retroceden, y sin
  /// cruce con otro uso del equipo ya reportado o en cola. El servidor decide
  /// en última instancia (asignación, vinculación al proyecto, solape con otros
  /// usos del operador).
  Future<UsageOutcome> submitUsageReport({
    required String equipmentId,
    required String projectId,
    required DateTime usageDate,
    required int startMinutes,
    required int endMinutes,
    required String activity,
    String location = '',
    double? startMeter,
    double? endMeter,
    String notes = '',
  }) async {
    final who = session();
    final equipment = await byId(equipmentId);
    if (who == null || equipment == null) return const UsageOutcome.rejected(UsageProblem.equipmentNotFound);
    if (!equipment.usageProjects.any((p) => p.id == projectId)) {
      return const UsageOutcome.rejected(UsageProblem.projectMissing);
    }
    if (activity.trim().isEmpty) return const UsageOutcome.rejected(UsageProblem.activityRequired);
    if (endMinutes <= startMinutes) return const UsageOutcome.rejected(UsageProblem.invalidTimes);
    final now = _now().toLocal();
    final ends = DateTime(usageDate.year, usageDate.month, usageDate.day).add(Duration(minutes: endMinutes));
    if (ends.isAfter(now.add(const Duration(minutes: 5)))) return const UsageOutcome.rejected(UsageProblem.futureTime);

    final unit = equipment.needsMeterForInspection ? equipment.meterUnits.first : null;
    if (unit != null) {
      if (startMeter == null || endMeter == null) return const UsageOutcome.rejected(UsageProblem.meterRequired);
      if (startMeter.isNaN || endMeter.isNaN || startMeter < 0 || endMeter < startMeter) {
        return const UsageOutcome.rejected(UsageProblem.invalidMeter);
      }
      final baseline = await _baseline(equipment, unit);
      if (baseline != null && startMeter < baseline) {
        return UsageOutcome.rejected(UsageProblem.meterBackwards, detail: baseline.toString());
      }
    }

    final day = _day(usageDate);
    bool crosses(int otherStart, int otherEnd) => startMinutes < otherEnd && endMinutes > otherStart;
    for (final usage in equipment.recentUsage) {
      if (usage.status != 'cancelled' &&
          _day(usage.usageDate) == day &&
          crosses(usage.startMinutes, usage.endMinutes)) {
        return UsageOutcome.rejected(UsageProblem.overlap, detail: usage.activity);
      }
    }
    final queued =
        await (db.select(db.usageReportOutbox)
              ..where((t) => t.equipmentId.equals(equipmentId) & t.usageDate.equals(day) & t.state.equals('pending')))
            .get();
    for (final row in queued) {
      if (crosses(row.startMinutes, row.endMinutes)) {
        return UsageOutcome.rejected(UsageProblem.overlap, detail: row.activity);
      }
    }

    final id = _newId();
    await db
        .into(db.usageReportOutbox)
        .insert(
          UsageReportOutboxCompanion.insert(
            id: id,
            orgId: who.orgId,
            userId: who.userId,
            equipmentId: equipmentId,
            projectId: projectId,
            usageDate: day,
            startMinutes: startMinutes,
            endMinutes: endMinutes,
            activity: activity.trim(),
            location: Value(location.trim()),
            startMeter: Value(unit == null ? null : startMeter),
            endMeter: Value(unit == null ? null : endMeter),
            notes: Value(notes.trim()),
          ),
        );
    return UsageOutcome.queued(id);
  }

  Future<List<PendingUsageReport>> pendingUsageFor(String equipmentId) async {
    final rows =
        await (db.select(db.usageReportOutbox)
              ..where((t) => t.equipmentId.equals(equipmentId))
              ..orderBy([(t) => OrderingTerm.desc(t.usageDate), (t) => OrderingTerm.desc(t.startMinutes)]))
            .get();
    return [
      for (final row in rows)
        PendingUsageReport(
          id: row.id,
          equipmentId: row.equipmentId,
          usageDate: DateTime.parse(row.usageDate),
          startMinutes: row.startMinutes,
          endMinutes: row.endMinutes,
          activity: row.activity,
          rejected: row.state == 'rejected',
          lastError: row.lastError,
        ),
    ];
  }

  Future<int> pendingUsageCount() async =>
      (await (db.select(db.usageReportOutbox)..where((t) => t.state.equals('pending'))).get()).length;

  Future<void> dismissRejectedUsage(String id) =>
      (db.delete(db.usageReportOutbox)..where((t) => t.id.equals(id) & t.state.equals('rejected'))).go();

  /// Envía los reportes de uso del usuario con sesión, del más antiguo al más
  /// nuevo; se detiene en el primer error transitorio. Devuelve cuántos
  /// confirmó el servidor.
  Future<int> flushUsage() async {
    final who = session();
    if (who == null) return 0;
    final rows =
        await (db.select(db.usageReportOutbox)
              ..where((t) => t.state.equals('pending') & t.userId.equals(who.userId) & t.orgId.equals(who.orgId))
              ..orderBy([(t) => OrderingTerm.asc(t.usageDate), (t) => OrderingTerm.asc(t.startMinutes)]))
            .get();
    var sent = 0;
    for (final row in rows) {
      final result = await transport.sendUsageReport(
        OutgoingUsageReport(
          id: row.id,
          equipmentId: row.equipmentId,
          projectId: row.projectId,
          usageDate: row.usageDate,
          startMinutes: row.startMinutes,
          endMinutes: row.endMinutes,
          activity: row.activity,
          location: row.location,
          startMeter: row.startMeter,
          endMeter: row.endMeter,
          notes: row.notes,
        ),
      );
      switch (result.status) {
        case ReadingSendStatus.sent:
          await (db.delete(db.usageReportOutbox)..where((t) => t.id.equals(row.id))).go();
          sent++;
        case ReadingSendStatus.rejected:
          await (db.update(db.usageReportOutbox)..where((t) => t.id.equals(row.id))).write(
            UsageReportOutboxCompanion(
              state: const Value('rejected'),
              attempts: Value(row.attempts + 1),
              lastError: Value(result.message),
            ),
          );
        case ReadingSendStatus.retry:
          await (db.update(db.usageReportOutbox)..where((t) => t.id.equals(row.id))).write(
            UsageReportOutboxCompanion(attempts: Value(row.attempts + 1), lastError: Value(result.message)),
          );
          return sent;
      }
    }
    return sent;
  }

  /// Un ciclo de sincronización de equipos: primero lo que se tomó en campo
  /// (lecturas, uso, preoperacionales, tanqueos y viajes), luego los catálogos y
  /// la lista actualizada, que ya trae el estado de lo enviado.
  Future<void> sync() async {
    await flushReadings();
    await flushUsage();
    await flushInspections();
    await flushFuelFills();
    await flushTrips();
    await refreshFuelCatalog();
    await refreshTransportCatalog();
    await refresh();
  }
}
