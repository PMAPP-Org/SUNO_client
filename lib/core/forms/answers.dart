// Validación de `answers` en el dispositivo (Paso 21, tarea 4): espejo de
// `server/visitacampo/forms/answers.py`.
//
// **Solo UX** (ADR-012, RD-03): señala en pantalla qué falta o está mal antes
// de guardar. La autoridad es el servidor, que revalida cada visita en el push
// contra la definición de **su** `template_version_id`. Las reglas y los
// `reason` son los mismos que allí, para que lo que se marca en pantalla sea
// lo que el servidor rechazaría:
//
// 1. clave no declarada ⇒ `unknown_field`;
// 2. campo obligatorio y visible sin responder ⇒ `required`;
// 3. campo oculto: no se exige, pero si trae valor se comprueba su tipo;
// 4. hasta [maxViolations] violaciones a la vez.
import 'dart:convert';

import 'package:meta/meta.dart';

import 'form_definition.dart';
import 'visibility.dart';

const maxViolations = 20;

@immutable
class AnswerViolation {
  const AnswerViolation(this.fieldKey, this.reason);

  /// Clave del campo, sin el prefijo `answers.` del servidor.
  final String fieldKey;
  final String reason;

  @override
  bool operator ==(Object other) => other is AnswerViolation && other.fieldKey == fieldKey && other.reason == reason;

  @override
  int get hashCode => Object.hash(fieldKey, reason);

  @override
  String toString() => 'answers.$fieldKey: $reason';
}

List<AnswerViolation> validateAnswers(
  FormDefinition definition,
  Map<String, Object?> answers, {
  String prefix = '',
  bool required = true,
}) {
  final violations = <AnswerViolation>[];
  final declared = {for (final field in definition.fields) field.key};

  for (final key in answers.keys) {
    if (!declared.contains(key)) {
      violations.add(AnswerViolation('$prefix$key', 'unknown_field'));
      if (violations.length >= maxViolations) return violations;
    }
  }

  for (final field in definition.fields) {
    final value = answers[field.key];
    final path = '$prefix${field.key}';
    final visible = required && evaluate(field.visibleIf, answers);
    if (isBlank(value)) {
      if (field.required && visible) {
        violations.add(AnswerViolation(path, 'required'));
      } else if (field is RepeatFieldDef && field.minRows > 0 && visible) {
        violations.add(AnswerViolation(path, 'too_few_rows'));
      }
    } else {
      final reason = field.checkAnswer(value);
      if (reason != null) {
        violations.add(AnswerViolation(path, reason));
      } else if (field is RepeatFieldDef && value is List<Object?>) {
        for (final (index, row) in value.indexed) {
          violations.addAll(
            validateAnswers(field.definition, row! as Map<String, Object?>, prefix: '$path.$index.', required: visible),
          );
          if (violations.length >= maxViolations) break;
        }
      }
    }
    if (violations.length >= maxViolations) break;
  }
  return violations.take(maxViolations).toList();
}

/// Solo al crear un formulario/fila; una edición conserva incluso los vacíos.
Map<String, Object?> defaultAnswers(FormDefinition definition) => {
  for (final field in definition.fields)
    if (field.defaultValue != null) field.key: jsonDecode(jsonEncode(field.defaultValue)) as Object?,
};

/// Recorre las respuestas con su definición, incluidas todas las filas.
Iterable<(FormFieldDef, Object?)> answeredFields(FormDefinition definition, Map<String, Object?> answers) sync* {
  for (final field in definition.fields) {
    final value = answers[field.key];
    if (field is RepeatFieldDef && value is List<Object?>) {
      for (final row in value) {
        if (row is Map<String, Object?>) yield* answeredFields(field.definition, row);
      }
    } else {
      yield (field, value);
    }
  }
}

/// Los campos visibles con estas respuestas, en el orden de la plantilla.
List<FormFieldDef> visibleFields(FormDefinition definition, Map<String, Object?> answers) => [
  for (final field in definition.fields)
    if (evaluate(field.visibleIf, answers)) field,
];
