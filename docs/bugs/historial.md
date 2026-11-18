# Historial de bugs y parches (SUNO_client)

Registro hacia atrás de defectos de la app ya corregidos, reconstruido el 2026-11-17 a partir de `git log` (commits `fix:` y cuerpos de PR que dicen «Fallo corregido» o «Bug arreglado»), la sección «Corregido» de [`CHANGELOG.md`](../../CHANGELOG.md) y `plans/suno-progreso.md` de SUNO_server. Desde ahora cada corrección se registra aquí en su propio PR ([`CONTRIBUTING.md`](../../CONTRIBUTING.md#bugs-y-parches)).

- **Versión:** primera release con el parche; «—» si fue antes de la primera release.
- **Prueba de regresión:** ruta actual; «—» si no hay una identificable. Los commits anteriores a la separación del monorepo tenían la app en `app/`.
- Los fallos de servidor, infraestructura y CI de la época del monorepo están en el historial de SUNO_server.

## 1. Defectos que llegaron a `master`

| # | Fecha | Versión | PR / commit | Área | Síntoma | Causa | Parche | Prueba de regresión |
|---|---|---|---|---|---|---|---|---|
| 1 | 2026-08-03 | — | Paso 13 (`ca60181`) | Modelos / contrato | El JSON real del servidor (`snake_case`) no se parseaba; el error ya existía en el `Visit` del Paso 10. | `json_serializable` esperaba `camelCase`; la prueba de ida y vuelta solo se comparaba consigo misma. | `field_rename: snake` en `build.yaml`. | `test/core/domain/record_test.dart` |
| 2 | 2026-08-03 | — | Paso 13 (`ca60181`) | Sync | El backoff no crecía: `OutboxInflight` no arrastraba el contador de intentos. | Transición `pending → inflight` sin el `attempt`. | Se conserva el contador. | `test/core/sync/outbox_op_state_test.dart` |
| 3 | 2026-08-07 | — | `f0000dc` | Adjuntos | Un archivo local borrado o ilegible dejaba el botón «Sincronizar» deshabilitado para siempre. | Lectura sin `try/catch`; `_isSyncing` sin `finally`. | La fila se marca fallida; `try/finally` en la pantalla. | `test/core/attachments/attachment_upload_service_test.dart` |
| 4 | 2026-08-07 | — | `1b2e5fd` | Adjuntos | Una foto con un fallo de subida transitorio no se reintentaba nunca. | Solo se drenaban filas `pending`. | Se drenan `pending` y `failed`. | `test/core/attachments/attachment_upload_service_test.dart` |
| 5 | 2026-08-07 | — | `ed8f4cc` | Sync / UI | Siempre decía «Sincronización completa», aunque hubiera rechazos, adjuntos fallidos o error de pull. | Se descartaban los informes del ciclo. | Mensaje «incompleta» con los conteos reales. | `test/features/home/home_screen_test.dart` |
| 6 | 2026-08-07 | — | `4ff1e23` | Adjuntos | Riesgo de subir bytes corruptos. | Los bytes se declaraban `List<int>`; Dio solo envía binario crudo si es `Uint8List`. | `Uint8List` explícito de punta a punta. | `test/data/http/attachment_api_client_test.dart` |
| 7 | 2026-10-16 | v0.2.0 | `d664107` | Android / release | El APK de release no llegaba al servidor (sin `INTERNET`), se firmaba con la llave de debug y los datos podían ir a copias en la nube. | Plantilla de `flutter create`. | `INTERNET` en el manifiesto, firma solo con `key.properties`, `allowBackup=false`. | — (guardia: job `android-release` de `mobile.yml`) |
| 8 | 2026-10-17 | v0.3.0 | PR #3 (`041338f`) | Inicio | El temporizador de la pantalla de inicio sobrevivía a la pantalla y al cierre de sesión. | Se usaba `ref` en `dispose()`. | Corregido en el PR del Paso 18. | — |
| 9 | 2026-10-17 | v0.3.0 | PR #4 (`a9007c0`) | Sync / cuarentena | Un conflicto pisaba en silencio la versión del agente; «Reintentar» no podía funcionar nunca. | Conflicto aplicado sin cuarentena; reintento con el mismo `op_uuid`. | Cuarentena con la fila del servidor; `op_uuid` nuevo por reintento ([ADR-0006](../adr/0006-cuarentena-sin-perder-trabajo.md)). | `test/core/sync/quarantine_service_test.dart` |
| 10 | 2026-10-17 | v0.3.0 | PR #8 (`2ed57bf`) | Sesión | Un fallo de red, un 5xx o un certificado rechazado cerraban la sesión: sin cobertura había que volver a iniciar sesión. | Cualquier error del refresh se trataba como sesión inválida. | Solo una familia revocada cierra la sesión. | `test/core/auth/auth_controller_test.dart` (ampliada en el PR; caso exacto no identificado) |
| 11 | 2026-10-17 | v0.4.0 | PR #11 (`99e90fd`) | Build | Las builds publicadas apuntaban a `https://localhost`. | Valor por defecto de `kApiBaseUrl`. | URL de producción por defecto y en las builds de CI. | — |
| 12 | 2026-10-18 | v0.4.0 | PR #19 (`172d328`) | Sync | Si la app se cerraba a mitad de un push, esas operaciones quedaban `inflight` para siempre. | Nada devolvía `inflight` a `pending` al iniciar. | Vuelven a `pending` en el primer drenaje de la sesión (el push es idempotente). | `test/core/capture/record_edit_test.dart` («un envío cortado (inflight) se reenvía en la siguiente sesión») |
| 13 | 2026-10-18 | v0.4.0 | PR #20 (`86fdf2a`) | Sesión | «Cerrar sesión» no cerraba la sesión local si la revocación en el servidor fallaba; el token sobrevivía. | La excepción cortaba el logout. | La sesión local se cierra siempre. | `test/core/auth/session_restore_test.dart` («si revocar en el servidor falla, la sesión del teléfono se cierra igual») |
| 14 | 2026-11-12 | v0.13.1 | PR #44 (`6e91a17`) | Pruebas | `visit_export_test` fallaba en un worktree de git (`PathExistsException`). | Escribía un PDF de QA dentro de `.git`, que en un worktree es un archivo. | Se quitó la escritura; se mantiene la aserción. | `test/core/exports/record_export_test.dart` |

## 2. Defectos encontrados en revisión, antes de integrar

| # | Fecha | PR | Área | Defectos corregidos | Prueba |
|---|---|---|---|---|---|
| 15 | 2026-10-31 | #46 | Captura / cronograma | «Revisión por lotes y revisión final; hallazgos corregidos» (sin detalle en el PR). | — |
| 16 | 2026-11-09 | #53 | UI | Revisión visual: «Añadir registro» dentro de un registro parecía anidado (pasa a «filas»); la tarjeta de «Para revisar» repetía en inglés el mensaje de `record_validated`. | — |
| 17 | 2026-11-11 | #54 | UI | A 390 dp se solapaban las etiquetas flotantes de «Cantidad hoy» y «Nota». | — |

**Sin evidencia de corrección:** la revisión de los PR #36 (C4) y #37 (C5/C6) de la app anotó hallazgos (GPS apagado mostrado como «sin señal», permiso de ubicación pedido otra vez al volver, «Comprobando el GPS…» sin reintento; repetible oculto que bloquea el guardado, errores del servidor en filas que no se limpian, PDF sin GPS con «null, null», GeoJSON que copia todas las respuestas en cada geometría). No consta cuáles se corrigieron antes del merge. Ver [`problemas-conocidos.md`](problemas-conocidos.md).

**Total:** 14 defectos en `master` y 3 grupos de defectos de revisión.
