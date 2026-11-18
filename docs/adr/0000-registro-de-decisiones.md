# ADR-0000: Registro de decisiones de la app

- **Estado:** Aceptada
- **Fecha:** 2026-11-17

## Contexto

Las decisiones de la app estaban en `DEPENDENCIES.md`, cuerpos de PR, comentarios del código y en doc 08 del servidor. Las decisiones transversales (sync, autenticación, TLS, formularios) ya tienen ADR en SUNO_server.

## Decisión

- Esta carpeta registra las decisiones **propias de la app Flutter**, con el mismo proceso del servidor ([ADR-0000 de SUNO_server](https://github.com/PMAPP-Org/SUNO_server/blob/master/docs/adr/0000-registro-de-decisiones.md)): formato Nygard, un archivo `NNNN-titulo-en-kebab.md`, secciones Estado, Fecha, Contexto, Decisión, Consecuencias y Referencias.
- **Inmutables:** un cambio de rumbo es un ADR nuevo que reemplaza al anterior; en el viejo solo cambia el estado a «Reemplazada por ADR-NNNN».
- Las decisiones transversales se citan como «ADR-NNNN del servidor» y no se duplican aquí.
- Cada pieza que toma una decisión de la app entrega su ADR en el mismo PR ([`CONTRIBUTING.md`](../../CONTRIBUTING.md#documentación)).

## Consecuencias

- Numeración independiente de la del servidor: «ADR-0005» a secas es de este repositorio.

## Referencias

- [ADR del servidor](https://github.com/PMAPP-Org/SUNO_server/tree/master/docs/adr).
