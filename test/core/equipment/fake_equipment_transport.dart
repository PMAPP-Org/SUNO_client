import 'dart:typed_data';

import 'package:suno/core/equipment/equipment_models.dart';
import 'package:suno/core/equipment/equipment_transport.dart';

/// Un equipo tal como lo entrega `GET /v1/equipment`.
Map<String, dynamic> equipmentJson({
  String id = '11111111-1111-4111-8111-111111111111',
  String code = 'EQ-1',
  String name = 'Volqueta 1',
  String plate = 'EXG871',
  String controlScheme = 'meter',
  List<String> meterUnits = const ['hours', 'kilometers'],
  List<Map<String, dynamic>> meters = const [],
  List<Map<String, dynamic>> alerts = const [],
  List<Map<String, dynamic>> documents = const [],
  List<Map<String, dynamic>> fields = const [],
  List<Map<String, dynamic>> checklist = const [],
  List<Map<String, dynamic>> recentInspections = const [],
  List<Map<String, dynamic>> maintenancePlans = const [],
  List<Map<String, dynamic>> openWorkOrders = const [],
  List<Map<String, dynamic>> usageProjects = const [],
  List<Map<String, dynamic>> recentUsage = const [],
}) => {
  'id': id,
  'code': code,
  'name': name,
  'qr_identifier': 'suno:eq:$id',
  'equipment_type': {
    'id': '22222222-2222-4222-8222-222222222222',
    'code': 'VOL',
    'name': 'Volqueta',
    'preoperational_template_id': null,
  },
  'status': 'available',
  'ownership': 'own',
  'license_plate': plate,
  'manufacturer': 'CAT',
  'model': '740',
  'serial_number': 'SN-1',
  'manufacture_year': 2020,
  'department': {'code': 'CC-1', 'name': 'Maquinaria Norte'},
  'control_scheme': controlScheme,
  'work_source': 'fuel',
  'current_project_id': null,
  'meters': meters,
  'meter_units': meterUnits,
  'documents': documents,
  'fields': fields,
  'alerts': alerts,
  'checklist': checklist,
  'recent_inspections': recentInspections,
  'usage_projects': usageProjects,
  'recent_usage': recentUsage,
  'maintenance_plans': maintenancePlans,
  'open_work_orders': openWorkOrders,
};

Map<String, dynamic> meterJson(String unit, double value) => {
  'unit': unit,
  'label': unit == 'hours' ? 'Horómetro' : 'Kilometraje',
  'is_primary': unit == 'hours',
  'value': value,
  'read_at': '2026-11-01T08:00:00Z',
};

Map<String, dynamic> checklistItemJson(String id, String label, {bool critical = false}) => {
  'id': id,
  'label': label,
  'critical': critical,
};

Map<String, dynamic> inspectionSummaryJson(
  String id, {
  String status = 'submitted',
  bool hasFaults = false,
  String comment = '',
}) => {
  'id': id,
  'captured_at': '2026-11-08T08:00:00Z',
  'status': status,
  'has_faults': hasFaults,
  'review_comment': comment,
};

Map<String, dynamic> planJson(
  String id,
  String name, {
  String state = 'ok',
  double? remaining,
  String unit = 'hours',
  bool hasOpenOrder = false,
}) => {
  'id': id,
  'name': name,
  'kind': 'meter',
  'meter_unit': unit,
  'state': state,
  'remaining': remaining,
  'due_value': 1030.0,
  'due_on': null,
  'has_open_order': hasOpenOrder,
};

Map<String, dynamic> orderJson(String id, String code, {String status = 'draft', String kind = 'preventive'}) => {
  'id': id,
  'code': code,
  'kind': kind,
  'status': status,
  'description': 'Cambio de aceite',
};

Map<String, dynamic> usageProjectJson(String id, String name) => {'id': id, 'name': name};

Map<String, dynamic> usageJson(
  String id, {
  String date = '2026-11-07',
  String start = '08:00',
  String end = '12:00',
  double? hours = 4,
  String activity = 'Excavación',
  String project = 'Norte',
  String status = 'completed',
}) => {
  'id': id,
  'usage_date': date,
  'start_time': start,
  'end_time': end,
  'hours': hours,
  'activity': activity,
  'project_name': project,
  'status': status,
};

FieldEquipment equipment([Map<String, dynamic>? json]) => FieldEquipment.fromJson(json ?? equipmentJson());

class FakeEquipmentTransport implements EquipmentTransport {
  /// Respuestas de `fetchList`, en orden; la última se repite.
  final List<EquipmentFetch> fetches = [];
  final List<String?> versionsAsked = [];
  ReadingSendResult sendResult = const ReadingSendResult(ReadingSendStatus.sent);
  ReadingSendResult inspectionResult = const ReadingSendResult(ReadingSendStatus.sent);
  final List<OutgoingMeterReading> sent = [];
  final List<OutgoingInspection> sentInspections = [];
  Uint8List? lifeSheet = Uint8List.fromList([0x25, 0x50, 0x44, 0x46]);
  final List<String> lifeSheetsAsked = [];
  final List<FuelCatalogFetch> catalogFetches = [];
  final List<String?> catalogVersionsAsked = [];
  ReadingSendResult fuelFillResult = const ReadingSendResult(ReadingSendStatus.sent);
  final List<OutgoingFuelFill> sentFuelFills = [];
  final List<TransportCatalogFetch> transportFetches = [];
  final List<String?> transportVersionsAsked = [];
  ReadingSendResult tripResult = const ReadingSendResult(ReadingSendStatus.sent);
  final List<OutgoingTrip> sentTrips = [];
  ReadingSendResult usageResult = const ReadingSendResult(ReadingSendStatus.sent);
  final List<OutgoingUsageReport> sentUsage = [];

  @override
  Future<EquipmentFetch> fetchList({String? version}) async {
    versionsAsked.add(version);
    if (fetches.isEmpty) return const EquipmentFetchFailed();
    return fetches.length > 1 ? fetches.removeAt(0) : fetches.first;
  }

  @override
  Future<ReadingSendResult> sendMeterReading(OutgoingMeterReading reading) async {
    sent.add(reading);
    return sendResult;
  }

  @override
  Future<FuelCatalogFetch> fetchFuelCatalog({String? version}) async {
    catalogVersionsAsked.add(version);
    if (catalogFetches.isEmpty) return const FuelCatalogFailed();
    return catalogFetches.length > 1 ? catalogFetches.removeAt(0) : catalogFetches.first;
  }

  @override
  Future<ReadingSendResult> sendFuelFill(OutgoingFuelFill fill) async {
    sentFuelFills.add(fill);
    return fuelFillResult;
  }

  @override
  Future<TransportCatalogFetch> fetchTransportCatalog({String? version}) async {
    transportVersionsAsked.add(version);
    if (transportFetches.isEmpty) return const TransportCatalogFailed();
    return transportFetches.length > 1 ? transportFetches.removeAt(0) : transportFetches.first;
  }

  @override
  Future<ReadingSendResult> sendTrip(OutgoingTrip trip) async {
    sentTrips.add(trip);
    return tripResult;
  }

  @override
  Future<ReadingSendResult> sendUsageReport(OutgoingUsageReport report) async {
    sentUsage.add(report);
    return usageResult;
  }

  @override
  Future<Uint8List?> fetchLifeSheet(String equipmentId) async {
    lifeSheetsAsked.add(equipmentId);
    return lifeSheet;
  }

  @override
  Future<ReadingSendResult> sendInspection(OutgoingInspection inspection) async {
    sentInspections.add(inspection);
    return inspectionResult;
  }
}
