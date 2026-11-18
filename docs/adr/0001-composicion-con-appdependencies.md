# ADR-0001: Composición con un único AppDependencies y providers escritos a mano

- **Estado:** Aceptada
- **Fecha:** 2026-08-07

## Contexto

Doc 08 nombra Riverpod para la UI. Los servicios centrales (`AuthController`, `SyncEngine`) no son observables y la navegación es imperativa. Además, `riverpod_generator` no resolvía junto con `freezed` y `json_serializable` en el SDK de entonces.

## Decisión

- `core/app_dependencies.dart` construye **un solo objeto** con todos los servicios (`AppDependencies.bootstrap()`), y las funcionalidades nuevas le añaden campos en vez de crear grafos paralelos.
- `core/providers.dart` expone ese objeto con un `Provider` de Riverpod que `main()` sobrescribe; las pruebas de widgets lo sobrescriben con fakes.
- Providers escritos a mano (`Provider`, `NotifierProvider`), sin `riverpod_generator`.

## Consecuencias

- Un punto único para ver qué depende de qué y para inyectar fakes.
- No hay reactividad fina por servicio; las pantallas consultan o escuchan streams de Drift.
- Revisar `riverpod_generator` cuando el ecosistema resuelva junto.

## Referencias

- Commit `f913d4e` (plan de despliegue del demo, Tarea 5); `lib/core/app_dependencies.dart`, `lib/core/providers.dart`.
- [`DEPENDENCIES.md`](../../DEPENDENCIES.md) («Nota sobre `riverpod_generator`»).
