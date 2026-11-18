# Stack de la app

Versiones de `pubspec.lock` y `.github/workflows/` en `master` (v0.13.1). El inventario exacto, con dependencias transitivas, es el SBOM CycloneDX/SPDX que genera `mobile.yml` en cada PR (artefacto `sbom-app`) y que `release.yml` adjunta a cada release. Cada paquete directo se justifica en [`DEPENDENCIES.md`](../../DEPENDENCIES.md).

## Lenguaje y framework

| Componente | Versión | Para qué | Por qué |
|---|---|---|---|
| Flutter | 3.47.9 (fijado en CI) | UI y plataforma. | ADR-0001 del servidor |
| Dart | 3.13 (`sdk: ^3.13.0`) | Lenguaje. | ADR-0001 del servidor |
| JDK | 17 | Build del APK. | `mobile.yml`, `release.yml` |

## Paquetes clave

| Paquete | Versión | Para qué | Por qué |
|---|---|---|---|
| drift / drift_dev | 2.35.4 / 2.35.3 | Base local tipada, migraciones, streams. | ADR-0002 del servidor |
| sqlite3 | 3.5.2 | SQLCipher por *hooks*; lectura de MBTiles. | [ADR-0002](../adr/0002-sqlcipher-por-hooks-de-sqlite3.md), [ADR-0008](../adr/0008-mapas-base-mbtiles-con-sqlite3.md) |
| flutter_secure_storage | 10.3.4 | Tokens, llave de la BD, pines. | ADR-0008 y ADR-0009 del servidor |
| flutter_riverpod | 3.4.3 | Inyección de `AppDependencies`. | [ADR-0001](../adr/0001-composicion-con-appdependencies.md) |
| freezed / freezed_annotation | 4.0.3 / 3.1.0 | Tipos sellados (RD-02/RD-03). | ADR-0001 del servidor |
| json_serializable / json_annotation | 6.15.2 / 4.12.0 | (De)serialización generada, `snake_case`. | `DEPENDENCIES.md` |
| build_runner | 2.17.1 | Generación de código (no se versiona). | [ADR-0004](../adr/0004-codigo-generado-no-se-versiona.md) |
| dio | 5.11.1 | HTTP con interceptores y adaptador para `TrustStore`. | `DEPENDENCIES.md` |
| uuid | 4.6.0 | `op_uuid` UUIDv7 y ids del cliente. | ADR-0003 del servidor |
| crypto | 3.0.8 | `sha256` de adjuntos y descargas. | ADR-0007 del servidor |
| geolocator | 14.1.2 | GPS. | — |
| image_picker | 1.2.4 | Fotos. | — |
| mobile_scanner | 7.5.0 | Escaneo QR sin red. | `DEPENDENCIES.md` (C5) |
| flutter_map / latlong2 | 8.3.2 / 0.10.1 | Mapa, asignaciones, geometrías. | [ADR-0008](../adr/0008-mapas-base-mbtiles-con-sqlite3.md) |
| proj4dart | 3.0.0 | Coordenadas en otros sistemas (Fase C). | `pubspec.yaml` |
| pdf / share_plus | 3.13.1 / 13.3.1 | Exportación local y compartir. | `DEPENDENCIES.md` (C6) |
| url_launcher | 6.3.3 | Abrir la ruta en Google Maps. | [`../c4-navegacion.md`](../c4-navegacion.md) |
| intl, flutter_localizations | 0.20.3 / SDK | Textos en español (`gen-l10n`). | — |
| path_provider / path | 2.1.6 / 1.9.1 | Rutas de archivos. | `DEPENDENCIES.md` |

## CI y seguridad

| Herramienta | Dónde | Para qué |
|---|---|---|
| `dart analyze`, `flutter test --coverage` | `mobile.yml` | Análisis estricto y pruebas (cobertura ≥ 75 %). |
| Build del APK de release | `mobile.yml` (`android-release`) | Firma con llave efímera; falla sin `key.properties` ([ADR-0010](../adr/0010-apk-firmado-solo-con-llave-de-subida.md)). |
| syft | `mobile.yml`, `release.yml` | SBOM CycloneDX y SPDX. |
| Lints de `tool/` | `mobile.yml` | RD-01, RD-06, sistema de diseño, nombres. |
| `contract.yml` | — | Integridad de la copia fijada del contrato. |
| gitleaks, osv-scanner, Semgrep | `security.yml` | Secretos, CVE, SAST (Semgrep fijado en `tool/requirements-sast.lock`). |
| CodeQL, Dependency Review, Scorecard, actionlint | workflows propios | Workflows y dependencias. |
| release-please | `release.yml` | Versiones, CHANGELOG, APK firmado si hay secretos (ADR-0015 del servidor). |
