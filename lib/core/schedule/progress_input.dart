// El % de avance acumulado que escribe el agente (costos, etapa 1): número
// entre 0 y 100 con hasta dos decimales, con coma o punto — lo mismo que el
// servidor guarda (`numeric(5,2)`). Puro.

final _pattern = RegExp(r'^\d{1,3}([.,]\d{1,2})?$');

/// El % escrito, o `null` si no es un número entre 0 y 100 con hasta dos decimales.
double? parseProgressPct(String text) {
  final value = text.trim();
  if (!_pattern.hasMatch(value)) return null;
  final pct = double.parse(value.replaceAll(',', '.'));
  return pct <= 100 ? pct : null;
}

/// `40.0` → `40`; `40.5` → `40,5`; `33.25` → `33,25`.
String formatProgressPct(double pct) =>
    pct.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '').replaceAll('.', ',');
