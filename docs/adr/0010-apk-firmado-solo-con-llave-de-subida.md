# ADR-0010: El APK de release solo se firma con la llave de subida

- **Estado:** Aceptada
- **Fecha:** 2026-10-16

## Contexto

La plantilla de `flutter create` firmaba el release con la llave de debug y el manifiesto principal no declaraba `INTERNET`.

## Decisión

- El release se firma con `android/key.properties` y su `.jks`, que no se versionan. **Sin `key.properties` el build de release falla** en vez de firmar con debug.
- La CI (`android-release`) comprueba que falla sin llave, firma con una llave efímera y verifica con `apksigner`/`aapt` la firma y el permiso `INTERNET`.
- `release.yml` adjunta el APK firmado, su checksum y su atestación solo si existen los secretos `ANDROID_UPLOAD_*`; si no, publica la release sin APK con un aviso.
- `allowBackup=false` y reglas de extracción que excluyen todo: los datos de campo no van a copias en la nube.

## Consecuencias

- Perder la llave obliga a la recuperación de Google Play: va en un gestor de secretos.
- Hoy las releases salen sin APK porque faltan los secretos (problema conocido).

## Referencias

- Commit `d664107`; [`CONTRIBUTING.md`](../../CONTRIBUTING.md#firma-de-releases-android); `.github/workflows/release.yml`.
