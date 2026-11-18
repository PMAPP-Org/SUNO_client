# ADR-0004: El código generado no se versiona

- **Estado:** Aceptada
- **Fecha:** 2026-07-30

## Contexto

`freezed`, `json_serializable`, `drift_dev` y `gen-l10n` generan archivos grandes que cambian con cada versión del generador.

## Decisión

`*.g.dart`, `*.freezed.dart` y `lib/l10n/app_localizations*.dart` están en `.gitignore` y se regeneran con `dart run build_runner build --delete-conflicting-outputs` y `flutter gen-l10n`. La CI los genera antes de analizar y probar.

## Consecuencias

- Diffs limpios; nada que revisar a mano en código generado.
- Quien clona debe correr los generadores antes de compilar (README).

## Referencias

- `.gitignore` («Decisión (Paso 0)»), [`README.md`](../../README.md), `.github/workflows/mobile.yml`.
