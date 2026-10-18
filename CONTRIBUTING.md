# Contribuir a SUNO_client

## Regla obligatoria: nada está terminado sin su CI en verde

Este repositorio sigue el plan de construcción de VisitaCampo ([`PMAPP-Org/SUNO_server` → `plans/`](https://github.com/PMAPP-Org/SUNO_server/tree/master/plans)). Un cambio no está completo si su CI no pasa. Desactivar o vaciar un job "para que pase" cuenta como no hacerlo.

## Cómo ejecutar los checks en local

```bash
flutter pub get --enforce-lockfile
dart run build_runner build --delete-conflicting-outputs
dart analyze
flutter test --concurrency=1 --coverage
python3 tool/check_lcov.py coverage/lcov.info --min 75
bash tool/lint_no_tls_bypass.sh
bash tool/lint_ui_tokens.sh
bash tool/lint_no_dynamic_code.sh
```

`--concurrency=1` evita los cuelgues del VM de Dart con el fixture TLS autofirmado (validado en el Paso 13).

## Gates de CI

| Gate | Workflow | Control ISO 27001 |
|---|---|---|
| `dart analyze` estricto (`strict-casts`, `strict-inference`, `strict-raw-types`) | `mobile.yml` | A.8.28 |
| `flutter test` y suelo de cobertura del 75 % | `mobile.yml` | A.8.29 |
| APK de release firmado, no con la clave de debug, y con permiso `INTERNET` | `mobile.yml` | A.8.32 |
| SBOM CycloneDX y SPDX | `mobile.yml`, `release.yml` | A.8.8 |
| Lint RD-01: sin bypass de TLS fuera de `TrustStore` | `mobile.yml` | A.8.24 |
| Lint de sistema de diseño (sin colores, estilos, medidas ni textos sueltos en pantallas) | `mobile.yml` | — |
| Lint RD-06: sin ejecución dinámica de código | `mobile.yml` | A.8.28 |
| Contrato idéntico al del servidor en el commit fijado | `contract.yml` | A.8.25 |
| `gitleaks` sobre todo el historial | `security.yml` | A.8.4, A.8.12 |
| `osv-scanner` sobre `pubspec.lock` (también semanal) | `security.yml` | A.8.8 |
| Semgrep (secretos, auditoría, Actions) y `actionlint` | `security.yml` | A.8.28 |
| CodeQL sobre los workflows | `codeql.yml` | A.8.28 |
| Dependency Review (CVE y licencias de dependencias nuevas) | `dependency-review.yml` | A.8.8 |
| Título del PR en Conventional Commits | `pr-title.yml` | A.8.32 |

**Falsos positivos:** se suprimen solo por identificador exacto y con la justificación al lado: huella exacta en `.gitleaksignore`, `# nosemgrep: <regla>` para Semgrep. Nunca se desactiva una regla entera. Una vulnerabilidad que se **acepta** (no un falso positivo) se registra en el [registro de excepciones del SGSI](https://github.com/PMAPP-Org/SUNO_server/blob/master/docs/seguridad/excepciones.md), con fecha de caducidad.

**Actions de GitHub:** se referencian por SHA de commit, con la versión en un comentario (`uses: actions/checkout@<sha> # v7.0.1`). Dependabot actualiza ambos a la vez.

## El gate RD-01 (sin bypass de TLS)

Hallazgo **crítico** de la revisión de la arquitectura de referencia: QField aceptaba certificados TLS inválidos sin condiciones. Aquí está prohibido.

`tool/lint_no_tls_bypass.sh` falla si aparece `badCertificateCallback`, `onBadCertificate`, `connectionFactory`, `allowBadCertificates`, `ignoreSslErrors` o `ignoreCertificateErrors` en cualquier `.dart` fuera de `lib/core/security/trust_store.dart` (o de `lib/core/security/trust_store/`). Ese es el módulo `TrustStore` auditado del Paso 16: solo HTTPS, pinning SPKI para el servidor oficial y TOFU con consentimiento explícito para los autohospedados, verificando el certificado antes de enviar la petición. Un cambio en ese módulo exige la misma revisión que el Paso 16.

Ante un falso positivo, se ajusta el script en un PR. **Nunca se elimina el gate.**

## Sistema de diseño

Las pantallas (`lib/features/`) no deciden cómo se ven: lo decide el tema. `tool/lint_ui_tokens.sh` falla si una pantalla escribe un color, un estilo de texto, una medida o un texto literal.

| Necesito… | Dónde | Cómo se usa |
|---|---|---|
| Un color | `lib/ui/theme/app_colors.dart` (único sitio con colores literales) | `Theme.of(context).colorScheme.primary`; estados con `context.statusColors.warning` |
| Un espaciado o tamaño | `lib/ui/theme/app_tokens.dart` | `AppSpacing.md`, `const AppGap.sm()`, `AppSizes.minTouchTarget` |
| Un estilo de texto | El `textTheme` de Material 3 | `Theme.of(context).textTheme.titleMedium` |
| Un texto visible | `lib/l10n/app_es.arb` | `context.l10n.loginSubmit`, con plurales ICU |
| Un botón con carga | `lib/ui/widgets/app_button.dart` | `AppButton(label:, isLoading:, loadingLabel:)` |
| Una pantalla con formulario | `lib/ui/widgets/app_page_body.dart` | `AppPageBody(children: …)` |

## Base de datos local

Todo cambio de esquema Drift sube `schemaVersion` en `lib/data/local/database.dart` y lleva su test de migración N-1→N con datos de ejemplo en `test/data/local/migration_test.dart`. **Ninguna migración destructiva sin ese test.**

## Contrato con el servidor

`contract/` es una copia fijada del contrato del servidor y no se edita a mano. Para actualizarla, sigue [`contract/README.md`](contract/README.md).

## Firma de releases Android

El APK de release se firma con la llave de subida de `android/key.properties` (`storeFile`, `keyAlias`, `storePassword`, `keyPassword`) y el `.jks` al que apunta. **Ninguno de los dos se versiona**, y deben guardarse en un gestor de secretos con copia de seguridad: perder la llave obliga a un proceso de recuperación con Google Play.

Sin `key.properties`, `flutter build apk --release` falla a propósito en vez de firmar con la clave de debug. El job `android-release` lo comprueba en cada PR con una llave efímera.

## Releases

El versionado lo lleva [release-please](https://github.com/googleapis/release-please) (`.github/workflows/release.yml`) a partir de [Conventional Commits](https://www.conventionalcommits.org/):
- `feat:` sube la versión menor;
- `fix:` sube el parche;
- `feat!:` o `BREAKING CHANGE:` sube la mayor (antes de 1.0, la menor).

Los PR se integran con **Squash and merge**, y su título es el mensaje del commit.

1. Cada push a `master` actualiza el PR `chore: release X.Y.Z`, con el CHANGELOG y la versión nueva en `version.txt`, `pubspec.yaml` y `lib/core/constants.dart`.
2. Mergear ese PR crea el tag `vX.Y.Z` y la GitHub Release, con el SBOM de la app.
3. Si existen los secretos, la release lleva además el APK firmado, su checksum y su atestación de procedencia (`gh attestation verify`).

**Configuración de una sola vez (admin):**
- *Settings → Actions → Allow GitHub Actions to create and approve pull requests*.
- Environment `release`, restringido a `master`, con los secretos:
  - `ANDROID_UPLOAD_KEYSTORE_B64` (el `.jks` en base64);
  - `ANDROID_UPLOAD_KEY_ALIAS`;
  - `ANDROID_UPLOAD_KEYSTORE_PASSWORD`;
  - `ANDROID_UPLOAD_KEY_PASSWORD`;
  - opcionalmente, `RELEASE_PLEASE_TOKEN`.
