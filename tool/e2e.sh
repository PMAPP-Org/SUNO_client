#!/usr/bin/env bash
# Prueba E2E de la Fase 0 (Paso 14): una visita creada en modo avión en el
# emulador llega al servidor al reconectar. Procedimiento completo en
# SUNO_server docs/testing/e2e-fase0.md.
#
# Uso: bash tool/e2e.sh
#   SUNO_SERVER_DIR  checkout de SUNO_server (por defecto ../SUNO_server)
#   ANDROID_SERIAL   dispositivo, si hay más de uno conectado
#
# Borra los datos de la app en el emulador (pm clear).
set -euo pipefail

# Git Bash en Windows: no reescribir rutas del contenedor (/data/...) como
# rutas de Windows, y no heredar un CURL_CA_BUNDLE ajeno.
export MSYS_NO_PATHCONV=1
unset CURL_CA_BUNDLE

CLIENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# `pwd -W` (solo Git Bash) da C:/...: docker lo entiende sin conversión.
SERVER_DIR="$(cd "${SUNO_SERVER_DIR:-$CLIENT_DIR/../SUNO_server}" && { pwd -W 2>/dev/null || pwd; })"
PACKAGE=com.visitacampo.visitacampo
HOST=10.0.2.2
RUN_ID="e2e-$(date +%Y%m%d%H%M%S)"
ENV_FILE="$SERVER_DIR/infra/.env.e2e"
WORK="$(cd "$(mktemp -d)" && { pwd -W 2>/dev/null || pwd; })"
COMPOSE=(docker compose -p suno-e2e --project-directory "$SERVER_DIR/infra"
  --env-file "$ENV_FILE" -f "$SERVER_DIR/infra/docker-compose.yml")

# --ssl-no-revoke: el curl de Windows (Schannel) consulta la revocación y la
# CA interna de Caddy no publica CRL; los demás backends lo ignoran.
healthz() {
  curl -sf --ssl-no-revoke --cacert "$WORK/root.crt" --connect-to "$HOST:443:127.0.0.1:443" \
    "https://$HOST/v1/healthz" >/dev/null
}

log() { printf '\n[e2e] %s\n' "$*"; }
die() { printf '\n[e2e] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  local status=$?
  set +e
  adb shell cmd connectivity airplane-mode disable >/dev/null 2>&1
  [[ -n "${LOGCAT_PID:-}" ]] && kill "$LOGCAT_PID" 2>/dev/null
  [[ -n "${TEST_PID:-}" ]] && kill "$TEST_PID" 2>/dev/null
  if [[ $status -ne 0 && -f "$ENV_FILE" ]]; then
    log "Últimas líneas del servidor:"
    "${COMPOSE[@]}" logs --tail 40 api caddy
  fi
  [[ -f "$ENV_FILE" ]] && "${COMPOSE[@]}" down -v >/dev/null 2>&1
  rm -f "$ENV_FILE"
  rm -rf "$WORK"
  if [[ $status -eq 0 ]]; then
    log "OK: la visita $RUN_ID llegó al servidor."
  else
    log "FALLÓ (código $status)."
  fi
}
trap cleanup EXIT

# --- Preflight ---------------------------------------------------------------
command -v docker >/dev/null || die "Falta docker."
docker info >/dev/null 2>&1 || die "Docker no responde: abre Docker Desktop."
command -v flutter >/dev/null || die "Falta flutter en el PATH."
command -v adb >/dev/null || die "Falta adb en el PATH (Android SDK platform-tools)."
command -v openssl >/dev/null || die "Falta openssl (Windows: añade C:\\Program Files\\Git\\usr\\bin al PATH)."
[[ -f "$SERVER_DIR/infra/docker-compose.yml" ]] || die "No encuentro SUNO_server en $SERVER_DIR (usa SUNO_SERVER_DIR)."
adb get-state >/dev/null 2>&1 || die "No hay emulador conectado: emulator -avd suno_api36"
DEVICE="${ANDROID_SERIAL:-$(adb get-serialno | tr -d '\r')}"

# --- Servidor ----------------------------------------------------------------
log "Generando $ENV_FILE"
PASSWORD="$(ENV_FILE="$ENV_FILE" DAST_HOST="$HOST" bash "$SERVER_DIR/infra/scripts/ci_dast_env.sh")"

log "Levantando db, api y caddy (suno-e2e)"
"${COMPOSE[@]}" up -d --build db api caddy

log "Esperando a la API"
for _ in $(seq 1 60); do
  if "${COMPOSE[@]}" exec -T caddy cat /data/caddy/pki/authorities/local/root.crt >"$WORK/root.crt" 2>/dev/null &&
     healthz; then
    break
  fi
  sleep 2
done
healthz || die "La API no respondió en https://$HOST/v1/healthz en 120 s."

log "Sembrando organización y usuario $RUN_ID"
"${COMPOSE[@]}" exec -T api python manage.py bootstrap_demo \
  --org-name "E2E $RUN_ID" --username "$RUN_ID" --email "$RUN_ID@example.com" \
  --password "$PASSWORD" >/dev/null

# --- App -----------------------------------------------------------------------
log "Limpiando los datos de la app en el emulador"
adb shell pm clear "$PACKAGE" >/dev/null 2>&1 || true
adb shell cmd connectivity airplane-mode disable >/dev/null
adb logcat -c

log "Lanzando la prueba de integración"
(
  cd "$CLIENT_DIR"
  # `flutter drive --no-dds` y no `flutter test`: con el emulador API 36 el
  # DDS se cuelga al conectarse justo cuando la app publica su VM service, y
  # `flutter test --no-dds` falla al no poder registrar el stream de goldens.
  flutter drive --no-dds -d "$DEVICE" \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/e2e_fase0_test.dart \
    --dart-define=VISITACAMPO_API_BASE_URL="https://$HOST" \
    --dart-define=E2E_HOST="$HOST" \
    --dart-define=E2E_USERNAME="$RUN_ID" \
    --dart-define=E2E_PASSWORD="$PASSWORD" \
    --dart-define=E2E_MARKER="$RUN_ID"
) >"$WORK/flutter.log" 2>&1 &
TEST_PID=$!

# El modo avión lo controla el script, a la señal de la prueba.
adb logcat -s flutter:I >"$WORK/logcat.log" 2>/dev/null &
LOGCAT_PID=$!
offline=0
while kill -0 "$TEST_PID" 2>/dev/null; do
  if [[ $offline -eq 0 ]] && grep -q 'E2E:READY_FOR_OFFLINE' "$WORK/logcat.log"; then
    log "Modo avión: ON"
    adb shell cmd connectivity airplane-mode enable >/dev/null
    offline=1
  fi
  if [[ $offline -eq 1 ]] && grep -q 'E2E:SAVED_OFFLINE' "$WORK/logcat.log"; then
    log "Modo avión: OFF"
    adb shell cmd connectivity airplane-mode disable >/dev/null
    offline=2
  fi
  sleep 1
done
TEST_STATUS=0
wait "$TEST_PID" || TEST_STATUS=$?
TEST_PID=
tail -n 25 "$WORK/flutter.log"
[[ $TEST_STATUS -eq 0 ]] || die "La prueba de integración falló (log completo arriba)."
grep -q 'E2E:SYNCED' "$WORK/logcat.log" || die "La prueba terminó sin la marca E2E:SYNCED."

# --- Verificación en el servidor ---------------------------------------------
log "Verificando la visita en el servidor"
"${COMPOSE[@]}" exec -T -e E2E_MARKER="$RUN_ID" api python manage.py shell -c '
import os, sys
from visitacampo.core.models import Visit
marker = os.environ["E2E_MARKER"]
visits = list(Visit.objects.filter(answers__notas=marker, deleted_at__isnull=True).select_related("org"))
ok = len(visits) == 1 and visits[0].org.name == f"E2E {marker}" and visits[0].version >= 1 and visits[0].change_seq
for v in visits:
    print(f"visita {v.pk} org={v.org.name!r} version={v.version} change_seq={v.change_seq}")
sys.exit(0 if ok else 1)
' || die "La visita $RUN_ID no está en el servidor como se esperaba."
