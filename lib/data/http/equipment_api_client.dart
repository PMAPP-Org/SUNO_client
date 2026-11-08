// `EquipmentApiClient`: implementación Dio de `EquipmentTransport`. Lista con
// `?version=` (el servidor contesta "sin cambios") y lecturas de medidor
// idempotentes por `id`. Con el bearer del agente, como el resto de clientes.
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/equipment/equipment_models.dart';
import '../../core/equipment/equipment_transport.dart';

class EquipmentApiClient implements EquipmentTransport {
  EquipmentApiClient({required this.dio, required this.accessTokenProvider});

  final Dio dio;
  final String Function() accessTokenProvider;

  Options get _auth => Options(
    headers: {'Authorization': 'Bearer ${accessTokenProvider()}'},
    // Los 4xx los interpretamos nosotros; solo la falta de red lanza.
    validateStatus: (status) => status != null && status < 500,
  );

  @override
  Future<EquipmentFetch> fetchList({String? version}) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        '/v1/equipment',
        queryParameters: {'version': ?version},
        options: _auth,
      );
      final body = response.data;
      if (response.statusCode != 200 || body == null) return const EquipmentFetchFailed();
      if (body['changed'] == false) return const EquipmentUnchanged();
      return EquipmentFetched(
        version: body['version'] as String,
        items: [
          for (final item in body['items'] as List<dynamic>) FieldEquipment.fromJson(item as Map<String, dynamic>),
        ],
      );
    } on DioException {
      return const EquipmentFetchFailed();
    } on TypeError {
      return const EquipmentFetchFailed();
    } on FormatException {
      return const EquipmentFetchFailed();
    }
  }

  @override
  Future<ReadingSendResult> sendMeterReading(OutgoingMeterReading reading) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/v1/equipment/${Uri.encodeComponent(reading.equipmentId)}/meter-readings',
        data: {
          'id': reading.id,
          'meter_unit': reading.meterUnit.name,
          'value': reading.value,
          'read_at': reading.readAt.toUtc().toIso8601String(),
          'notes': reading.notes,
        },
        options: _auth,
      );
      return _result(response);
    } on DioException catch (error) {
      return ReadingSendResult(ReadingSendStatus.retry, message: error.type.name);
    }
  }

  @override
  Future<ReadingSendResult> sendInspection(OutgoingInspection inspection) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/v1/equipment/${Uri.encodeComponent(inspection.equipmentId)}/inspections',
        data: {
          'id': inspection.id,
          'captured_at': inspection.capturedAt.toUtc().toIso8601String(),
          'meter_unit': inspection.meterUnit?.name,
          'meter_value': inspection.meterValue,
          'items': [
            for (final item in inspection.items) {'item_id': item.itemId, 'ok': item.ok, 'note': item.note},
          ],
          'notes': inspection.notes,
        },
        options: _auth,
      );
      return _result(response);
    } on DioException catch (error) {
      return ReadingSendResult(ReadingSendStatus.retry, message: error.type.name);
    }
  }

  @override
  Future<Uint8List?> fetchLifeSheet(String equipmentId) async {
    try {
      final response = await dio.get<List<int>>(
        '/v1/equipment/${Uri.encodeComponent(equipmentId)}/life-sheet',
        options: Options(
          headers: {'Authorization': 'Bearer ${accessTokenProvider()}'},
          responseType: ResponseType.bytes,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final data = response.data;
      if (response.statusCode != 200 || data == null || data.isEmpty) return null;
      return Uint8List.fromList(data);
    } on DioException {
      return null;
    }
  }

  @override
  Future<FuelCatalogFetch> fetchFuelCatalog({String? version}) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        '/v1/fuel/catalog',
        queryParameters: {'version': ?version},
        options: _auth,
      );
      final body = response.data;
      if (response.statusCode != 200 || body == null) return const FuelCatalogFailed();
      if (body['changed'] == false) return const FuelCatalogUnchanged();
      return FuelCatalogFetched(version: body['version'] as String, catalog: FuelCatalogInfo.fromJson(body));
    } on DioException {
      return const FuelCatalogFailed();
    } on TypeError {
      return const FuelCatalogFailed();
    }
  }

  @override
  Future<ReadingSendResult> sendFuelFill(OutgoingFuelFill fill) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/v1/equipment/${Uri.encodeComponent(fill.equipmentId)}/fuel-fills',
        data: {
          'id': fill.id,
          'source': fill.source.name,
          'station_id': fill.stationId,
          'store_id': fill.storeId,
          'fuel_type': fill.fuelType,
          'voucher_number': fill.voucherNumber,
          'filled_at': fill.filledAt.toUtc().toIso8601String(),
          'gallons': fill.gallons,
          'meter_unit': fill.meterUnit?.name,
          'meter_value': fill.meterValue,
          'work_front': fill.workFront,
          'driver_name': fill.driverName,
          'driver_document': fill.driverDocument,
          'notes': fill.notes,
        },
        options: _auth,
      );
      return _result(response);
    } on DioException catch (error) {
      return ReadingSendResult(ReadingSendStatus.retry, message: error.type.name);
    }
  }

  @override
  Future<TransportCatalogFetch> fetchTransportCatalog({String? version}) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        '/v1/transport/catalog',
        queryParameters: {'version': ?version},
        options: _auth,
      );
      final body = response.data;
      if (response.statusCode != 200 || body == null) return const TransportCatalogFailed();
      if (body['changed'] == false) return const TransportCatalogUnchanged();
      return TransportCatalogFetched(version: body['version'] as String, catalog: TransportCatalogInfo.fromJson(body));
    } on DioException {
      return const TransportCatalogFailed();
    } on TypeError {
      return const TransportCatalogFailed();
    }
  }

  @override
  Future<ReadingSendResult> sendTrip(OutgoingTrip trip) async {
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/v1/transport/trips',
        data: {
          'id': trip.id,
          'recorded_at': trip.recordedAt.toUtc().toIso8601String(),
          'route_id': trip.routeId,
          'material_id': trip.materialId,
          'volume_m3': trip.volumeM3,
          'equipment_id': trip.equipmentId,
          'vehicle_id': trip.vehicleId,
          'requested_by_id': trip.requestedBy,
          'dispatched_by_id': trip.dispatchedBy,
          'received_by_id': trip.receivedBy,
          'driver_name': trip.driverName,
          'driver_document': trip.driverDocument,
          'notes': trip.notes,
        },
        options: _auth,
      );
      return _result(response);
    } on DioException catch (error) {
      return ReadingSendResult(ReadingSendStatus.retry, message: error.type.name);
    }
  }

  @override
  Future<ReadingSendResult> sendUsageReport(OutgoingUsageReport report) async {
    String hhmm(int minutes) =>
        '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}:00';
    try {
      final response = await dio.post<Map<String, dynamic>>(
        '/v1/equipment/${Uri.encodeComponent(report.equipmentId)}/usage-reports',
        data: {
          'id': report.id,
          'project_id': report.projectId,
          'usage_date': report.usageDate,
          'start_time': hhmm(report.startMinutes),
          'end_time': hhmm(report.endMinutes),
          'activity': report.activity,
          'location': report.location,
          'start_meter': report.startMeter,
          'end_meter': report.endMeter,
          'notes': report.notes,
        },
        options: _auth,
      );
      return _result(response);
    } on DioException catch (error) {
      return ReadingSendResult(ReadingSendStatus.retry, message: error.type.name);
    }
  }

  ReadingSendResult _result(Response<Map<String, dynamic>> response) {
    final status = response.statusCode ?? 0;
    if (status == 200) return const ReadingSendResult(ReadingSendStatus.sent);
    if (status == 403 || status == 404 || status == 422) {
      return ReadingSendResult(ReadingSendStatus.rejected, message: response.data?['message'] as String?);
    }
    // 401 (el interceptor ya intentó renovar), 408/429…: reintentar luego.
    return ReadingSendResult(ReadingSendStatus.retry, message: 'HTTP $status');
  }
}
