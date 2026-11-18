# Arquitectura de la app SUNO (estado actual)

Cómo está construida la app hoy, según el código de `master` (v0.13.1, 2026-11-12). Sigue el modelo [C4](https://c4model.com/).

| Documento | Qué responde |
|---|---|
| [`contexto.md`](contexto.md) | C4 nivel 1: quién usa la app y con qué habla. |
| [`contenedores.md`](contenedores.md) | C4 nivel 2: la app, su base local, el almacén seguro y el servidor. |
| [`componentes.md`](componentes.md) | C4 nivel 3: capas `core/`, `data/`, `features/`, `ui/` y sus módulos. |
| [`stack.md`](stack.md) | Dart, Flutter y paquetes clave, con versión y motivo. |

**Fuera de este repositorio** (en [SUNO_server](https://github.com/PMAPP-Org/SUNO_server)): la arquitectura del sistema completo (`docs/arquitectura/`), el **flujo de sincronización** entre app y servidor (`docs/arquitectura/flujos.md`), el contrato de la API y las decisiones transversales (`docs/adr/`). Las decisiones propias de la app están en [`../adr/`](../adr/README.md).

## Diferencias entre la propuesta (doc 08 del servidor) y el código

| Tema | Doc 08 / ADR del servidor | Código actual |
|---|---|---|
| Estado | Riverpod como gestor de estado en la UI. | Un único objeto `AppDependencies` expuesto con un provider de Riverpod; la navegación es imperativa ([ADR-0001](../adr/0001-composicion-con-appdependencies.md)). |
| SQLCipher | `sqlcipher_flutter_libs`. | *Hooks* de `sqlite3` 3.x con `source: sqlcipher` ([ADR-0002](../adr/0002-sqlcipher-por-hooks-de-sqlite3.md)). |
| Mapa base | `flutter_map` + PMTiles. | `flutter_map` + MBTiles ráster leídos con `sqlite3` ([ADR-0008](../adr/0008-mapas-base-mbtiles-con-sqlite3.md)). |
| Subida en segundo plano | WorkManager / BGTask. | Solo con la app abierta; la sincronización con la app cerrada sigue pendiente ([ADR-0005](../adr/0005-sincronizacion-con-la-app-abierta.md)). |
| Plataformas | Android e iOS. | Se publica solo el APK de Android. |

## Cómo se mantiene

Cada pieza que cambia la app actualiza estas páginas en su PR, junto con su ADR ([`CONTRIBUTING.md`](../../CONTRIBUTING.md#documentación)).
