# Problemas conocidos (SUNO_client)

Problemas abiertos al 2026-11-17, para convertir en issues con la etiqueta `known-issue`. Desde ese momento **el issue es la fuente de verdad**. Severidades en [`CONTRIBUTING.md`](../../CONTRIBUTING.md#bugs-y-parches). Los del servidor y la infraestructura están en `docs/bugs/problemas-conocidos.md` de SUNO_server.

## KI-C01. Las releases salen sin APK: faltan los secretos de firma
- **Issue:** [#65](https://github.com/PMAPP-Org/SUNO_client/issues/65)

- **Título propuesto:** `Release: configurar los secretos ANDROID_UPLOAD_* para publicar el APK firmado`
- **Severidad:** S3. No hay APK oficial y verificable (con checksum y atestación) para instalar en campo.
- **Descripción:** `release.yml` solo firma y adjunta el APK si existen `ANDROID_UPLOAD_KEYSTORE_B64`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_KEYSTORE_PASSWORD` y `ANDROID_UPLOAD_KEY_PASSWORD` en el environment `release`. La v0.13.1 se publicó con el aviso «Release v0.13.1 sin APK» y solo con los SBOM. Requiere un Admin y una llave de subida guardada en un gestor de secretos.
- **Evidencia:** run 43319669217 de `release.yml`; `gh release view v0.13.1` (assets: `sbom-app.cdx.json`, `sbom-app.spdx.json`); [`CONTRIBUTING.md`](../../CONTRIBUTING.md#releases).

## KI-C02. `RELEASE_PLEASE_TOKEN` sin configurar
- **Issue:** [#66](https://github.com/PMAPP-Org/SUNO_client/issues/66)

- **Título propuesto:** `Release: configurar RELEASE_PLEASE_TOKEN para que el PR de release corra la CI`
- **Severidad:** S4.
- **Descripción:** `release.yml` usa `secrets.RELEASE_PLEASE_TOKEN || github.token`. Con `github.token`, GitHub no dispara workflows sobre el PR `chore: release X.Y.Z`, así que ese PR se integra sin checks. No se pudo comprobar si el secreto existe (hace falta permiso de Admin); está documentado como pendiente de configuración de una sola vez.
- **Evidencia:** `.github/workflows/release.yml` (línea del `token:`); [`CONTRIBUTING.md`](../../CONTRIBUTING.md#releases).

## KI-C03. No se sincroniza con la app cerrada
- **Issue:** [#67](https://github.com/PMAPP-Org/SUNO_client/issues/67)

- **Título propuesto:** `Sync: sincronizar y subir adjuntos con la app cerrada (WorkManager / BGTaskScheduler)`
- **Severidad:** S3.
- **Descripción:** el ciclo de sync solo corre con la app abierta ([ADR-0005](../adr/0005-sincronizacion-con-la-app-abierta.md)). Si el agente cierra la app, nada sube hasta que la abra. Es el resto del Paso 18 y necesita pruebas en dispositivo real (Android e iOS).
- **Evidencia:** `lib/core/sync/sync_coordinator.dart` y `lib/core/attachments/attachment_upload_scheduler.dart` («Alcance»); `plans/suno-progreso.md` del servidor (Paso 18).

## KI-C04. Pruebas en dispositivo real pendientes
- **Issue:** [#68](https://github.com/PMAPP-Org/SUNO_client/issues/68)

- **Título propuesto:** `Pruebas en dispositivo: TrustStore, navegación C4, QR y GPS de C5/C6`
- **Severidad:** S3.
- **Descripción:** sin prueba en teléfono real: el `TrustStore` (Paso 16) y los pines SPKI reales (dependen del dominio oficial), la navegación a la asignación (lista de [`../c4-navegacion.md`](../c4-navegacion.md)), cámara QR, compartir y GPS de C5/C6, y el conflicto contra el backend real (Paso 23).
- **Evidencia:** `docs/c4-navegacion.md` («Pendiente de dispositivo real»); `plans/suno-progreso.md` del servidor («Sigue pendiente»).

## KI-C05. Hallazgos de revisión de C4 y C5/C6 sin verificar
- **Issue:** [#69](https://github.com/PMAPP-Org/SUNO_client/issues/69)

- **Título propuesto:** `Verificar hallazgos de revisión de C4 (#36) y C5/C6 (#37) en la app`
- **Severidad:** S3 hasta verificarlos (uno bloquea el guardado de un registro).
- **Descripción:** GPS apagado mostrado como «sin señal»; el mapa vuelve a pedir permiso al volver de la navegación; «Comprobando el GPS…» sin reintento; un repetible oculto con filas bloquea el guardado; errores del servidor dentro de filas que no se pueden limpiar; PDF sin GPS con «null, null»; GeoJSON que copia todas las respuestas en cada geometría. No consta cuáles se corrigieron antes del merge. Verificar cada uno y abrir un issue por cada uno vigente.
- **Evidencia:** `plans/suno-progreso.md` del servidor, «Estado al 2026-10-29».

## KI-C06. `DEPENDENCIES.md` desactualizado
- **Issue:** [#70](https://github.com/PMAPP-Org/SUNO_client/issues/70)

- **Título propuesto:** `DEPENDENCIES.md no refleja pubspec.yaml`
- **Severidad:** S4.
- **Descripción:** dice que `freezed` está anclado a `3.2.6-dev.1` (el lock tiene 4.0.3, PR #58); no tiene filas para `geolocator`, `image_picker`, `crypto`, `flutter_map`, `latlong2`, `proj4dart`, `sqlite3` (runtime) ni `yaml`; y `mobile_scanner`, `pdf` y `share_plus` aparecen bajo «Desarrollo» aunque son de runtime. Rompe la regla de [ADR-0003](../adr/0003-presupuesto-de-dependencias.md).
- **Evidencia:** `DEPENDENCIES.md`, `pubspec.yaml`, `pubspec.lock`.
