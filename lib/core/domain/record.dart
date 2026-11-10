// Modelo de ejemplo del Paso 10: valida que el pipeline de codegen (freezed +
// json_serializable) funciona antes de construir el dominio real en el
// Paso 12. Espejo mínimo de `RecordData` (contrato `server/openapi/v1.yaml`,
// server/suno/sync/schemas.py::RecordData) — solo los campos que
// bastan para probar el codegen, no el modelo completo del Paso 12.
import 'package:freezed_annotation/freezed_annotation.dart';

part 'record.freezed.dart';
part 'record.g.dart';

@freezed
abstract class Record with _$Record {
  const factory Record({
    required String id,
    required String orgId,
    required int version,
    required int changeSeq,
    DateTime? deletedAt,
    required String templateVersionId,
    required Map<String, dynamic> answers,
    double? lat,
    double? lon,
    double? accuracyM,
    double? altitudeM,
    required DateTime capturedAt,
    required String deviceId,
    required String createdBy,
  }) = _Record;

  factory Record.fromJson(Map<String, dynamic> json) => _$RecordFromJson(json);
}
