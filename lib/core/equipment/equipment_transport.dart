// Contrato del teléfono con `GET /v1/equipment` y
// `POST /v1/equipment/{id}/meter-readings`. La implementación Dio vive en
// `data/http/equipment_api_client.dart`; los tests usan un fake.
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'equipment_models.dart';

sealed class EquipmentFetch {
  const EquipmentFetch();
}

/// La lista no cambió desde la `version` enviada.
final class EquipmentUnchanged extends EquipmentFetch {
  const EquipmentUnchanged();
}

final class EquipmentFetched extends EquipmentFetch {
  const EquipmentFetched({required this.version, required this.items});
  final String version;
  final List<FieldEquipment> items;
}

/// Sin red, sin sesión o respuesta inválida: no se toca la caché.
final class EquipmentFetchFailed extends EquipmentFetch {
  const EquipmentFetchFailed();
}

enum ReadingSendStatus {
  /// El servidor la registró (o ya la tenía: es idempotente por `id`).
  sent,

  /// Error transitorio (red, 5xx): se reintenta en el siguiente ciclo.
  retry,

  /// 403/404/422: el servidor no la aceptará nunca tal como está.
  rejected,
}

@immutable
class ReadingSendResult {
  const ReadingSendResult(this.status, {this.message});
  final ReadingSendStatus status;
  final String? message;
}

@immutable
class OutgoingMeterReading {
  const OutgoingMeterReading({
    required this.id,
    required this.equipmentId,
    required this.meterUnit,
    required this.value,
    required this.readAt,
    required this.notes,
  });

  final String id;
  final String equipmentId;
  final MeterUnit meterUnit;
  final double value;
  final DateTime readAt;
  final String notes;
}

@immutable
class OutgoingInspectionItem {
  const OutgoingInspectionItem({required this.itemId, required this.ok, required this.note});

  final String itemId;
  final bool ok;
  final String note;
}

@immutable
class OutgoingInspection {
  const OutgoingInspection({
    required this.id,
    required this.equipmentId,
    required this.capturedAt,
    required this.meterUnit,
    required this.meterValue,
    required this.items,
    required this.notes,
  });

  final String id;
  final String equipmentId;
  final DateTime capturedAt;
  final MeterUnit? meterUnit;
  final double? meterValue;
  final List<OutgoingInspectionItem> items;
  final String notes;
}

sealed class FuelCatalogFetch {
  const FuelCatalogFetch();
}

final class FuelCatalogUnchanged extends FuelCatalogFetch {
  const FuelCatalogUnchanged();
}

final class FuelCatalogFetched extends FuelCatalogFetch {
  const FuelCatalogFetched({required this.version, required this.catalog});
  final String version;
  final FuelCatalogInfo catalog;
}

final class FuelCatalogFailed extends FuelCatalogFetch {
  const FuelCatalogFailed();
}

@immutable
class OutgoingFuelFill {
  const OutgoingFuelFill({
    required this.id,
    required this.equipmentId,
    required this.source,
    required this.stationId,
    required this.storeId,
    required this.fuelType,
    required this.voucherNumber,
    required this.filledAt,
    required this.gallons,
    required this.meterUnit,
    required this.meterValue,
    required this.workFront,
    required this.driverName,
    required this.driverDocument,
    required this.notes,
  });

  final String id;
  final String equipmentId;
  final FuelSource source;
  final String? stationId;
  final String? storeId;
  final String fuelType;
  final String voucherNumber;
  final DateTime filledAt;
  final double gallons;
  final MeterUnit? meterUnit;
  final double? meterValue;
  final String workFront;
  final String driverName;
  final String driverDocument;
  final String notes;
}

sealed class TransportCatalogFetch {
  const TransportCatalogFetch();
}

final class TransportCatalogUnchanged extends TransportCatalogFetch {
  const TransportCatalogUnchanged();
}

final class TransportCatalogFetched extends TransportCatalogFetch {
  const TransportCatalogFetched({required this.version, required this.catalog});
  final String version;
  final TransportCatalogInfo catalog;
}

final class TransportCatalogFailed extends TransportCatalogFetch {
  const TransportCatalogFailed();
}

@immutable
class OutgoingTrip {
  const OutgoingTrip({
    required this.id,
    required this.equipmentId,
    required this.vehicleId,
    required this.routeId,
    required this.materialId,
    required this.volumeM3,
    required this.recordedAt,
    required this.requestedBy,
    required this.dispatchedBy,
    required this.receivedBy,
    required this.driverName,
    required this.driverDocument,
    required this.notes,
  });

  final String id;
  final String? equipmentId;
  final String? vehicleId;
  final String routeId;
  final String materialId;
  final double volumeM3;
  final DateTime recordedAt;
  final String requestedBy;
  final String dispatchedBy;
  final String receivedBy;
  final String driverName;
  final String driverDocument;
  final String notes;
}

@immutable
class OutgoingUsageReport {
  const OutgoingUsageReport({
    required this.id,
    required this.equipmentId,
    required this.projectId,
    required this.usageDate,
    required this.startMinutes,
    required this.endMinutes,
    required this.activity,
    required this.location,
    required this.startMeter,
    required this.endMeter,
    required this.notes,
  });

  final String id;
  final String equipmentId;
  final String projectId;

  /// `AAAA-MM-DD`, hora local de quien trabajó.
  final String usageDate;
  final int startMinutes;
  final int endMinutes;
  final String activity;
  final String location;
  final double? startMeter;
  final double? endMeter;
  final String notes;
}

abstract class EquipmentTransport {
  Future<EquipmentFetch> fetchList({String? version});
  Future<ReadingSendResult> sendMeterReading(OutgoingMeterReading reading);

  /// Mismo contrato de resultado que las lecturas: enviada, reintentar o rechazada.
  Future<ReadingSendResult> sendInspection(OutgoingInspection inspection);

  /// La Hoja de Vida en PDF; `null` si no se pudo descargar (sin red, sin
  /// permiso o equipo fuera de alcance).
  Future<Uint8List?> fetchLifeSheet(String equipmentId);

  /// Estaciones y tanques propios; `version` permite el "sin cambios".
  Future<FuelCatalogFetch> fetchFuelCatalog({String? version});

  Future<ReadingSendResult> sendFuelFill(OutgoingFuelFill fill);

  /// Tramos, materiales, vehículos de terceros y personas; `version` permite "sin cambios".
  Future<TransportCatalogFetch> fetchTransportCatalog({String? version});

  Future<ReadingSendResult> sendTrip(OutgoingTrip trip);

  Future<ReadingSendResult> sendUsageReport(OutgoingUsageReport report);
}
