# ADR-0011: El renombre a com.suno.app reinicia la base local

- **Estado:** Aceptada
- **Fecha:** 2026-11-09

## Contexto

El producto pasó de «VisitaCampo»/«visitas» a «SUNO»/«registros», y el servidor pasó al contrato de esquema 2 sin convivencia (ADR-0025 del servidor).

## Decisión

- App id nuevo `com.suno.app`, paquete Dart `suno`, dart-defines `SUNO_*`, APK `suno-<versión>.apk`.
- La base Drift se **reinicia** (`schemaVersion` 1) en vez de migrar las tablas de visitas; desde ahí cada cambio sube la versión con su prueba N-1 → N.
- La app acepta `suno/form@1` y, por compatibilidad, `visitacampo/form@1`.
- Guardia `tool/check_naming.sh` en CI.

## Consecuencias

- Para Android es otra app: hay que instalarla y desinstalar la vieja; lo no sincronizado en la vieja se pierde (había que sincronizar antes).

## Referencias

- PR #53 (`ac74efa`); [`CONTRIBUTING.md`](../../CONTRIBUTING.md#base-de-datos-local).
