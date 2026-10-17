<!--
El TÍTULO de este PR será el mensaje del commit en master (Squash and merge)
y de él sale el CHANGELOG: usa Conventional Commits, p. ej.
  feat(capture): …   fix(sync): …   feat!: … (rompe compatibilidad)
-->

## Qué cambia y por qué



## Cómo probarlo



## Checklist del autor

**Calidad**
- [ ] El CI está en verde, o lo que falla está explicado aquí y no es de este cambio.
- [ ] Los tests nuevos o cambiados cubren el comportamiento, incluido el caso de error (la cobertura no baja del 75 %, `tool/check_lcov.py`).
- [ ] Textos en `lib/l10n/app_es.arb` y medidas/colores del tema: `tool/lint_ui_tokens.sh` pasa.
- [ ] Si depende de un cambio del contrato: el servidor ya lo publicó y `contract/` está actualizado a esa versión (`contract/SOURCE`).

**Seguridad** ([OWASP Top 10 del proyecto](https://github.com/PMAPP-Org/SUNO_server/blob/master/docs/seguridad/owasp-top10-2025.md))
- [ ] Sin secretos, tokens ni llaves en el código, los tests ni el historial: vienen de variables de entorno o del environment `release`.
- [ ] Lo que llega de la red o del disco se parsea a tipos sellados con resultado `Ok`/`Err` explícito, nunca con acceso sin validar (RD-02/RD-03).
- [ ] Sin `badCertificateCallback` ni otro bypass de TLS fuera de `TrustStore` (RD-01, `tool/lint_no_tls_bypass.sh`).
- [ ] No se desactiva ningún gate. Los falsos positivos se suprimen por regla exacta (`# nosec`, `# nosemgrep`, `.gitleaksignore`) con la justificación al lado, y las vulnerabilidades aceptadas van a [`excepciones.md`](https://github.com/PMAPP-Org/SUNO_server/blob/master/docs/seguridad/excepciones.md) con fecha de caducidad.
- [ ] Ningún log ni mensaje de error muestra contraseñas, tokens ni datos personales (RD-12).
- [ ] Si toca autenticación, TLS, cifrado de la BD local o la firma de Android: lo indico aquí para una revisión más cuidadosa.

**Datos personales** (Ley 1581 de 2012, ISO 27001 A.5.34)
- [ ] Si se guarda un dato personal nuevo (ubicación, foto, identificador, IP): está justificado y tiene plazo de retención en [`retencion.md`](https://github.com/PMAPP-Org/SUNO_server/blob/master/docs/seguridad/retencion.md).

**Datos locales y compatibilidad**
- [ ] Si cambia el esquema Drift: sube `schemaVersion` y hay test de migración N-1→N con datos (`test/data/local/migration_test.dart`).
- [ ] Si rompe compatibilidad con datos ya guardados en teléfonos o con el servidor desplegado: el título lleva `!` y se explica la migración.

## Para quien revisa

La aprobación tiene que darla **una persona distinta del autor** (ISO 27001 A.8.32). Revisa el diff, no solo el CI.
