# SUNO_client

App móvil **offline-first** de VisitaCampo, para registrar visitas de campo: formularios dinámicos, GPS, fotos y firma. Todo se guarda en el teléfono (SQLite cifrado con SQLCipher) y se sincroniza con el servidor cuando hay red.

El backend (API, panel de administración e infraestructura) está en [`PMAPP-Org/SUNO_server`](https://github.com/PMAPP-Org/SUNO_server). Allí también viven la arquitectura (`docs/08-arquitectura-propuesta-visitacampo.md`), el SGSI ISO 27001 (`docs/seguridad/`) y el plan de construcción (`plans/`).

## Requisitos

- Flutter **3.44.9** (Dart 3.12.2), la versión con la que se generó `pubspec.lock`. Los demás canales no están probados.
- Para el APK: JDK 17 y el Android SDK.

## Puesta en marcha

```bash
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs   # freezed, json_serializable, drift
flutter test --concurrency=1
flutter run
```

Ni el código generado (`*.g.dart`, `*.freezed.dart`) ni los textos generados (`lib/l10n/app_localizations*.dart`) se versionan: se regeneran con los comandos de arriba.

## Estructura

| Carpeta | Qué hay |
|---|---|
| `lib/core/` | Dominio sin UI: sesión, sincronización (outbox, pull, CAS), formularios (DSL de visibilidad, validación), captura de visitas |
| `lib/data/` | Adaptadores: HTTP (Dio), base de datos local (Drift + SQLCipher), cámara, GPS |
| `lib/features/` | Pantallas: login, inicio, captura, firma |
| `lib/ui/` | Sistema de diseño (tema, tokens, widgets) y el renderer de formularios |
| `lib/l10n/` | Textos (`app_es.arb`) |
| `contract/` | Copia fijada del contrato del servidor: OpenAPI y casos de paridad ([`contract/README.md`](contract/README.md)) |
| `tool/` | Gates de CI propios de la app: lints, cobertura y el lock de Semgrep |

## Calidad y seguridad

Cada PR pasa, entre otros:
- `dart analyze` en modo estricto;
- `flutter test` con un suelo de cobertura del 75 %;
- el APK de release firmado, comprobado que no lleva la clave de debug, y su SBOM;
- los lints de [`tool/`](tool/): bypass de TLS (RD-01), sistema de diseño y ejecución dinámica de código (RD-06);
- la integridad del contrato;
- gitleaks, osv-scanner, Semgrep, actionlint, CodeQL (workflows) y Dependency Review.

El detalle está en [`CONTRIBUTING.md`](CONTRIBUTING.md). Las vulnerabilidades se reportan como indica [`SECURITY.md`](SECURITY.md).

## Releases

release-please versiona a partir de Conventional Commits: el título de cada PR es el commit de `master`, porque se integra con *Squash and merge*. Cada release publica el SBOM y, si existe la llave de subida en el environment `release`, el APK firmado con su checksum y atestación de procedencia. Ver [`CONTRIBUTING.md`](CONTRIBUTING.md#releases).

## Historia

Este repositorio salió del monorepo `PMAPP-Org/Seguimiento_Proyectos` (archivado) con su historial: los commits anteriores a la separación conservan la carpeta `app/` en sus rutas.
