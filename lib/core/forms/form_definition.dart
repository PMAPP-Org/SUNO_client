// Definición de plantilla de formulario en el cliente (Paso 21, tareas 1-2):
// espejo de `server/visitacampo/forms/definition.py` (Paso 20).
//
// `parseFormDefinition` aplica **el mismo meta-schema** que el servidor al
// publicar: catálogo cerrado de tipos de campo, claves sin extra
// (`extra="forbid"`), etiquetas i18n acotadas, rangos coherentes, visibilidad
// solo hacia atrás y operadores aplicables al tipo referenciado. El servidor
// ya validó la plantilla al publicarla; el cliente la valida otra vez porque
// lo que lee viene de la red y del disco, y un dato que no cumple **no se
// interpreta a medias**: se rechaza entero (RD-02/RD-03) y la caché lo trata
// como corrupto (`FormTemplateRepository`).
//
// El cliente es **más estricto** que Pydantic en un punto, a propósito: no
// convierte tipos (`"true"` no es `true`, `3.0` no es un entero). El servidor
// guarda la definición ya normalizada (`model_dump(mode="json")`), así que una
// plantilla publicada siempre cumple también esta versión estricta.
//
// Un tipo de campo nuevo se añade aquí, en el servidor y en el catálogo de
// widgets (`lib/ui/forms/field_widgets.dart`): **en el binario**, nunca
// descrito por la propia plantilla (ADR-012).
import 'package:meta/meta.dart';

import 'visibility.dart';

/// Dialecto que habla este cliente (`definition.DSL_VERSION` del servidor).
const dslVersion = 'visitacampo/form@1';
const supportedDslVersions = {dslVersion};

const maxFields = 300;
const maxOptions = 200;
const maxJsonDepth = 24;
const maxTextLength = 4096;

/// Rangos de coordenadas (ADR-005; `core/models` del servidor).
const latMin = -90.0, latMax = 90.0, lonMin = -180.0, lonMax = 180.0;

final _langCode = RegExp(r'^[a-z]{2}(-[A-Z]{2})?$');
final _optionValue = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}$');
final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _uuid = RegExp(r'^[0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12}$');

/// Hora con offset explícito al final de un datetime RFC 3339 (`…T10:00Z`,
/// `…T10:00:00+05:00`). Exige la parte de hora: en `2026-01-01` el `-01`
/// final no es un offset.
final _explicitOffset = RegExp(r'[Tt ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|z|[+-]\d{2}(:?\d{2})?)$');

/// Texto i18n: `{"es": "...", "en": "..."}`, en el orden declarado.
@immutable
class I18nText {
  const I18nText(this.values);
  final Map<String, String> values;

  /// El texto para [locale] (`es-CO`): primero la etiqueta exacta, luego el
  /// idioma (`es`) y, si no está, el primero que declara la plantilla.
  String resolve(String locale) {
    final exact = values[locale];
    if (exact != null) return exact;
    final language = locale.split(RegExp('[-_]')).first;
    return values[language] ?? values.values.first;
  }
}

@immutable
class ChoiceOption {
  const ChoiceOption(this.value, this.label);
  final String value;
  final I18nText label;
}

/// Un campo del formulario. `checkAnswer` devuelve `null` si el valor es
/// aceptable, o el mismo `reason` estable que el servidor (`check_answer`).
@immutable
sealed class FormFieldDef {
  const FormFieldDef({
    required this.key,
    required this.label,
    required this.help,
    required this.required,
    required this.visibleIf,
    this.defaultValue,
  });

  final String key;
  final I18nText label;
  final I18nText? help;
  final bool required;
  final VisibilityExpr? visibleIf;
  final Object? defaultValue;

  /// El `type` del contrato (`text`, `number`, …).
  String get type;

  String? checkAnswer(Object? value);
}

final class TextFieldDef extends FormFieldDef {
  const TextFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
    required this.multiline,
    required this.minLength,
    required this.maxLength,
  });
  final bool multiline;
  final int? minLength;
  final int? maxLength;

  @override
  String get type => 'text';

  @override
  String? checkAnswer(Object? value) {
    if (value is! String) return 'not_a_string';
    // `len()` de Python cuenta puntos de código, no unidades UTF-16.
    final length = value.runes.length;
    if (length > maxTextLength) return 'too_long';
    if (minLength != null && length < minLength!) return 'too_short';
    if (maxLength != null && length > maxLength!) return 'too_long';
    return null;
  }
}

final class QrFieldDef extends FormFieldDef {
  const QrFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
    this.minLength,
    this.maxLength,
  });
  final int? minLength;
  final int? maxLength;
  @override
  String get type => 'qr';
  @override
  String? checkAnswer(Object? value) => TextFieldDef(
    key: key,
    label: label,
    help: help,
    required: this.required,
    visibleIf: visibleIf,
    multiline: false,
    minLength: minLength,
    maxLength: maxLength,
  ).checkAnswer(value);
}

final class RepeatFieldDef extends FormFieldDef {
  const RepeatFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
    required this.definition,
    required this.minRows,
    required this.maxRows,
  });
  final FormDefinition definition;
  final int minRows;
  final int maxRows;
  @override
  String get type => 'repeat';
  @override
  String? checkAnswer(Object? value) {
    if (value is! List<Object?>) return 'not_a_list';
    if (value.length < minRows) return 'too_few_rows';
    if (value.length > maxRows) return 'too_many_rows';
    if (value.any((row) => row is! Map<String, Object?>)) return 'not_an_object';
    return null;
  }
}

final class NumberFieldDef extends FormFieldDef {
  const NumberFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
    required this.min,
    required this.max,
  });
  final double? min;
  final double? max;

  @override
  String get type => 'number';

  @override
  String? checkAnswer(Object? value) {
    if (value is! num) return 'not_a_number';
    if (!value.isFinite) return 'not_finite';
    if ((min != null && value < min!) || (max != null && value > max!)) return 'out_of_range';
    return null;
  }
}

final class IntegerFieldDef extends FormFieldDef {
  const IntegerFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
    required this.min,
    required this.max,
  });
  final int? min;
  final int? max;

  @override
  String get type => 'integer';

  @override
  String? checkAnswer(Object? value) {
    if (value is! int) return 'not_an_integer';
    if ((min != null && value < min!) || (max != null && value > max!)) return 'out_of_range';
    return null;
  }
}

final class BooleanFieldDef extends FormFieldDef {
  const BooleanFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
  });

  @override
  String get type => 'boolean';

  @override
  String? checkAnswer(Object? value) => value is bool ? null : 'not_a_boolean';
}

final class DateFieldDef extends FormFieldDef {
  const DateFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
  });

  @override
  String get type => 'date';

  @override
  String? checkAnswer(Object? value) {
    if (value is! String) return 'not_a_string';
    return isValidIsoDate(value) ? null : 'not_a_date';
  }
}

final class DateTimeFieldDef extends FormFieldDef {
  const DateTimeFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
  });

  @override
  String get type => 'datetime';

  @override
  String? checkAnswer(Object? value) {
    if (value is! String) return 'not_a_string';
    if (DateTime.tryParse(value) == null) return 'not_a_datetime';
    return _explicitOffset.hasMatch(value) ? null : 'naive_datetime';
  }
}

sealed class ChoiceFieldDef extends FormFieldDef {
  const ChoiceFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
    required this.options,
  });
  final List<ChoiceOption> options;

  bool hasOption(Object? value) => options.any((option) => option.value == value);
}

final class SingleChoiceFieldDef extends ChoiceFieldDef {
  const SingleChoiceFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
    required super.options,
  });

  @override
  String get type => 'single_choice';

  @override
  String? checkAnswer(Object? value) {
    if (value is! String) return 'not_a_string';
    return hasOption(value) ? null : 'not_an_option';
  }
}

final class MultiChoiceFieldDef extends ChoiceFieldDef {
  const MultiChoiceFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
    required super.options,
    required this.minSelected,
    required this.maxSelected,
  });
  final int? minSelected;
  final int? maxSelected;

  @override
  String get type => 'multi_choice';

  @override
  String? checkAnswer(Object? value) {
    if (value is! List<Object?>) return 'not_a_list';
    if (value.length > maxOptions) return 'too_many_selected';
    for (final item in value) {
      if (item is! String) return 'not_a_string';
      if (!hasOption(item)) return 'not_an_option';
    }
    if (value.toSet().length != value.length) return 'duplicate_selection';
    if (minSelected != null && value.length < minSelected!) return 'too_few_selected';
    if (maxSelected != null && value.length > maxSelected!) return 'too_many_selected';
    return null;
  }
}

/// Campo cuya respuesta es el `id` (UUID) de un `visit_attachment`: el
/// binario viaja por su propio camino (ADR-007), nunca dentro de `answers`.
sealed class AttachmentRefFieldDef extends FormFieldDef {
  const AttachmentRefFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
  });

  @override
  String? checkAnswer(Object? value) {
    if (value is! String) return 'not_a_string';
    return _uuid.hasMatch(value) ? null : 'not_a_uuid';
  }
}

final class PhotoFieldDef extends AttachmentRefFieldDef {
  const PhotoFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
  });

  @override
  String get type => 'photo';
}

final class SignatureFieldDef extends AttachmentRefFieldDef {
  const SignatureFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
  });

  @override
  String get type => 'signature';
}

final class LocationFieldDef extends FormFieldDef {
  const LocationFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
  });

  @override
  String get type => 'location';

  @override
  String? checkAnswer(Object? value) {
    if (value is! Map<String, Object?>) return 'not_an_object';
    if (value.length != 2 || !value.containsKey('lat') || !value.containsKey('lon')) {
      return 'not_a_location';
    }
    for (final (key, low, high) in [('lat', latMin, latMax), ('lon', lonMin, lonMax)]) {
      final coordinate = value[key];
      if (coordinate is! num) return 'not_a_number';
      if (!coordinate.isFinite || coordinate < low || coordinate > high) return 'out_of_range';
    }
    return null;
  }
}

/// Vértices máximos de una línea o un polígono (mismo tope que el servidor).
const maxVertices = 2000;

String? _checkPositions(Object? positions, {required int minimum}) {
  if (positions is! List<Object?>) return 'not_a_geometry';
  if (positions.length < minimum) return 'too_few_vertices';
  if (positions.length > maxVertices) return 'too_many_vertices';
  for (final position in positions) {
    if (position is! List<Object?> || position.length != 2) return 'not_a_geometry';
    for (final (coordinate, low, high) in [(position[0], lonMin, lonMax), (position[1], latMin, latMax)]) {
      if (coordinate is! num) return 'not_a_number';
      if (!coordinate.isFinite || coordinate < low || coordinate > high) return 'out_of_range';
    }
  }
  return null;
}

/// Fase C: recorrido o lindero abierto. GeoJSON `LineString` en WGS84,
/// `{"type": "LineString", "coordinates": [[lon, lat], ...]}`, 2+ vértices.
final class LineFieldDef extends FormFieldDef {
  const LineFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
  });

  @override
  String get type => 'line';

  @override
  String? checkAnswer(Object? value) {
    if (value is! Map<String, Object?>) return 'not_an_object';
    if (value.length != 2 || value['type'] != 'LineString' || !value.containsKey('coordinates')) {
      return 'not_a_geometry';
    }
    return _checkPositions(value['coordinates'], minimum: 2);
  }
}

/// Fase C: un área. GeoJSON `Polygon` en WGS84 con un anillo exterior
/// cerrado (el último vértice repite el primero), 3+ vértices distintos.
final class PolygonFieldDef extends FormFieldDef {
  const PolygonFieldDef({
    required super.key,
    required super.label,
    required super.help,
    required super.required,
    required super.visibleIf,
    super.defaultValue,
  });

  @override
  String get type => 'polygon';

  @override
  String? checkAnswer(Object? value) {
    if (value is! Map<String, Object?>) return 'not_an_object';
    if (value.length != 2 || value['type'] != 'Polygon' || !value.containsKey('coordinates')) {
      return 'not_a_geometry';
    }
    final rings = value['coordinates'];
    if (rings is! List<Object?> || rings.length != 1) return 'not_a_geometry';
    final ring = rings.single;
    final problem = _checkPositions(ring, minimum: 4);
    if (problem != null) return problem;
    final positions = ring! as List<Object?>;
    final first = positions.first! as List<Object?>;
    final last = positions.last! as List<Object?>;
    if (first[0] != last[0] || first[1] != last[1]) return 'not_closed';
    return null;
  }
}

/// Una plantilla bien formada.
@immutable
class FormDefinition {
  const FormDefinition({required this.dsl, required this.title, required this.fields});
  final String dsl;
  final I18nText? title;
  final List<FormFieldDef> fields;
}

/// Resultado de [parseFormDefinition]: nunca una excepción.
@immutable
sealed class DefinitionResult {
  const DefinitionResult();
}

final class DefinitionOk extends DefinitionResult {
  const DefinitionOk(this.definition);
  final FormDefinition definition;
}

/// La plantilla no cumple el meta-schema. [unsupportedDialect]: está bien
/// formada para **otro** dialecto (`@2`): la app necesita actualizarse, el
/// dato no está corrupto.
final class DefinitionInvalid extends DefinitionResult {
  const DefinitionInvalid(this.path, this.reason, {this.unsupportedDialect = false});
  final String path;
  final String reason;
  final bool unsupportedDialect;
}

bool isValidIsoDate(String value) {
  if (!_isoDate.hasMatch(value)) return false;
  final parsed = DateTime.tryParse(value);
  // `DateTime.parse('2026-02-30')` "normaliza" al 2 de marzo: se rechaza.
  return parsed != null && parsed.toIso8601String().startsWith(value);
}

/// Rechaza un JSON más anidado que [limit], **sin recursión**.
void checkJsonDepth(Object? value, {int limit = maxJsonDepth}) {
  final stack = <(Object?, int)>[(value, 1)];
  while (stack.isNotEmpty) {
    final (item, depth) = stack.removeLast();
    if (depth > limit) throw const InvalidDefinition('definition', 'too_deep');
    if (item is Map) {
      stack.addAll(item.values.map((nested) => (nested, depth + 1)));
    } else if (item is List) {
      stack.addAll(item.map((nested) => (nested, depth + 1)));
    }
  }
}

/// Valida [raw] contra el meta-schema. Nunca lanza.
DefinitionResult parseFormDefinition(Object? raw) {
  try {
    checkJsonDepth(raw);
    final definition = _parseDefinition(raw);
    var count = 0;
    var expanded = 0;
    final stack = <(List<FormFieldDef>, int, int)>[(definition.fields, 0, 1)];
    while (stack.isNotEmpty) {
      final (fields, depth, multiplier) = stack.removeLast();
      if (depth > 3) throw const InvalidDefinition('fields', 'repeat_too_deep');
      for (final field in fields) {
        if (++count > maxFields) throw const InvalidDefinition('fields', 'too_many_fields');
        expanded += multiplier;
        if (expanded > 10000) throw const InvalidDefinition('fields', 'repeat_capacity');
        if (field is RepeatFieldDef) stack.add((field.definition.fields, depth + 1, multiplier * field.maxRows));
      }
    }
    return DefinitionOk(definition);
  } on InvalidDefinition catch (error) {
    return DefinitionInvalid(error.path, error.reason, unsupportedDialect: error.reason == 'unsupported_dialect');
  }
}

// --- Implementación --------------------------------------------------------

const _commonKeys = {'key', 'type', 'label', 'help', 'required', 'visible_if', 'default'};

const _typeKeys = <String, Set<String>>{
  'text': {'multiline', 'min_length', 'max_length'},
  'qr': {'multiline', 'min_length', 'max_length'},
  'repeat': {'fields', 'min_rows', 'max_rows'},
  'number': {'min', 'max'},
  'integer': {'min', 'max'},
  'boolean': {},
  'date': {},
  'datetime': {},
  'single_choice': {'options'},
  'multi_choice': {'options', 'min_selected', 'max_selected'},
  'photo': {},
  'signature': {},
  'location': {},
  'line': {},
  'polygon': {},
};

/// Tipos del catálogo cerrado.
final fieldTypes = _typeKeys.keys.toSet();

const _equalityTypes = {'text', 'qr', 'number', 'integer', 'boolean', 'date', 'datetime', 'single_choice'};
const _orderTypes = {'number', 'integer', 'date', 'datetime'};

/// La profundidad JSON ya la comprobó [parseFormDefinition], una sola vez.
FormDefinition _parseDefinition(Object? raw) {
  if (raw is! Map<String, Object?>) throw const InvalidDefinition('definition', 'not_an_object');
  for (final key in raw.keys) {
    if (!const {'dsl', 'title', 'fields'}.contains(key)) throw InvalidDefinition(key, 'extra_forbidden');
  }

  final dsl = raw['dsl'] ?? dslVersion;
  if (dsl is! String) throw const InvalidDefinition('dsl', 'not_a_string');
  if (!supportedDslVersions.contains(dsl)) throw const InvalidDefinition('dsl', 'unsupported_dialect');

  final title = raw['title'] == null ? null : _i18n(raw['title'], 'title');
  return FormDefinition(dsl: dsl, title: title, fields: _parseFields(raw['fields'], 'fields'));
}

/// Una lista de campos en [path] (`fields`, o `fields.3.fields` dentro de un
/// grupo), para que los errores señalen el campo real.
List<FormFieldDef> _parseFields(Object? rawFields, String path) {
  if (rawFields is! List<Object?>) throw InvalidDefinition(path, 'not_a_list');
  if (rawFields.length > maxFields) throw InvalidDefinition(path, 'too_many_fields');

  final declared = <String, FormFieldDef>{};
  for (final (index, rawField) in rawFields.indexed) {
    final field = _parseField(rawField, '$path.$index');
    if (declared.containsKey(field.key)) throw InvalidDefinition('$path.$index.key', 'duplicate_key');
    if (field.visibleIf != null) _checkVisibility(field.visibleIf!, declared, '$path.$index.visible_if');
    declared[field.key] = field;
  }
  return List.unmodifiable(declared.values);
}

FormFieldDef _parseField(Object? raw, String path) {
  final field = _parseFieldShape(raw, path);
  if (field.defaultValue != null &&
      (field is AttachmentRefFieldDef || field is RepeatFieldDef || field.checkAnswer(field.defaultValue) != null)) {
    throw InvalidDefinition('$path.default', 'invalid_default');
  }
  return field;
}

FormFieldDef _parseFieldShape(Object? raw, String path) {
  if (raw is! Map<String, Object?>) throw InvalidDefinition(path, 'not_an_object');
  final type = raw['type'];
  final extraKeys = _typeKeys[type];
  if (type is! String || extraKeys == null) throw InvalidDefinition('$path.type', 'unknown_field_type');
  for (final key in raw.keys) {
    if (!_commonKeys.contains(key) && !extraKeys.contains(key)) {
      throw InvalidDefinition('$path.$key', 'extra_forbidden');
    }
  }

  final key = raw['key'];
  if (key is! String || !fieldKeyPattern.hasMatch(key)) throw InvalidDefinition('$path.key', 'invalid_field_key');
  final label = _i18n(raw['label'], '$path.label');
  final help = raw['help'] == null ? null : _i18n(raw['help'], '$path.help');
  final required = _bool(raw, 'required', path) ?? false;
  final visibleIf = raw['visible_if'] == null ? null : parseVisibility(raw['visible_if'], '$path.visible_if');

  switch (type) {
    case 'qr':
      final minLength = _int(raw, 'min_length', path, min: 0, max: maxTextLength);
      final maxLength = _int(raw, 'max_length', path, min: 1, max: maxTextLength);
      if (minLength != null && maxLength != null && minLength > maxLength) {
        throw InvalidDefinition('$path.min_length', 'min_greater_than_max');
      }
      _bool(raw, 'multiline', path);
      return QrFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
        minLength: minLength,
        maxLength: maxLength,
      );
    case 'repeat':
      final minRows = _int(raw, 'min_rows', path, min: 0, max: 100) ?? 0;
      final maxRows = _int(raw, 'max_rows', path, min: 1, max: 100) ?? 100;
      if (minRows > maxRows) throw InvalidDefinition('$path.min_rows', 'min_greater_than_max');
      final children = FormDefinition(dsl: dslVersion, title: null, fields: _parseFields(raw['fields'], '$path.fields'));
      if (children.fields.isEmpty) throw InvalidDefinition('$path.fields', 'empty_group');
      return RepeatFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
        definition: children,
        minRows: minRows,
        maxRows: maxRows,
      );

    case 'text':
      final minLength = _int(raw, 'min_length', path, min: 0, max: maxTextLength);
      final maxLength = _int(raw, 'max_length', path, min: 1, max: maxTextLength);
      if (minLength != null && maxLength != null && minLength > maxLength) {
        throw InvalidDefinition('$path.min_length', 'min_greater_than_max');
      }
      return TextFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
        multiline: _bool(raw, 'multiline', path) ?? false,
        minLength: minLength,
        maxLength: maxLength,
      );
    case 'number':
      final min = _num(raw, 'min', path);
      final max = _num(raw, 'max', path);
      if (min != null && max != null && min > max) throw InvalidDefinition('$path.min', 'min_greater_than_max');
      return NumberFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
        min: min,
        max: max,
      );
    case 'integer':
      final min = _int(raw, 'min', path);
      final max = _int(raw, 'max', path);
      if (min != null && max != null && min > max) throw InvalidDefinition('$path.min', 'min_greater_than_max');
      return IntegerFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
        min: min,
        max: max,
      );
    case 'boolean':
      return BooleanFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
      );
    case 'date':
      return DateFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
      );
    case 'datetime':
      return DateTimeFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
      );
    case 'single_choice':
      return SingleChoiceFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
        options: _options(raw['options'], '$path.options'),
      );
    case 'multi_choice':
      final minSelected = _int(raw, 'min_selected', path, min: 0, max: maxOptions);
      final maxSelected = _int(raw, 'max_selected', path, min: 1, max: maxOptions);
      if (minSelected != null && maxSelected != null && minSelected > maxSelected) {
        throw InvalidDefinition('$path.min_selected', 'min_greater_than_max');
      }
      return MultiChoiceFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
        options: _options(raw['options'], '$path.options'),
        minSelected: minSelected,
        maxSelected: maxSelected,
      );
    case 'photo':
      return PhotoFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
      );
    case 'signature':
      return SignatureFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
      );
    case 'line':
      return LineFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
      );
    case 'polygon':
      return PolygonFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
      );
    default: // 'location' (el catálogo ya se comprobó arriba)
      return LocationFieldDef(
        key: key,
        label: label,
        help: help,
        required: required,
        visibleIf: visibleIf,
        defaultValue: raw['default'],
      );
  }
}

I18nText _i18n(Object? raw, String path) {
  if (raw is! Map<String, Object?> || raw.isEmpty || raw.length > 16) throw InvalidDefinition(path, 'invalid_i18n');
  final values = <String, String>{};
  for (final MapEntry(:key, :value) in raw.entries) {
    if (!_langCode.hasMatch(key)) throw InvalidDefinition('$path.$key', 'invalid_language');
    if (value is! String || value.isEmpty || value.runes.length > 256) {
      throw InvalidDefinition('$path.$key', 'invalid_label');
    }
    values[key] = value;
  }
  return I18nText(Map.unmodifiable(values));
}

List<ChoiceOption> _options(Object? raw, String path) {
  if (raw is! List<Object?> || raw.isEmpty || raw.length > maxOptions) throw InvalidDefinition(path, 'invalid_options');
  final options = <ChoiceOption>[];
  for (final (index, rawOption) in raw.indexed) {
    final optionPath = '$path.$index';
    if (rawOption is! Map<String, Object?>) throw InvalidDefinition(optionPath, 'not_an_object');
    for (final key in rawOption.keys) {
      if (key != 'value' && key != 'label') throw InvalidDefinition('$optionPath.$key', 'extra_forbidden');
    }
    final value = rawOption['value'];
    if (value is! String || !_optionValue.hasMatch(value)) {
      throw InvalidDefinition('$optionPath.value', 'invalid_option_value');
    }
    options.add(ChoiceOption(value, _i18n(rawOption['label'], '$optionPath.label')));
  }
  if (options.map((option) => option.value).toSet().length != options.length) {
    throw InvalidDefinition(path, 'duplicate_option');
  }
  return List.unmodifiable(options);
}

bool? _bool(Map<String, Object?> raw, String key, String path) {
  final value = raw[key];
  if (value == null) return null;
  if (value is! bool) throw InvalidDefinition('$path.$key', 'not_a_boolean');
  return value;
}

int? _int(Map<String, Object?> raw, String key, String path, {int? min, int? max}) {
  final value = raw[key];
  if (value == null) return null;
  if (value is! int) throw InvalidDefinition('$path.$key', 'not_an_integer');
  if ((min != null && value < min) || (max != null && value > max)) {
    throw InvalidDefinition('$path.$key', 'out_of_range');
  }
  return value;
}

double? _num(Map<String, Object?> raw, String key, String path) {
  final value = raw[key];
  if (value == null) return null;
  if (value is! num || !value.isFinite) throw InvalidDefinition('$path.$key', 'not_a_number');
  return value.toDouble();
}

/// Las reglas del DSL que dependen del resto de la plantilla.
void _checkVisibility(VisibilityExpr expr, Map<String, FormFieldDef> declared, String path) {
  if (expressionDepth(expr) > maxExprDepth) throw InvalidDefinition(path, 'too_deep');
  for (final leaf in leaves(expr)) {
    final target = declared[leafField(leaf)];
    // Solo hacia atrás ⇒ grafo acíclico por construcción.
    if (target == null) throw InvalidDefinition(path, 'forward_or_unknown_reference');
    final List<Object?> literals;
    switch (leaf) {
      case Presence():
        continue;
      case Comparison(:final op, :final value):
        final applicable = orderOperators.contains(op) ? _orderTypes : _equalityTypes;
        if (!applicable.contains(target.type)) throw InvalidDefinition(path, 'operator_not_applicable');
        literals = [value];
      case Membership(:final values):
        if (!_equalityTypes.contains(target.type)) throw InvalidDefinition(path, 'operator_not_applicable');
        literals = values;
      default:
        continue;
    }
    for (final literal in literals) {
      if (!_literalFits(target, literal)) throw InvalidDefinition(path, 'impossible_literal');
    }
  }
}

/// ¿Puede el campo referenciado tomar alguna vez ese literal? (una errata en
/// el valor de una opción haría la regla falsa para siempre).
bool _literalFits(FormFieldDef field, Object? literal) {
  if (literal == null) return true;
  return switch (field) {
    BooleanFieldDef() => literal is bool,
    NumberFieldDef() || IntegerFieldDef() => literal is num,
    SingleChoiceFieldDef() => literal is String && field.hasOption(literal),
    _ => literal is String,
  };
}
