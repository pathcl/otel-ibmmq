#!/usr/bin/env bash
# uninstall.sh — remove otel_exit from the running MQ container.
#
# Reverses install.sh: strips the ApiExitLocal stanza from qm.ini,
# removes the .so, and restarts the container so QM1 loads clean.
#
# Usage:
#   ./labs/otel-ibmmq/api-exit/uninstall.sh

set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$LAB_DIR/docker-compose.yml"

CONTAINER=$(docker compose -f "$COMPOSE_FILE" ps -q ibmmq 2>/dev/null | head -1)
if [[ -z "$CONTAINER" ]]; then
    echo "ERROR: ibmmq container is not running." >&2
    exit 1
fi
CONTAINER_NAME=$(docker inspect --format '{{.Name}}' "$CONTAINER" | sed 's|/||')
echo "==> Found MQ container: $CONTAINER_NAME"

# ── 1. Remove ApiExitLocal stanza from qm.ini ────────────────────────────────
echo ""
echo "==> Removing ApiExitLocal stanza from qm.ini..."
docker exec "$CONTAINER" bash -c '
    INI=/var/mqm/qmgrs/QM1/qm.ini
    if ! grep -q "OtelPropagator" "$INI" 2>/dev/null; then
        echo "    ApiExitLocal stanza not found — nothing to remove"
    else
        python3 -c "
import re, sys
src = open(\"$INI\").read()
src = re.sub(r\"\nApiExitLocal:\n(  [^\n]+\n)+\", \"\", src)
open(\"$INI\", \"w\").write(src)
"
        echo "    Removed ApiExitLocal stanza"
        grep -A4 "ApiExitLocal" "$INI" 2>/dev/null && echo "    WARNING: stanza may still be present" || echo "    Confirmed clean"
    fi
'

# ── 2. Remove the .so ────────────────────────────────────────────────────────
echo ""
echo "==> Removing otel_exit.so..."
docker exec "$CONTAINER" bash -c '
    SO=/var/mqm/exits64/otel_exit.so
    if [[ -f "$SO" ]]; then
        rm -f "$SO"
        echo "    Removed $SO"
    else
        echo "    $SO not found — nothing to remove"
    fi
'

# ── 3. Restart container so QM1 loads without the exit ───────────────────────
echo ""
echo "==> Restarting ibmmq container..."
docker compose -f "$COMPOSE_FILE" restart ibmmq

echo "    Waiting for QM1 to be ready..."
until docker compose -f "$COMPOSE_FILE" exec -T ibmmq dspmq -m QM1 2>/dev/null | grep -q "Running"; do
    sleep 3
done
echo "    QM1 running"

# ── 4. Re-apply PROPCTL (reset by the restart) ───────────────────────────────
echo ""
echo "==> Re-applying PROPCTL(ALL) on pipeline queues..."
docker compose -f "$COMPOSE_FILE" exec -T ibmmq bash -c '
    echo "
ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(ALL)
ALTER QLOCAL(DEV.QUEUE.2) PROPCTL(ALL)
ALTER QLOCAL(DEV.QUEUE.3) PROPCTL(ALL)
ALTER QLOCAL(DEV.DEAD.LETTER.QUEUE) PROPCTL(ALL)
" | runmqsc QM1' 2>/dev/null | grep -E "AMQ|altered" || true

echo ""
echo "==> Done. Exit unloaded — QM1 running clean."
