# ADR-0002: SQLCipher por los hooks de sqlite3 3.x

- **Estado:** Aceptada
- **Fecha:** 2026-08-02

## Contexto

ADR-0002 del servidor eligió Drift + SQLCipher con `sqlcipher_flutter_libs`. Ese paquete y `sqlite3_flutter_libs` quedaron descontinuados («update to version 3.x of package:sqlite3»).

## Decisión

Activar SQLCipher con el sistema de *hooks*/native assets de `sqlite3` 3.x (`pubspec.yaml`: `hooks.user_defines.sqlite3.source: sqlcipher`). La llave vive en el almacén seguro (`EncryptionKeyStore`). Al abrir: `PRAGMA key`, luego `journal_mode=WAL` y `synchronous=NORMAL`.

## Consecuencias

- La decisión de cifrar no cambia; cambia solo el empaquetado.
- Una prueba comprueba que el archivo es ilegible sin la llave (`test/data/local/encryption_smoke_test.dart`).

## Referencias

- Paso 11 (`738db92`); [`DEPENDENCIES.md`](../../DEPENDENCIES.md) («Nota sobre `sqlcipher_flutter_libs`»); `lib/data/local/database.dart`.
