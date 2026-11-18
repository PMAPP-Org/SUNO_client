# C4 nivel 2: contenedores

```mermaid
flowchart LR
    subgraph tel["Teléfono Android"]
        ui["UI Flutter<br/>(features/, ui/)"]
        dom["Dominio y sync<br/>(core/)"]
        db[("SQLite cifrado<br/>Drift + SQLCipher<br/>registros, outbox, cola de adjuntos,<br/>tareas, equipos, cursor")]
        files[("Archivos de la app<br/>fotos, firmas, .mbtiles, capas")]
        sec[("Keystore / Keychain<br/>tokens, llave de la BD, pines")]
    end
    api["Servidor SUNO /v1"]
    s3[("S3 (R2)")]

    ui --> dom
    dom --> db
    dom --> files
    dom --> sec
    dom -- "Dio + TrustStore" --> api
    dom -- "PUT/GET prefirmado" --> s3
```

| Contenedor | Tecnología | Responsabilidad |
|---|---|---|
| App | Flutter 3.47.9 / Dart 3.13 | Toda la lógica de campo; funciona sin red. |
| Base local | SQLite vía Drift, cifrada con SQLCipher (WAL, `synchronous=NORMAL`, un escritor) | Registros y su outbox en la misma transacción; cola de adjuntos; cursor del pull; copia de tareas, ítems, asignaciones, plantillas y equipos; outboxes de equipos. Esquema `schemaVersion = 2` (se reinició en 1 con el renombre a SUNO, [ADR-0011](../adr/0011-renombre-reinicia-la-base-local.md)). |
| Archivos | Directorio privado de la app | Fotos y firmas pendientes de subir; mapas base MBTiles y capas GeoJSON descargados y verificados por `sha256`. Sin copia de seguridad en la nube (`allowBackup=false`). |
| Almacén seguro | `flutter_secure_storage` (Keystore, Keychain *ThisDeviceOnly*) | Refresh token, llave de SQLCipher, pines TOFU, id del dispositivo. |
| Servidor | Django + Ninja (SUNO_server) | Ver la arquitectura del servidor. |
