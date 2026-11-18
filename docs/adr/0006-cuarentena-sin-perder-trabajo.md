# ADR-0006: Rechazos y conflictos a cuarentena, reintentos con op_uuid nuevo

- **Estado:** Aceptada
- **Fecha:** 2026-10-17

## Contexto

ADR-0003 del servidor: el servidor gana y nunca se descarta trabajo en silencio. La primera implementación pisaba la versión del agente en un conflicto, y «Reintentar» reenviaba el mismo `op_uuid`, al que el servidor responde con el resultado guardado (el mismo rechazo).

## Decisión

- Un conflicto va a **cuarentena** con la fila del servidor guardada; el agente elige: «Enviar mi versión» (un `update` sobre la versión actual del servidor, solo con los campos que difieren) o «Quedarme con la del servidor».
- Un rechazo guarda el `code` y solo los pares `field`/`reason`; se puede **corregir** (formulario con los campos marcados), **reintentar** o **descartar** con confirmación.
- **Cada reintento usa un `op_uuid` nuevo.** El registro se reenvía antes que sus adjuntos.
- Un registro validado (`record_validated`) solo se puede descartar.

## Consecuencias

- Ningún camino de la UI descarta trabajo sin confirmación.
- Sin merge de tres vías.

## Referencias

- PR #4 (`a9007c0`, Paso 23), PR #19, PR #46; `lib/core/sync/quarantine_service.dart`, `lib/features/review/`.
