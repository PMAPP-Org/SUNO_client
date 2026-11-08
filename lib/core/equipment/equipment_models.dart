// Equipos de campo (Maquinaria y equipos, fase 1): la ficha resumida que el
// servidor entrega en `GET /v1/equipment` y que el teléfono guarda para
// consultarla sin red. Solo lectura: lo único que el teléfono escribe son las
// lecturas de medidor (`equipment_manager.dart`).
import 'package:meta/meta.dart';

/// Medidores del contrato (`MeterUnit`). El nombre del enum es el valor del
/// contrato.
enum MeterUnit {
  hours,
  kilometers;

  static MeterUnit? tryParse(String? value) {
    for (final unit in values) {
      if (unit.name == value) return unit;
    }
    return null;
  }
}

@immutable
class EquipmentMeter {
  const EquipmentMeter({
    required this.unit,
    required this.label,
    required this.isPrimary,
    required this.value,
    required this.readAt,
  });

  factory EquipmentMeter.fromJson(Map<String, dynamic> json) => EquipmentMeter(
    unit: MeterUnit.values.byName(json['unit'] as String),
    label: json['label'] as String,
    isPrimary: json['is_primary'] as bool,
    value: (json['value'] as num).toDouble(),
    readAt: DateTime.parse(json['read_at'] as String),
  );

  final MeterUnit unit;
  final String label;
  final bool isPrimary;
  final double value;
  final DateTime readAt;
}

@immutable
class EquipmentDocumentInfo {
  const EquipmentDocumentInfo({
    required this.id,
    required this.type,
    required this.name,
    required this.number,
    required this.expiresOn,
  });

  factory EquipmentDocumentInfo.fromJson(Map<String, dynamic> json) => EquipmentDocumentInfo(
    id: json['id'] as String,
    type: json['type'] as String,
    name: json['name'] as String,
    number: json['number'] as String,
    expiresOn: json['expires_on'] == null ? null : DateTime.parse(json['expires_on'] as String),
  );

  final String id;
  final String type;
  final String name;
  final String number;
  final DateTime? expiresOn;
}

@immutable
class EquipmentFieldInfo {
  const EquipmentFieldInfo({required this.name, required this.type, required this.value});

  factory EquipmentFieldInfo.fromJson(Map<String, dynamic> json) =>
      EquipmentFieldInfo(name: json['name'] as String, type: json['type'] as String, value: json['value']);

  final String name;

  /// `number`, `date` o `text`.
  final String type;

  /// Número, fecha ISO o texto según [type]; `null` si no tiene valor.
  final Object? value;
}

@immutable
class EquipmentAlertInfo {
  const EquipmentAlertInfo({
    required this.source,
    required this.name,
    required this.expiresOn,
    required this.daysLeft,
  });

  factory EquipmentAlertInfo.fromJson(Map<String, dynamic> json) => EquipmentAlertInfo(
    source: json['source'] as String,
    name: json['name'] as String,
    expiresOn: DateTime.parse(json['expires_on'] as String),
    daysLeft: json['days_left'] as int,
  );

  /// `field` (campo de fecha con aviso) o `document`.
  final String source;
  final String name;
  final DateTime expiresOn;

  /// Negativo: ya venció.
  final int daysLeft;

  bool get expired => daysLeft < 0;
}

@immutable
class ChecklistItemInfo {
  const ChecklistItemInfo({required this.id, required this.label, required this.critical});

  factory ChecklistItemInfo.fromJson(Map<String, dynamic> json) =>
      ChecklistItemInfo(id: json['id'] as String, label: json['label'] as String, critical: json['critical'] as bool);

  final String id;
  final String label;
  final bool critical;
}

/// Estado de una inspección ya enviada (contrato `InspectionStatus`).
enum InspectionStatus {
  submitted,
  approved,
  rejected,
  correctionRequested;

  static InspectionStatus parse(String wire) => switch (wire) {
    'approved' => approved,
    'rejected' => rejected,
    'correction_requested' => correctionRequested,
    _ => submitted,
  };
}

@immutable
class InspectionSummary {
  const InspectionSummary({
    required this.id,
    required this.capturedAt,
    required this.status,
    required this.hasFaults,
    required this.reviewComment,
  });

  factory InspectionSummary.fromJson(Map<String, dynamic> json) => InspectionSummary(
    id: json['id'] as String,
    capturedAt: DateTime.parse(json['captured_at'] as String),
    status: InspectionStatus.parse(json['status'] as String),
    hasFaults: json['has_faults'] as bool,
    reviewComment: json['review_comment'] as String,
  );

  final String id;
  final DateTime capturedAt;
  final InspectionStatus status;
  final bool hasFaults;
  final String reviewComment;
}

/// Estado de un plan preventivo (contrato `FieldMaintenancePlan.state`).
enum PlanState {
  ok,
  dueSoon,
  overdue,
  unknown;

  static PlanState parse(String wire) => switch (wire) {
    'due_soon' => dueSoon,
    'overdue' => overdue,
    'unknown' => unknown,
    _ => ok,
  };
}

@immutable
class MaintenancePlanInfo {
  const MaintenancePlanInfo({
    required this.id,
    required this.name,
    required this.kind,
    required this.meterUnit,
    required this.state,
    required this.remaining,
    required this.dueValue,
    required this.dueOn,
    required this.hasOpenOrder,
  });

  factory MaintenancePlanInfo.fromJson(Map<String, dynamic> json) => MaintenancePlanInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    kind: json['kind'] as String,
    meterUnit: MeterUnit.tryParse(json['meter_unit'] as String?),
    state: PlanState.parse(json['state'] as String),
    remaining: (json['remaining'] as num?)?.toDouble(),
    dueValue: (json['due_value'] as num?)?.toDouble(),
    dueOn: json['due_on'] == null ? null : DateTime.parse(json['due_on'] as String),
    hasOpenOrder: json['has_open_order'] as bool,
  );

  final String id;
  final String name;

  /// `meter` o `date`.
  final String kind;
  final MeterUnit? meterUnit;
  final PlanState state;

  /// Horas/km o días que faltan; negativo = vencido.
  final double? remaining;
  final double? dueValue;
  final DateTime? dueOn;
  final bool hasOpenOrder;

  bool get byMeter => kind == 'meter';
}

@immutable
class WorkOrderSummary {
  const WorkOrderSummary({
    required this.id,
    required this.code,
    required this.kind,
    required this.status,
    required this.description,
  });

  factory WorkOrderSummary.fromJson(Map<String, dynamic> json) => WorkOrderSummary(
    id: json['id'] as String,
    code: json['code'] as String,
    kind: json['kind'] as String,
    status: json['status'] as String,
    description: json['description'] as String,
  );

  final String id;

  /// Número por organización, p. ej. `OT-0012`.
  final String code;

  /// `preventive`, `corrective` u `overhaul`.
  final String kind;

  /// `draft`, `approved` o `in_execution` (las abiertas).
  final String status;
  final String description;
}

@immutable
class UsageProjectInfo {
  const UsageProjectInfo({required this.id, required this.name});

  factory UsageProjectInfo.fromJson(Map<String, dynamic> json) =>
      UsageProjectInfo(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;
}

@immutable
class UsageSummary {
  const UsageSummary({
    required this.id,
    required this.usageDate,
    required this.startMinutes,
    required this.endMinutes,
    required this.hours,
    required this.activity,
    required this.projectName,
    required this.status,
  });

  factory UsageSummary.fromJson(Map<String, dynamic> json) => UsageSummary(
    id: json['id'] as String,
    usageDate: DateTime.parse(json['usage_date'] as String),
    startMinutes: minutesOf(json['start_time'] as String),
    endMinutes: minutesOf(json['end_time'] as String),
    hours: (json['hours'] as num?)?.toDouble(),
    activity: json['activity'] as String,
    projectName: json['project_name'] as String,
    status: json['status'] as String,
  );

  /// "08:30" → 510.
  static int minutesOf(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }

  final String id;
  final DateTime usageDate;
  final int startMinutes;
  final int endMinutes;
  final double? hours;
  final String activity;
  final String projectName;

  /// `scheduled`, `in_progress`, `completed` o `cancelled`.
  final String status;
}

@immutable
class FieldEquipment {
  const FieldEquipment({
    required this.raw,
    required this.id,
    required this.code,
    required this.name,
    required this.qrIdentifier,
    required this.typeName,
    required this.preoperationalTemplateId,
    required this.status,
    required this.ownership,
    required this.licensePlate,
    required this.manufacturer,
    required this.model,
    required this.serialNumber,
    required this.departmentLabel,
    required this.controlScheme,
    required this.workSource,
    required this.currentProjectId,
    required this.meters,
    required this.meterUnits,
    required this.documents,
    required this.fields,
    required this.alerts,
    required this.checklist,
    required this.recentInspections,
    required this.usageProjects,
    required this.recentUsage,
    required this.maintenancePlans,
    required this.openWorkOrders,
  });

  factory FieldEquipment.fromJson(Map<String, dynamic> json) {
    final type = json['equipment_type'] as Map<String, dynamic>;
    final department = json['department'] as Map<String, dynamic>?;
    List<T> list<T>(String key, T Function(Map<String, dynamic>) build) => [
      for (final item in json[key] as List<dynamic>) build(item as Map<String, dynamic>),
    ];
    return FieldEquipment(
      raw: json,
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      qrIdentifier: json['qr_identifier'] as String,
      typeName: type['name'] as String,
      preoperationalTemplateId: type['preoperational_template_id'] as String?,
      status: json['status'] as String,
      ownership: json['ownership'] as String,
      licensePlate: json['license_plate'] as String,
      manufacturer: json['manufacturer'] as String,
      model: json['model'] as String,
      serialNumber: json['serial_number'] as String,
      departmentLabel: department == null ? null : '${department['code']} · ${department['name']}',
      controlScheme: json['control_scheme'] as String,
      workSource: json['work_source'] as String,
      currentProjectId: json['current_project_id'] as String?,
      meters: list('meters', EquipmentMeter.fromJson),
      meterUnits: [for (final unit in json['meter_units'] as List<dynamic>) MeterUnit.values.byName(unit as String)],
      documents: list('documents', EquipmentDocumentInfo.fromJson),
      fields: list('fields', EquipmentFieldInfo.fromJson),
      alerts: list('alerts', EquipmentAlertInfo.fromJson),
      checklist: list('checklist', ChecklistItemInfo.fromJson),
      recentInspections: list('recent_inspections', InspectionSummary.fromJson),
      usageProjects: list('usage_projects', UsageProjectInfo.fromJson),
      recentUsage: list('recent_usage', UsageSummary.fromJson),
      maintenancePlans: list('maintenance_plans', MaintenancePlanInfo.fromJson),
      openWorkOrders: list('open_work_orders', WorkOrderSummary.fromJson),
    );
  }

  /// El JSON del servidor tal como llegó: es lo que se guarda en la caché.
  final Map<String, dynamic> raw;
  final String id;
  final String code;
  final String name;

  /// Contenido de su QR (`suno:eq:<uuid>`).
  final String qrIdentifier;
  final String typeName;
  final String? preoperationalTemplateId;
  final String status;
  final String ownership;
  final String licensePlate;
  final String manufacturer;
  final String model;
  final String serialNumber;
  final String? departmentLabel;
  final String controlScheme;
  final String workSource;
  final String? currentProjectId;
  final List<EquipmentMeter> meters;

  /// Medidores configurados en la ficha (principal primero).
  final List<MeterUnit> meterUnits;
  final List<EquipmentDocumentInfo> documents;
  final List<EquipmentFieldInfo> fields;
  final List<EquipmentAlertInfo> alerts;

  /// Lista de chequeo preoperacional vigente de la tipología.
  final List<ChecklistItemInfo> checklist;

  /// Mis últimas inspecciones sobre este equipo (más reciente primero).
  final List<InspectionSummary> recentInspections;

  /// Proyectos en los que quien llama puede reportar uso de este equipo hoy.
  final List<UsageProjectInfo> usageProjects;

  /// Mis últimos usos de este equipo (más reciente primero).
  final List<UsageSummary> recentUsage;

  /// Planes preventivos vigentes con lo que falta para cada uno.
  final List<MaintenancePlanInfo> maintenancePlans;

  /// Órdenes de trabajo abiertas (borrador, aprobada o en ejecución).
  final List<WorkOrderSummary> openWorkOrders;

  bool get needsMeterForInspection => controlScheme == 'meter' && meterUnits.isNotEmpty;

  EquipmentMeter? meter(MeterUnit unit) {
    for (final meter in meters) {
      if (meter.unit == unit) return meter;
    }
    return null;
  }

  bool get hasExpired => alerts.any((alert) => alert.expired);
}

/// Origen de un tanqueo (contrato `FuelFillIn.source`).
enum FuelSource {
  station,
  store;

  static FuelSource? tryParse(String? value) {
    for (final source in values) {
      if (source.name == value) return source;
    }
    return null;
  }
}

@immutable
class FuelStationInfo {
  const FuelStationInfo({required this.id, required this.name, required this.supplier});

  factory FuelStationInfo.fromJson(Map<String, dynamic> json) =>
      FuelStationInfo(id: json['id'] as String, name: json['name'] as String, supplier: json['supplier'] as String);

  final String id;
  final String name;
  final String supplier;
}

@immutable
class FuelStoreInfo {
  const FuelStoreInfo({required this.id, required this.name});

  factory FuelStoreInfo.fromJson(Map<String, dynamic> json) =>
      FuelStoreInfo(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;
}

@immutable
class FuelCatalogInfo {
  const FuelCatalogInfo({required this.stations, required this.stores});

  factory FuelCatalogInfo.fromJson(Map<String, dynamic> json) => FuelCatalogInfo(
    stations: [for (final item in json['stations'] as List<dynamic>) FuelStationInfo.fromJson(item as Map<String, dynamic>)],
    stores: [for (final item in json['stores'] as List<dynamic>) FuelStoreInfo.fromJson(item as Map<String, dynamic>)],
  );

  static const empty = FuelCatalogInfo(stations: [], stores: []);

  final List<FuelStationInfo> stations;
  final List<FuelStoreInfo> stores;

  Map<String, dynamic> toJson() => {
    'stations': [
      for (final s in stations) {'id': s.id, 'name': s.name, 'supplier': s.supplier},
    ],
    'stores': [
      for (final s in stores) {'id': s.id, 'name': s.name},
    ],
  };

  bool get isEmpty => stations.isEmpty && stores.isEmpty;
}

@immutable
class TransportRouteInfo {
  const TransportRouteInfo({
    required this.id,
    required this.origin,
    required this.destination,
    required this.zone,
    required this.distanceKm,
  });

  factory TransportRouteInfo.fromJson(Map<String, dynamic> json) => TransportRouteInfo(
    id: json['id'] as String,
    origin: json['origin'] as String,
    destination: json['destination'] as String,
    zone: json['zone'] as String,
    distanceKm: (json['distance_km'] as num).toDouble(),
  );

  final String id;
  final String origin;
  final String destination;
  final String zone;
  final double distanceKm;
}

@immutable
class TransportMaterialInfo {
  const TransportMaterialInfo({required this.id, required this.name});

  factory TransportMaterialInfo.fromJson(Map<String, dynamic> json) =>
      TransportMaterialInfo(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;
}

@immutable
class TransportVehicleInfo {
  const TransportVehicleInfo({
    required this.id,
    required this.plate,
    required this.contractor,
    required this.capacityM3,
  });

  factory TransportVehicleInfo.fromJson(Map<String, dynamic> json) => TransportVehicleInfo(
    id: json['id'] as String,
    plate: json['plate'] as String,
    contractor: json['contractor'] as String,
    capacityM3: (json['capacity_m3'] as num?)?.toDouble(),
  );

  final String id;
  final String plate;
  final String contractor;
  final double? capacityM3;
}

@immutable
class TransportPersonInfo {
  const TransportPersonInfo({required this.id, required this.name});

  factory TransportPersonInfo.fromJson(Map<String, dynamic> json) =>
      TransportPersonInfo(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;
}

@immutable
class TransportCatalogInfo {
  const TransportCatalogInfo({
    required this.routes,
    required this.materials,
    required this.vehicles,
    required this.people,
  });

  factory TransportCatalogInfo.fromJson(Map<String, dynamic> json) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) build) => [
      for (final item in json[key] as List<dynamic>) build(item as Map<String, dynamic>),
    ];
    return TransportCatalogInfo(
      routes: list('routes', TransportRouteInfo.fromJson),
      materials: list('materials', TransportMaterialInfo.fromJson),
      vehicles: list('vehicles', TransportVehicleInfo.fromJson),
      people: list('people', TransportPersonInfo.fromJson),
    );
  }

  static const empty = TransportCatalogInfo(routes: [], materials: [], vehicles: [], people: []);

  final List<TransportRouteInfo> routes;
  final List<TransportMaterialInfo> materials;
  final List<TransportVehicleInfo> vehicles;
  final List<TransportPersonInfo> people;

  Map<String, dynamic> toJson() => {
    'routes': [
      for (final r in routes)
        {'id': r.id, 'origin': r.origin, 'destination': r.destination, 'zone': r.zone, 'distance_km': r.distanceKm},
    ],
    'materials': [
      for (final m in materials) {'id': m.id, 'name': m.name},
    ],
    'vehicles': [
      for (final v in vehicles)
        {'id': v.id, 'plate': v.plate, 'contractor': v.contractor, 'capacity_m3': v.capacityM3},
    ],
    'people': [
      for (final p in people) {'id': p.id, 'name': p.name},
    ],
  };

  /// Sin tramos o sin materiales no se puede registrar un viaje.
  bool get canRegisterTrips => routes.isNotEmpty && materials.isNotEmpty;
}
