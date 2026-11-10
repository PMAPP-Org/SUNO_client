// Cantidades ejecutadas en campo (costos, pieza 4b): las filas que el agente digita en
// un registro de una tarea medida por cantidades. Puro: sin Flutter ni BD; lo comparten
// la captura, la corrección de rechazos, el detalle y las exportaciones.
//
// Reglas (spec, sección 2.2): solo se guardan las filas con cantidad distinta de 0;
// hace falta al menos una; hasta 4 decimales y |cantidad| < 10^14; la nota es
// obligatoria si el ítem no está planeado o la cantidad es negativa (ajuste), y tiene
// hasta 500 caracteres; hasta 200 filas. La sobreejecución solo se avisa.
//
// Los datos automáticos (`client_id`, `captured_at`, `gps`, `seen`, `location_mode`)
// solo se generan en las filas creadas en el teléfono. Una fila que ya existía (guardada
// o bajada del servidor, quizá sin ellos) los reenvía tal como llegaron: el servidor
// compara la forma guardada de un registro validado y rechazaría (`record_validated`) un
// reenvío que les agregue algo.
import 'dart:convert';

import 'package:meta/meta.dart';

/// Filas de cantidad por registro (`MAX_QUANTITY_ROWS` del servidor).
const maxQuantityRows = 200;

/// Caracteres de la nota de una fila.
const maxQuantityNote = 500;

/// Claves de los datos automáticos de una fila (pieza 4b).
const _captureKeys = ['client_id', 'captured_at', 'gps', 'seen', 'location_mode'];

/// Hasta 14 dígitos enteros (|q| < 10^14) y 4 decimales, con coma o punto.
final _quantityPattern = RegExp(r'^-?\d{1,14}([.,]\d{1,4})?$');

/// La cantidad escrita, o `null` si no es un número válido.
double? parseQuantity(String text) {
  final value = text.trim();
  if (!_quantityPattern.hasMatch(value)) return null;
  return double.parse(value.replaceAll(',', '.'));
}

/// `10.0` → `10`; `2.5` → `2,5`; hasta 4 decimales.
String formatQuantity(double value) =>
    value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '').replaceAll('.', ',');

/// Un ítem del presupuesto tal como lo muestra la app.
@immutable
class QuantityItem {
  const QuantityItem({required this.itemId, required this.code, required this.description, required this.unit});

  /// Un ítem del que el teléfono no tiene datos (llegó en un registro de otro proyecto).
  const QuantityItem.unknown(this.itemId) : code = '', description = '', unit = '';

  final String itemId;
  final String code;
  final String description;
  final String unit;

  String get label => code.isEmpty ? itemId : '$code $description';
}

/// Un ítem planeado de la tarea, con lo planeado y lo validado a la fecha.
@immutable
class PlannedQuantity {
  const PlannedQuantity({required this.item, required this.planned, required this.validated});
  final QuantityItem item;
  final double planned;
  final double validated;
}

/// Una ubicación elegible para una fila: la de la tarea o una que la precisa.
@immutable
class LocationChoice {
  const LocationChoice({required this.id, required this.label, required this.isTaskLocation});
  final String id;
  final String label;
  final bool isTaskLocation;
}

/// Lo que la captura de cantidades sabe de una tarea.
@immutable
class QuantityTaskContext {
  const QuantityTaskContext({
    required this.taskId,
    this.planned = const [],
    this.locations = const [],
    this.catalog = const [],
  });

  final String taskId;
  final List<PlannedQuantity> planned;
  final List<LocationChoice> locations;

  /// Ítems medibles del presupuesto vigente del proyecto de la tarea.
  final List<QuantityItem> catalog;

  /// La ubicación de la tarea, o `null` si no tiene.
  LocationChoice? get taskLocation => locations.where((l) => l.isTaskLocation).firstOrNull;

  /// Las ubicaciones con que se puede precisar la de la tarea.
  List<LocationChoice> get refinements => [
    for (final l in locations)
      if (!l.isTaskLocation) l,
  ];

  PlannedQuantity? plannedFor(String itemId) => planned.where((p) => p.item.itemId == itemId).firstOrNull;

  QuantityItem? catalogItem(String itemId) => catalog.where((i) => i.itemId == itemId).firstOrNull;

  /// "Agregar ítem no planeado": el catálogo sin los ítems ya planeados.
  List<QuantityItem> get unplannedCatalog => [
    for (final item in catalog)
      if (plannedFor(item.itemId) == null) item,
  ];

  /// Los planeados y el catálogo, sin repetir (para reasignar una fila rechazada).
  List<QuantityItem> get allItems => [for (final p in planned) p.item, ...unplannedCatalog];
}

/// Contrato `QuantityGps`.
@immutable
class GpsReading {
  const GpsReading({required this.lat, required this.lon, required this.accuracyM});

  factory GpsReading.fromJson(Map<String, Object?> json) => GpsReading(
    lat: (json['lat']! as num).toDouble(),
    lon: (json['lon']! as num).toDouble(),
    accuracyM: (json['accuracy_m']! as num).toDouble(),
  );

  final double lat;
  final double lon;
  final double accuracyM;

  Map<String, Object?> toJson() => {'lat': lat, 'lon': lon, 'accuracy_m': accuracyM};
}

/// Contrato `QuantitySeen`: lo que la app mostraba al capturar la fila.
@immutable
class QuantitySeen {
  const QuantitySeen({required this.planned, required this.validated, required this.locationId});

  factory QuantitySeen.fromJson(Map<String, Object?> json) => QuantitySeen(
    planned: (json['planned'] as num?)?.toDouble(),
    validated: (json['validated'] as num?)?.toDouble(),
    locationId: json['location_id'] as String?,
  );

  final double? planned;
  final double? validated;

  /// La ubicación de la tarea que se mostraba; `null` si no tenía.
  final String? locationId;

  Map<String, Object?> toJson() => {'planned': planned, 'validated': validated, 'location_id': locationId};
}

const Object _keep = Object();

/// Una fila de cantidad mientras se captura o se corrige.
@immutable
class QuantityRowDraft {
  const QuantityRowDraft({
    required this.clientId,
    required this.item,
    this.planned,
    this.validated,
    this.isPlanned = false,
    this.text = '',
    this.note = '',
    this.locationId,
    this.capturedAt,
    this.gps,
    this.seen,
    this.added = false,
    this.storedCapture,
  });

  /// Una fila guardada (forma del contrato) vuelta a la pantalla. [planned] es el ítem
  /// planeado de la tarea, si lo es; una fila sin `client_id` (captura anterior a la
  /// pieza 4b, o bajada del servidor sin él) toma [fallbackId] solo para identificarla
  /// en pantalla: al reenviarla no lleva `client_id` (ver [storedCapture]).
  factory QuantityRowDraft.fromStored(
    Map<String, Object?> json, {
    required QuantityItem item,
    PlannedQuantity? planned,
    required String fallbackId,
    bool added = false,
  }) {
    final captured = json['captured_at'];
    final gps = json['gps'];
    final seen = json['seen'];
    return QuantityRowDraft(
      clientId: json['client_id'] as String? ?? fallbackId,
      item: item,
      planned: planned?.planned,
      validated: planned?.validated,
      isPlanned: planned != null,
      text: formatQuantity((json['quantity']! as num).toDouble()),
      note: json['note'] as String? ?? '',
      locationId: json['location_id'] as String?,
      capturedAt: captured is String ? DateTime.tryParse(captured) : null,
      gps: gps is Map ? GpsReading.fromJson(gps.cast<String, Object?>()) : null,
      seen: seen is Map ? QuantitySeen.fromJson(seen.cast<String, Object?>()) : null,
      added: added,
      storedCapture: {
        for (final key in _captureKeys)
          if (json[key] != null) key: json[key],
      },
    );
  }

  /// Identifica la fila; viaja como `client_id` solo en las filas creadas en el teléfono.
  final String clientId;
  final QuantityItem item;
  final double? planned;
  final double? validated;
  final bool isPlanned;

  /// Lo escrito en "Cantidad hoy".
  final String text;
  final String note;

  /// `null`: la ubicación de la tarea.
  final String? locationId;
  final DateTime? capturedAt;
  final GpsReading? gps;
  final QuantitySeen? seen;

  /// Fila agregada por el agente (ítem no planeado u otra fila de un ítem): se puede quitar.
  final bool added;

  /// Los datos automáticos con que llegó una fila que ya existía (`null` en una creada
  /// en esta pantalla): se reenvían tal cual, sin agregar ni recalcular ninguno.
  final Map<String, Object?>? storedCapture;

  /// La fila ya existía (guardada o del servidor): sus datos automáticos no cambian.
  bool get isStored => storedCapture != null;

  double? get quantity => parseQuantity(text);
  bool get hasQuantity => (quantity ?? 0) != 0;
  bool get isAdjustment => (quantity ?? 0) < 0;

  /// Ítem fuera del plan o ajuste negativo.
  bool get needsNote => !isPlanned || isAdjustment;
  String get locationMode => locationId == null ? 'task' : 'refined';

  QuantityRowDraft copyWith({
    QuantityItem? item,
    Object? planned = _keep,
    Object? validated = _keep,
    bool? isPlanned,
    String? text,
    String? note,
    Object? locationId = _keep,
    Object? capturedAt = _keep,
    Object? gps = _keep,
    Object? seen = _keep,
    bool? added,
  }) => QuantityRowDraft(
    clientId: clientId,
    item: item ?? this.item,
    planned: identical(planned, _keep) ? this.planned : planned as double?,
    validated: identical(validated, _keep) ? this.validated : validated as double?,
    isPlanned: isPlanned ?? this.isPlanned,
    text: text ?? this.text,
    note: note ?? this.note,
    locationId: identical(locationId, _keep) ? this.locationId : locationId as String?,
    capturedAt: identical(capturedAt, _keep) ? this.capturedAt : capturedAt as DateTime?,
    gps: identical(gps, _keep) ? this.gps : gps as GpsReading?,
    seen: identical(seen, _keep) ? this.seen : seen as QuantitySeen?,
    added: added ?? this.added,
    storedCapture: storedCapture,
  );

  /// Contrato `RecordQuantityPayload`.
  Map<String, Object?> toPayload() {
    final base = <String, Object?>{
      'item_id': item.itemId,
      'location_id': locationId,
      'quantity': quantity,
      'note': note.trim(),
    };
    final stored = storedCapture;
    if (stored != null) return {...base, ...stored};
    return {
      ...base,
      'client_id': clientId,
      'captured_at': capturedAt?.toUtc().toIso8601String(),
      'gps': gps?.toJson(),
      'seen': seen?.toJson(),
      'location_mode': locationMode,
    };
  }
}

enum QuantityRowProblem { invalidNumber, noteRequired, noteTooLong }

/// Resultado de validar las filas al guardar.
@immutable
class QuantityCheck {
  const QuantityCheck({this.rows = const {}, this.noQuantity = false, this.tooManyRows = false});

  /// Problema de cada fila, por `clientId`.
  final Map<String, QuantityRowProblem> rows;

  /// Ninguna fila tiene una cantidad distinta de 0.
  final bool noQuantity;
  final bool tooManyRows;

  bool get ok => rows.isEmpty && !noQuantity && !tooManyRows;
}

QuantityCheck checkQuantityRows(List<QuantityRowDraft> rows) {
  final problems = <String, QuantityRowProblem>{};
  var counted = 0;
  for (final row in rows) {
    if (row.text.trim().isEmpty) continue;
    final quantity = row.quantity;
    if (quantity == null) {
      problems[row.clientId] = QuantityRowProblem.invalidNumber;
      continue;
    }
    if (quantity == 0) continue;
    counted++;
    final note = row.note.trim();
    if (note.length > maxQuantityNote) {
      problems[row.clientId] = QuantityRowProblem.noteTooLong;
    } else if (row.needsNote && note.isEmpty) {
      problems[row.clientId] = QuantityRowProblem.noteRequired;
    }
  }
  return QuantityCheck(rows: problems, noQuantity: counted == 0, tooManyRows: counted > maxQuantityRows);
}

/// La suma de lo escrito hoy para [itemId] (las filas válidas).
double todayTotal(List<QuantityRowDraft> rows, String itemId) {
  var total = 0.0;
  for (final row in rows) {
    if (row.item.itemId == itemId) total += row.quantity ?? 0;
  }
  return total;
}

/// Ítems planeados cuyo validado más lo de hoy supera lo planeado. Solo se avisa.
Set<String> overrunItems(List<QuantityRowDraft> rows) => {
  for (final row in rows)
    if (row.isPlanned && row.planned != null && (row.validated ?? 0) + todayTotal(rows, row.item.itemId) > row.planned!)
      row.item.itemId,
};

/// Las filas que viajan: las que tienen una cantidad distinta de 0.
List<Map<String, Object?>> quantityPayload(List<QuantityRowDraft> rows) => [
  for (final row in rows)
    if (row.hasQuantity) row.toPayload(),
];

/// `Records.quantitiesJson` como lista; `[]` si no se entiende.
List<Map<String, Object?>> decodeQuantities(String json) {
  final decoded = jsonDecode(json);
  return decoded is List
      ? [
          for (final row in decoded)
            if (row is Map) row.cast<String, Object?>(),
        ]
      : const [];
}

/// ¿Las dos listas registran lo mismo? Compara ítem, ubicación, cantidad y nota (los
/// datos automáticos y la forma del pull no cuentan).
bool sameQuantities(List<Map<String, Object?>> a, List<Map<String, Object?>> b) {
  List<Object?> key(Map<String, Object?> row) => [
    row['item_id'],
    row['location_id'],
    (row['quantity'] as num?)?.toDouble(),
    (row['note'] as String? ?? '').trim(),
  ];
  return jsonEncode([for (final row in a) key(row)]) == jsonEncode([for (final row in b) key(row)]);
}

/// Una fila guardada, para mostrar o exportar.
@immutable
class QuantityLine {
  const QuantityLine({
    required this.itemId,
    required this.code,
    required this.description,
    required this.unit,
    required this.locationId,
    required this.locationLabel,
    required this.quantity,
    required this.note,
  });

  factory QuantityLine.fromStored(Map<String, Object?> json, {QuantityItem? item, String? locationLabel}) {
    final itemId = json['item_id']! as String;
    final known = item ?? QuantityItem.unknown(itemId);
    return QuantityLine(
      itemId: itemId,
      code: known.code,
      description: known.description,
      unit: known.unit,
      locationId: json['location_id'] as String?,
      locationLabel: locationLabel,
      quantity: (json['quantity']! as num).toDouble(),
      note: json['note'] as String? ?? '',
    );
  }

  final String itemId;
  final String code;
  final String description;
  final String unit;

  /// `null`: la ubicación de la tarea.
  final String? locationId;

  /// Etiqueta de [locationId] si el teléfono la conoce.
  final String? locationLabel;
  final double quantity;
  final String note;

  String get label => code.isEmpty ? itemId : '$code $description';
}
