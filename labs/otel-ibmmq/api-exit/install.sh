#!/usr/bin/env bash
# install.sh — compile and install otel_exit.so into the running MQ container.
#
# Changes survive container restarts (written to the /var/mqm Docker volume).
# Changes are lost only if the volume is destroyed (docker compose down -v).
#
# Usage:
#   ./labs/otel-ibmmq/api-exit/install.sh
#
# The lab must be running (./start.sh) before calling this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="$LAB_DIR/docker-compose.yml"

# Resolve the container name dynamically
CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps -q ibmmq 2>/dev/null | head -1)
if [[ -z "$CONTAINER" ]]; then
    echo "ERROR: ibmmq container is not running. Start the lab first: ./start.sh" >&2
    exit 1
fi
CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$CONTAINER" | sed 's|/||')
echo "==> Found MQ container: $CONTAINER_NAME"

# ── 1. Install gcc if not present ────────────────────────────────────────────
echo ""
echo "==> Checking build tools..."
if ! docker exec "$CONTAINER" which gcc &>/dev/null; then
    echo "    gcc not found — installing..."
    docker exec -u root "$CONTAINER" bash -c \
        'apt-get update -qq && apt-get install -y --no-install-recommends gcc 2>&1 | tail -3'
else
    echo "    gcc already present"
fi

# ── 2. Compile the exit ───────────────────────────────────────────────────────
echo ""
echo "==> Compiling otel_exit.so..."
docker cp "$SCRIPT_DIR/otel_exit.c" "$CONTAINER:/tmp/otel_exit.c"
docker exec -u root "$CONTAINER" bash -c '
    mkdir -p /var/mqm/exits64
    gcc -fPIC -shared -O2 \
        -I/opt/mqm/inc \
        -o /var/mqm/exits64/otel_exit.so \
        /tmp/otel_exit.c \
        -L/opt/mqm/lib64 -lmqm_r -Wl,-rpath,/opt/mqm/lib64
    chown mqm:mqm /var/mqm/exits64/otel_exit.so
    chmod 755    /var/mqm/exits64/otel_exit.so
    rm /tmp/otel_exit.c
'
echo "    $(docker exec "$CONTAINER" ls -lh /var/mqm/exits64/otel_exit.so)"

# ── 3. Patch qm.ini (idempotent) ─────────────────────────────────────────────
echo ""
echo "==> Patching qm.ini..."
docker exec "$CONTAINER" bash -c '
    INI=/var/mqm/qmgrs/QM1/qm.ini
    if grep -q "OtelPropagator" "$INI" 2>/dev/null; then
        echo "    ApiExitLocal already configured in qm.ini"
    else
        printf "\nApiExitLocal:\n  Name=OtelPropagator\n  Module=/var/mqm/exits64/otel_exit\n  Function=OtelExitInit\n  Sequence=1\n" >> "$INI"
        echo "    Added ApiExitLocal stanza to qm.ini"
    fi
    grep -A4 "ApiExitLocal" "$INI"
'

# ── 4. Restart the container so QM1 loads the exit ───────────────────────────
echo ""
echo "==> Restarting ibmmq container (QM1 will pick up the exit on startup)..."
docker compose -f "$COMPOSE_FILE" restart ibmmq

echo "    Waiting for QM1 to be ready..."
until docker compose -f "$COMPOSE_FILE" exec -T ibmmq dspmq -m QM1 2>/dev/null | grep -q "Running"; do
    sleep 3
done
echo "    QM1 running"

# ── 5. Re-apply PROPCTL (reset by the restart) ───────────────────────────────
echo ""
echo "==> Re-applying PROPCTL(ALL) on pipeline queues..."
docker compose -f "$COMPOSE_FILE" exec -T ibmmq bash -c '
    echo "
ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(ALL)
ALTER QLOCAL(DEV.QUEUE.2) PROPCTL(ALL)
ALTER QLOCAL(DEV.QUEUE.3) PROPCTL(ALL)
ALTER QLOCAL(DEV.DEAD.LETTER.QUEUE) PROPCTL(ALL)
" | runmqsc QM1' 2>/dev/null | grep -E "AMQ|altered" || true

# ── 6. Verify the exit loaded ────────────────────────────────────────────────
echo ""
echo "==> Verifying exit is active..."
docker compose -f "$COMPOSE_FILE" exec -T ibmmq bash -c \
    'echo "DISPLAY QMGR APIEXITL" | runmqsc QM1' 2>/dev/null | grep -i "APIEXITL" || true

echo ""
echo "==> Done. Watch exit output:"
echo "    docker logs -f $CONTAINER_NAME 2>&1 | grep otel-exit"
echo ""
echo "==> Send a message to trigger inject:"
echo "    curl -X POST http://localhost:8081/order -H 'X-bsi-ep: checkout' -H 'X-bsi-ch: android' -H 'X-bsi-cj: MoneyTransfer'"
