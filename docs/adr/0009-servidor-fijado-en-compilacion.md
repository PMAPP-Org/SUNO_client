# ADR-0009: URL del servidor y pines fijados en compilación

- **Estado:** Aceptada
- **Fecha:** 2026-10-18

## Contexto

Elegir el servidor desde la app cambiaría el modelo de confianza (TOFU de un servidor arbitrario, ADR-0009 del servidor). Las primeras builds publicadas apuntaban a `https://localhost`.

## Decisión

- La URL base y los pines SPKI se fijan al compilar con `--dart-define` (`SUNO_API_BASE_URL`, `SUNO_SPKI_PINS`, `SUNO_SPKI_PINS_EXPIRE`). Sin override, `kApiBaseUrl` apunta a producción.
- No hay pantalla para cambiar de servidor.

## Consecuencias

- Otro servidor (pruebas, cliente auto-hospedado) exige otra build.
- Los pines reales se fijan cuando exista el dominio oficial.

## Referencias

- PR #11 (`99e90fd`); PR #20 (`86fdf2a`, «Fuera de alcance»); PR #53 (nombres `SUNO_*`); `lib/core/constants.dart`.
