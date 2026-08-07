#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$ROOT/tutorial-miniops-app"
LAB_DIR="$ROOT/labs/otel-ibmmq"

usage() {
  cat <<EOF
Usage: $0 [command] [scenario]

Commands:
  up      Start everything (default)
  down    Stop everything
  status  Show container status
  logs    Tail logs from all containers

Scenarios (optional second argument):
  middle  IBM MQ is in the middle — upstream service owns the trace origin (default)
  origin  IBM MQ gateway is the trace origin — no upstream service

Examples:
  $0              # same as: $0 up middle
  $0 up           # same as: $0 up middle
  $0 up origin    # beginning-of-chain scenario
  $0 down origin  # stop the beginning-of-chain stack

EOF
}

# Build the list of compose files for the chosen scenario.
# middle: base stack + upstream override
# origin: base stack only
compose_files() {
  local scenario="${1:-middle}"
  if [[ "$scenario" == "origin" ]]; then
    echo "-f $LAB_DIR/docker-compose.yml"
  else
    echo "-f $LAB_DIR/docker-compose.yml -f $LAB_DIR/docker-compose.upstream.yml"
  fi
}

cmd_up() {
  local scenario="${1:-middle}"
  # shellcheck disable=SC2046
  if [[ "$scenario" == "origin" ]]; then
    echo "==> Starting lab stack — origin scenario (gateway is the trace origin)"
  else
    echo "==> Starting lab stack — middle-of-chain scenario (upstream → gateway → IBM MQ pipeline)"
  fi

  docker compose $(compose_files "$scenario") up -d --build

  echo ""
  echo "==> Building tutorial plugin"
  cd "$PLUGIN_DIR"
  npm run build

  echo ""
  echo "==> Starting tutorial Grafana (port 3000)"
  docker compose -f "$PLUGIN_DIR/docker-compose.yaml" up -d

  echo ""
  echo "==> Starting webpack dev server (logs: /tmp/webpack-dev.log)"
  cd "$PLUGIN_DIR"
  npm run dev > /tmp/webpack-dev.log 2>&1 &
  echo $! > /tmp/webpack-dev.pid
  echo "    PID: $(cat /tmp/webpack-dev.pid)"

  echo ""
  echo "==> Everything is up. IBM MQ takes ~60s to initialise — the Java services retry automatically."
  echo ""
  echo "    Tutorial Grafana (plugin):  http://localhost:3000"
  echo "    Lab Grafana (dashboard):    http://localhost:3001"
  echo "    Lab Prometheus:             http://localhost:9090"
  if [[ "$scenario" == "origin" ]]; then
    echo "    Gateway (trace origin):     http://localhost:8080"
    echo ""
    echo "Send a test message (gateway is the entry point):"
    echo "    curl -X POST http://localhost:8080/send -H 'X-Tenant-ID: acme' -H 'X-User-ID: user1'"
  else
    echo "    Upstream (trace origin):    http://localhost:8081"
    echo "    Gateway (MQ bridge):        http://localhost:8080"
    echo ""
    echo "Send a test message (enters at upstream — full middle-of-chain trace):"
    echo "    curl -X POST http://localhost:8081/order -H 'X-Tenant-ID: acme' -H 'X-User-ID: user1'"
  fi
  echo "    IBM MQ console:             https://localhost:9443  (admin / passw0rd)"
}

cmd_down() {
  local scenario="${1:-middle}"
  echo "==> Stopping tutorial Grafana"
  docker compose -f "$PLUGIN_DIR/docker-compose.yaml" down

  echo "==> Stopping lab stack"
  docker compose $(compose_files "$scenario") down

  if [ -f /tmp/webpack-dev.pid ]; then
    echo "==> Stopping webpack dev server (PID $(cat /tmp/webpack-dev.pid))"
    kill "$(cat /tmp/webpack-dev.pid)" 2>/dev/null || true
    rm -f /tmp/webpack-dev.pid
  fi
}

cmd_status() {
  local scenario="${1:-middle}"
  echo "==> Tutorial stack"
  docker compose -f "$PLUGIN_DIR/docker-compose.yaml" ps
  echo ""
  echo "==> Lab stack ($scenario scenario)"
  docker compose $(compose_files "$scenario") ps
  echo ""
  if [ -f /tmp/webpack-dev.pid ]; then
    PID=$(cat /tmp/webpack-dev.pid)
    if kill -0 "$PID" 2>/dev/null; then
      echo "==> webpack dev server running (PID $PID)"
    else
      echo "==> webpack dev server NOT running (stale PID $PID)"
    fi
  else
    echo "==> webpack dev server not started"
  fi
}

cmd_logs() {
  local scenario="${1:-middle}"
  echo "==> Tailing lab stack logs — $scenario scenario (Ctrl+C to stop)"
  docker compose $(compose_files "$scenario") logs -f
}

COMMAND="${1:-up}"
SCENARIO="${2:-middle}"

if [[ "$SCENARIO" != "middle" && "$SCENARIO" != "origin" ]]; then
  echo "Error: unknown scenario '$SCENARIO'. Use 'middle' or 'origin'." >&2
  usage
  exit 1
fi

case "$COMMAND" in
  up)     cmd_up     "$SCENARIO" ;;
  down)   cmd_down   "$SCENARIO" ;;
  status) cmd_status "$SCENARIO" ;;
  logs)   cmd_logs   "$SCENARIO" ;;
  *)      usage; exit 1 ;;
esac
