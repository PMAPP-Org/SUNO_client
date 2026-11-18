# ADR-0005: Sincronización automática solo con la app abierta, un ciclo a la vez

- **Estado:** Aceptada
- **Fecha:** 2026-10-18

## Contexto

Al principio solo se sincronizaba al pulsar «Sincronizar»: una jornada entera podía quedarse en el teléfono aunque hubiera cobertura. La sincronización con la app cerrada (WorkManager, BGTaskScheduler) exige pruebas en dispositivo real que no se podían hacer.

## Decisión

- `SyncCoordinator` dispara el ciclo completo (push de la outbox, subida de adjuntos, pull, tareas y equipos) al abrir el inicio, al volver al primer plano, cada 5 minutos con la app abierta y justo después de guardar. El botón «Sincronizar» usa el mismo coordinador con `force: true`.
- **Single-flight:** un disparo durante un ciclo deja pedido otro al terminar.
- Sin red no pasa nada: cada operación tiene su backoff y el siguiente disparo reintenta.
- La sincronización con la app cerrada queda pendiente; lo pendiente sale en el siguiente ciclo.

## Consecuencias

- Si el agente cierra la app, nada sube hasta que la vuelva a abrir.
- Un registro guardado nunca se pierde entre dos ciclos.

## Referencias

- PR #15 (`f682585`); `lib/core/sync/sync_coordinator.dart`, `lib/core/attachments/attachment_upload_scheduler.dart`.
