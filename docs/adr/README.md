# Decisiones de arquitectura de la app (ADR)

Proceso: [ADR-0000](0000-registro-de-decisiones.md). Las decisiones transversales (sync, autenticación, TLS, formularios, almacén local, release-please) están en los [ADR del servidor](https://github.com/PMAPP-Org/SUNO_server/tree/master/docs/adr).

| ADR | Título | Estado |
|---|---|---|
| [0000](0000-registro-de-decisiones.md) | Registro de decisiones de la app | Aceptada |
| [0001](0001-composicion-con-appdependencies.md) | Composición con un único `AppDependencies` y providers a mano | Aceptada |
| [0002](0002-sqlcipher-por-hooks-de-sqlite3.md) | SQLCipher por los hooks de `sqlite3` 3.x | Aceptada |
| [0003](0003-presupuesto-de-dependencias.md) | Presupuesto de dependencias | Aceptada |
| [0004](0004-codigo-generado-no-se-versiona.md) | El código generado no se versiona | Aceptada |
| [0005](0005-sincronizacion-con-la-app-abierta.md) | Sincronización automática solo con la app abierta | Aceptada |
| [0006](0006-cuarentena-sin-perder-trabajo.md) | Rechazos y conflictos a cuarentena, reintentos con `op_uuid` nuevo | Aceptada |
| [0007](0007-equipos-con-outboxes-propias.md) | Equipos con outboxes propias por tipo | Aceptada |
| [0008](0008-mapas-base-mbtiles-con-sqlite3.md) | Mapas base MBTiles leídos con `sqlite3` | Aceptada |
| [0009](0009-servidor-fijado-en-compilacion.md) | URL del servidor y pines fijados en compilación | Aceptada |
| [0010](0010-apk-firmado-solo-con-llave-de-subida.md) | El APK de release solo se firma con la llave de subida | Aceptada |
| [0011](0011-renombre-reinicia-la-base-local.md) | El renombre a `com.suno.app` reinicia la base local | Aceptada |
