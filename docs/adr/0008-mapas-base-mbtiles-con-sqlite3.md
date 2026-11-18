# ADR-0008: Mapas base MBTiles leídos con sqlite3 en flutter_map

- **Estado:** Aceptada
- **Fecha:** 2026-10-18

## Contexto

El servidor publica mapas base como MBTiles ráster por organización (ADR-0021 del servidor, que reemplaza el PMTiles de ADR-0012). La app debe mostrarlos sin red.

## Decisión

- Descarga automática de los mapas base de la organización, reanudable con `Range` y verificada por `sha256` (`core/offline/verified_download.dart`, `data/http/resumable_fetch.dart`); un archivo que no coincide se descarta.
- `data/map/mbtiles_tile_provider.dart` lee las teselas del `.mbtiles` con `sqlite3` (ya en el árbol por Drift) como proveedor de `flutter_map`.

## Consecuencias

- Sin motor SIG ni dependencia nueva para el mapa.
- Los paquetes ráster ocupan más espacio en el teléfono.

## Referencias

- SUNO_client PR #24, #26 y #27; servidor PR #27.
