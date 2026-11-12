#!/usr/bin/env bash
# Prueba E2E de la Fase 0 (Paso 14): un registro creado en modo avión en el
# emulador llega al servidor al reconectar. Procedimiento completo en
# SUNO_server docs/testing/e2e-fase0.md.
#
# Uso: bash tool/e2e.sh (E2E_FLOW=quantities para la variante de cantidades;
#   E2E_SHOTS=<carpeta> para guardar capturas)
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
PACKAGE=com.suno.app
HOST=10.0.2.2
RUN_ID="e2e-$(date +%Y%m%d%H%M%S)"
# Variante: `fase0` (por defecto: registro con % en modo avión) o `quantities`
# (costos, pieza 4b: cantidades por ítem, validación en el servidor y lo validado en la
# tarea). Con E2E_SHOTS=<carpeta>, guarda las capturas que pida la prueba (E2E:SHOT:…).
FLOW="${E2E_FLOW:-fase0}"
case "$FLOW" in
  fase0) TARGET=integration_test/e2e_fase0_test.dart; SEED_FLAGS=(--with-schedule) ;;
  quantities) TARGET=integration_test/e2e_quantities_test.dart; SEED_FLAGS=(--with-schedule --with-quantities) ;;
  *) echo "E2E_FLOW desconocido: $FLOW (fase0 | quantities)" >&2; exit 2 ;;
esac
SHOTS="${E2E_SHOTS:-}"
[[ -z "$SHOTS" ]] || mkdir -p "$SHOTS"
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
    log "OK ($FLOW): el registro $RUN_ID llegó al servidor con su tarea y su avance."
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
adb get-state >/dev/null 2>&1 ||
  die "No hay un único dispositivo conectado: arranca el emulador (emulator -avd suno_api36) o elige uno con ANDROID_SERIAL."
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

log "Sembrando organización, usuario y tarea del cronograma $RUN_ID"
"${COMPOSE[@]}" exec -T api python manage.py bootstrap_demo \
  --org-name "E2E $RUN_ID" --username "$RUN_ID" --email "$RUN_ID@example.com" \
  --password "$PASSWORD" "${SEED_FLAGS[@]}" >/dev/null

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
    --target="$TARGET" \
    --dart-define=SUNO_API_BASE_URL="https://$HOST" \
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
approved=0
broken=0
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
  if [[ $FLOW == quantities && $approved -eq 0 ]] && grep -q 'E2E:SYNCED' "$WORK/logcat.log"; then
    log "Validando el registro $RUN_ID en el servidor"
    "${COMPOSE[@]}" exec -T -e E2E_MARKER="$RUN_ID" api python manage.py shell -c '
import os
from suno.core.models import Record, RecordReview
record = Record.objects.get(answers__notas=os.environ["E2E_MARKER"], deleted_at__isnull=True)
RecordReview.objects.create(org=record.org, record=record, status="approved", reviewer=record.created_by)
print("registro", record.pk, "validado")
' || die "No se pudo validar el registro $RUN_ID."
    approved=1
  fi
  if [[ $FLOW == quantities && $broken -eq 0 ]] && grep -q 'E2E:BREAK_ITEM' "$WORK/logcat.log"; then
    # Rechazo forzado: el 1.2 pasa a capítulo en la versión aplicada del presupuesto.
    log "Volviendo capítulo el ítem 1.2 (rechazo item_not_in_project)"
    "${COMPOSE[@]}" exec -T -e E2E_MARKER="$RUN_ID" api python manage.py shell -c '
import os
from suno.core.models import BudgetItemVersion
rows = BudgetItemVersion.objects.filter(item__code="1.2", item__budget__project__org__name="E2E " + os.environ["E2E_MARKER"])
print("filas", rows.update(kind="chapter", quantity=None, unit_price=None))
' || die "No se pudo volver capítulo el ítem 1.2."
    broken=1
  fi
  if [[ -n "$SHOTS" ]]; then
    while IFS= read -r shot; do
      [[ -f "$SHOTS/$shot.png" ]] && continue
      adb exec-out screencap -p >"$SHOTS/$shot.png"
      log "Captura: $SHOTS/$shot.png"
    done < <(grep -o 'E2E:SHOT:[a-z0-9-]*' "$WORK/logcat.log" | sed 's/^E2E:SHOT://' | sort -u)
  fi
  sleep 1
done
TEST_STATUS=0
wait "$TEST_PID" || TEST_STATUS=$?
TEST_PID=
tail -n 25 "$WORK/flutter.log"
[[ $TEST_STATUS -eq 0 ]] || die "La prueba de integración falló (log completo arriba)."
grep -q 'E2E:SYNCED' "$WORK/logcat.log" || die "La prueba terminó sin la marca E2E:SYNCED."
if [[ $FLOW == quantities ]]; then
  grep -q 'E2E:VALIDATED_SEEN' "$WORK/logcat.log" || die "La prueba terminó sin ver lo validado en la tarea."
  grep -q 'E2E:CORRECTED' "$WORK/logcat.log" || die "La prueba terminó sin corregir el registro rechazado."
fi

# --- Verificación en el servidor ---------------------------------------------
log "Verificando el registro en el servidor"
if [[ $FLOW == fase0 ]]; then
"${COMPOSE[@]}" exec -T -e E2E_MARKER="$RUN_ID" api python manage.py shell -c '
import os, sys
from decimal import Decimal
from suno.core.models import Record
marker = os.environ["E2E_MARKER"]
records = list(Record.objects.filter(answers__notas=marker, deleted_at__isnull=True).select_related("org", "task"))
ok = (
    len(records) == 1
    and records[0].org.name == f"E2E {marker}"
    and records[0].version >= 1
    and records[0].change_seq
    and records[0].task is not None
    and records[0].task.wbs == "1.1"
    and records[0].progress_pct == Decimal("35")
)
for v in records:
    print(f"registro {v.pk} org={v.org.name!r} version={v.version} change_seq={v.change_seq} tarea={v.task} avance={v.progress_pct}")
sys.exit(0 if ok else 1)
' || die "El registro $RUN_ID no está en el servidor como se esperaba (con la tarea 1.1 al 35 %)."
else
  "${COMPOSE[@]}" exec -T -e E2E_MARKER="$RUN_ID" api python manage.py shell -c '
import os, sys
from suno.core.models import Record, RecordReview
marker = os.environ["E2E_MARKER"]
records = list(Record.objects.filter(answers__notas=marker, deleted_at__isnull=True).select_related("task"))
rows = records[0].quantities if len(records) == 1 else []
ok = (
    len(records) == 1
    and records[0].task is not None
    and records[0].task.wbs == "1.1"
    and records[0].progress_pct is None
    and [r["quantity"] for r in rows] == ["12.5000", "3.0000"]
    and all(r.get("client_id") and r.get("captured_at") and r.get("location_mode") == "task" for r in rows)
    and rows[1]["note"] == "sobrante E2E"
    and RecordReview.objects.filter(record=records[0], status="approved").exists()
)
for r in rows:
    print("fila", r["item_id"], r["quantity"], repr(r["note"]), r.get("location_mode"), "gps" if r.get("gps") else "sin gps")
sys.exit(0 if ok else 1)
' || die "El registro $RUN_ID no está en el servidor como se esperaba (12,5 y 3 m3, validado)."
  log "Verificando el registro rechazado y corregido"
  "${COMPOSE[@]}" exec -T -e E2E_MARKER="$RUN_ID" api python manage.py shell -c '
import os, sys
from suno.core.models import BudgetItem, Record
marker = os.environ["E2E_MARKER"] + "-r"
records = list(Record.objects.filter(answers__notas=marker, deleted_at__isnull=True))
rows = records[0].quantities if len(records) == 1 else []
codes = {str(i.pk): i.code for i in BudgetItem.objects.filter(pk__in=[r["item_id"] for r in rows])}
ok = (
    len(records) == 1
    and [(codes.get(r["item_id"]), r["quantity"], r["note"]) for r in rows] == [("1.1", "2.0000", "rechazo E2E")]
    and all(r.get("client_id") for r in rows)
)
for r in rows:
    print("fila corregida", codes.get(r["item_id"]), r["quantity"], repr(r["note"]))
sys.exit(0 if ok else 1)
' || die "El registro corregido $RUN_ID-r no está en el servidor con su fila en el 1.1."
fi
