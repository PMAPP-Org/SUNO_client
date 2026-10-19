// Estado de un formulario dinámico en pantalla (Paso 21).
//
// Guarda las respuestas, recalcula la visibilidad en cada cambio (el DSL es un
// recorrido lineal acotado: barato) y valida con las mismas reglas que el
// servidor — **solo para UX** (ADR-012): el servidor revalida en el push.
import 'package:flutter/foundation.dart';

import '../../core/forms/answers.dart';
import '../../core/forms/form_definition.dart';
import '../../core/forms/visibility.dart';

class FormController extends ChangeNotifier {
  FormController(this.definition, {Map<String, Object?>? initialAnswers, Map<String, String> serverErrors = const {}})
    : _answers = Map.of(initialAnswers ?? defaultAnswers(definition)),
      _serverErrors = Map.of(serverErrors);

  final FormDefinition definition;
  final Map<String, Object?> _answers;

  /// Errores que señaló el **servidor** al rechazar la visita (Paso 23), por
  /// clave de campo. Se muestran desde el principio —son la razón de abrir el
  /// formulario— y el de un campo desaparece en cuanto el agente lo cambia.
  final Map<String, String> _serverErrors;

  /// Los errores se muestran tras el primer intento de guardar, no mientras
  /// el agente todavía está escribiendo.
  bool _showErrors = false;
  bool get showErrors => _showErrors;

  /// Respuestas actuales (sin claves en blanco), en el formato de `answers`.
  Map<String, Object?> get answers => Map.unmodifiable(_answers);

  Object? valueOf(String key) => _answers[key];

  List<FormFieldDef> get visibleFields => [
    for (final field in definition.fields)
      if (evaluate(field.visibleIf, _answers)) field,
  ];

  List<AnswerViolation> get violations => validateAnswers(definition, _answers);

  Map<String, String> get displayedErrors => {
    if (_showErrors)
      for (final v in violations) v.fieldKey: v.reason,
    ..._serverErrors,
  };

  /// El `reason` del primer error de [key], si hay que mostrarlo.
  String? errorFor(String key) {
    final fromServer = _serverErrors[key];
    if (fromServer != null) return fromServer;
    if (!_showErrors) return null;
    for (final violation in violations) {
      if (violation.fieldKey == key) return violation.reason;
    }
    return null;
  }

  /// Fija la respuesta de [key]. Un valor en blanco **quita** la clave: así
  /// `answers` no lleva `""` ni `[]` que el servidor tendría que interpretar.
  void setAnswer(String key, Object? value) {
    final hadServerError = _serverErrors.keys.any((k) => k == key || k.startsWith('$key.'));
    _serverErrors.removeWhere((k, _) => k == key || k.startsWith('$key.'));
    if (isBlank(value)) {
      if (_answers.remove(key) == null && !hadServerError) return;
    } else {
      _answers[key] = value;
    }
    notifyListeners();
  }

  /// Intento de guardar: muestra los errores y devuelve si no hay ninguno
  /// (ni locales ni pendientes del servidor).
  bool validate() {
    _showErrors = true;
    // Un error del servidor sobre un campo que no se ve (oculto, o una clave
    // que la plantilla no declara) no lo puede arreglar el agente, y su
    // respuesta tampoco viajará: al guardar solo van los campos visibles.
    final visible = {for (final field in visibleFields) field.key};
    _serverErrors.removeWhere((key, _) => !visible.contains(key.split('.').first));
    notifyListeners();
    return violations.isEmpty && _serverErrors.isEmpty;
  }
}
