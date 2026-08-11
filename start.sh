#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$ROOT/tutorial-miniops-app"
LAB_DIR="$ROOT/labs/otel-ibmmq"

usage() {
  cat <<EOF
Usage: $0 [command] [scenario|all]

Commands:
  up      Start the lab stack (default)
  down    Stop the lab stack
  status  Show container status
  logs    Tail logs from all containers

Scenarios (optional second argument):
  middle  IBM MQ is in the middle — upstream service owns the trace origin (default)
  origin  IBM MQ gateway is the trace origin — no upstream service
  all     Also start the tutorial Grafana plugin (port 3000) and webpack dev server

Examples:
  $0              # same as: $0 up middle  (lab only)
  $0 up           # same as: $0 up middle
  $0 up all       # full stack including tutorial Grafana on port 3000
  $0 up origin    # beginning-of-chain scenario (lab only)
  $0 down         # stop the lab
  $0 down all     # stop lab + tutorial Grafana + webpack

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

start_tutorial_plugin() {
  echo ""
  echo "==> Building tutorial plugin (tutorial-miniops-app)"
  cd "$PLUGIN_DIR"
  npm ci
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
}

stop_tutorial_plugin() {
  echo "==> Stopping tutorial Grafana"
  docker compose -f "$PLUGIN_DIR/docker-compose.yaml" down

  if [ -f /tmp/webpack-dev.pid ]; then
    echo "==> Stopping webpack dev server (PID $(cat /tmp/webpack-dev.pid))"
    kill "$(cat /tmp/webpack-dev.pid)" 2>/dev/null || true
    rm -f /tmp/webpack-dev.pid
  fi
}

cmd_up() {
  local scenario="${1:-middle}"
  local with_plugin=false
  [[ "$scenario" == "all" ]] && { with_plugin=true; scenario="middle"; }

  echo "==> Building lab plugin (otel-mq-app)"
  cd "$LAB_DIR/otel-mq-app"
  npm ci
  npm run build

  if $with_plugin; then
    echo ""
    echo "==> Building tutorial plugin (tutorial-miniops-app)"
    cd "$PLUGIN_DIR"
    npm ci
    npm run build
  fi

  echo ""
  if [[ "$scenario" == "origin" ]]; then
    echo "==> Starting lab stack — origin scenario (gateway is the trace origin)"
  else
    echo "==> Starting lab stack — middle-of-chain scenario (upstream → gateway → IBM MQ pipeline)"
  fi

  # shellcheck disable=SC2046
  docker compose $(compose_files "$scenario") up -d --build

  echo ""
  echo "==> Waiting for IBM MQ (QM1) to be ready..."
  until docker compose -f "$LAB_DIR/docker-compose.yml" exec -T ibmmq dspmq -m QM1 2>/dev/null | grep -q "Running"; do
    sleep 3
  done
  echo "    QM1 running — applying PROPCTL(ALL) on pipeline queues"
  docker compose -f "$LAB_DIR/docker-compose.yml" exec -T ibmmq bash -c '
    echo "
ALTER QLOCAL(DEV.QUEUE.1) PROPCTL(ALL)
ALTER QLOCAL(DEV.QUEUE.2) PROPCTL(ALL)
ALTER QLOCAL(DEV.QUEUE.3) PROPCTL(ALL)
ALTER QLOCAL(DEV.DEAD.LETTER.QUEUE) PROPCTL(ALL)
" | runmqsc QM1' 2>/dev/null | grep -E "AMQ|altered" || true
  echo "    PROPCTL(ALL) applied"

  if $with_plugin; then
    echo ""
    echo "==> Starting tutorial Grafana (port 3000)"
    docker compose -f "$PLUGIN_DIR/docker-compose.yaml" up -d

    echo ""
    echo "==> Starting webpack dev server (logs: /tmp/webpack-dev.log)"
    cd "$PLUGIN_DIR"
    npm run dev > /tmp/webpack-dev.log 2>&1 &
    echo $! > /tmp/webpack-dev.pid
    echo "    PID: $(cat /tmp/webpack-dev.pid)"
  fi

  echo ""
  echo "==> Lab is up. IBM MQ takes ~60s to initialise — the Java services retry automatically."
  echo ""
  echo "    Lab Grafana (dashboard):    http://localhost:3001"
  echo "    Lab Prometheus:             http://localhost:9090"
  if $with_plugin; then
    echo "    Tutorial Grafana (plugin):  http://localhost:3000"
  fi
  if [[ "$scenario" == "origin" ]]; then
    echo "    Gateway (trace origin):     http://localhost:8080"
    echo ""
    echo "Send a test message (gateway is the entry point):"
    echo "    curl -X POST http://localhost:8080/send -H 'X-bsi-ep: checkout' -H 'X-bsi-ch: android' -H 'X-bsi-cj: MoneyTransfer'"
  else
    echo "    Upstream (trace origin):    http://localhost:8081"
    echo "    Gateway (MQ bridge):        http://localhost:8080"
    echo ""
    echo "Send a test message (enters at upstream — full middle-of-chain trace):"
    echo "    curl -X POST http://localhost:8081/order -H 'X-bsi-ep: checkout' -H 'X-bsi-ch: android' -H 'X-bsi-cj: MoneyTransfer'"
  fi
  echo "    IBM MQ console:             https://localhost:9443  (admin / passw0rd)"
}

cmd_down() {
  local scenario="${1:-middle}"
  local with_plugin=false
  [[ "$scenario" == "all" ]] && { with_plugin=true; scenario="middle"; }

  if $with_plugin; then
    echo "==> Stopping tutorial Grafana"
    docker compose -f "$PLUGIN_DIR/docker-compose.yaml" down

    if [ -f /tmp/webpack-dev.pid ]; then
      echo "==> Stopping webpack dev server (PID $(cat /tmp/webpack-dev.pid))"
      kill "$(cat /tmp/webpack-dev.pid)" 2>/dev/null || true
      rm -f /tmp/webpack-dev.pid
    fi
  fi

  echo "==> Stopping lab stack"
  # shellcheck disable=SC2046
  docker compose $(compose_files "$scenario") down
}

cmd_status() {
  local scenario="${1:-middle}"
  local with_plugin=false
  [[ "$scenario" == "all" ]] && { with_plugin=true; scenario="middle"; }

  if $with_plugin; then
    echo "==> Tutorial stack"
    docker compose -f "$PLUGIN_DIR/docker-compose.yaml" ps
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
    echo ""
  fi

  echo "==> Lab stack ($scenario scenario)"
  # shellcheck disable=SC2046
  docker compose $(compose_files "$scenario") ps
}

cmd_logs() {
  local scenario="${1:-middle}"
  [[ "$scenario" == "all" ]] && scenario="middle"
  echo "==> Tailing lab stack logs — $scenario scenario (Ctrl+C to stop)"
  # shellcheck disable=SC2046
  docker compose $(compose_files "$scenario") logs -f
}

COMMAND="${1:-up}"
SCENARIO="${2:-middle}"

if [[ "$SCENARIO" != "middle" && "$SCENARIO" != "origin" && "$SCENARIO" != "all" ]]; then
  echo "Error: unknown scenario '$SCENARIO'. Use 'middle', 'origin', or 'all'." >&2
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
