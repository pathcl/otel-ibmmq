#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$ROOT/tutorial-miniops-app"

# otel-mq-app dist is always built from the SDK lab; the agent lab references it
# via a relative path in its docker-compose.yml volumes.
PLUGIN_SRC="$ROOT/labs/otel-ibmmq/otel-mq-app"

usage() {
  cat <<EOF
Usage: $0 [command] [mode] [scenario]

Commands:
  up      Start the lab stack (default)
  down    Stop the lab stack
  status  Show container status
  logs    Tail logs from all containers

Modes (optional, default: sdk):
  sdk     Manual OTel SDK — JmsCarrier, explicit inject/extract, full control
  agent   OTel Java Agent — zero-code JMS instrumentation, JAVA_TOOL_OPTIONS

Scenarios (optional, default: middle):
  middle  IBM MQ is in the middle — upstream service owns the trace origin
  origin  IBM MQ gateway is the trace origin — no upstream service
  all     Also start the tutorial Grafana plugin (port 3000) and webpack dev server

Mode and scenario can be given in either order after the command.

Examples:
  $0                       # sdk, middle (lab only)
  $0 up                    # sdk, middle
  $0 up agent              # agent, middle
  $0 up agent middle       # agent, middle (explicit)
  $0 up agent origin       # agent, origin
  $0 up origin             # sdk, origin  (backward-compatible)
  $0 up all                # sdk, middle + tutorial Grafana on port 3000
  $0 up agent all          # agent, middle + tutorial Grafana
  $0 down                  # stop sdk lab
  $0 down agent            # stop agent lab
  $0 down all              # stop sdk lab + tutorial Grafana + webpack

Note: ApiExitLocal (C exit at queue manager level) is not a start.sh mode — it
requires building a C shared library and loading it into IBM MQ manually.
See docs/16-api-exit.md for step-by-step instructions.

EOF
}

# Parse MODE and SCENARIO from remaining positional args (after the command).
# Either can appear in any order; they don't overlap.
parse_mode_scenario() {
  MODE="sdk"
  SCENARIO="middle"
  for arg in "$@"; do
    case "$arg" in
      sdk|agent)   MODE="$arg" ;;
      middle|origin|all) SCENARIO="$arg" ;;
      *) echo "Error: unknown argument '$arg'." >&2; usage; exit 1 ;;
    esac
  done
}

compose_files() {
  if [[ "$SCENARIO" == "origin" ]]; then
    echo "-f $LAB_DIR/docker-compose.yml"
  else
    echo "-f $LAB_DIR/docker-compose.yml -f $LAB_DIR/docker-compose.upstream.yml"
  fi
}

cmd_up() {
  local with_plugin=false
  [[ "$SCENARIO" == "all" ]] && { with_plugin=true; SCENARIO="middle"; }

  echo "==> Building lab plugin (otel-mq-app)"
  cd "$PLUGIN_SRC"
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
  echo "==> Starting lab stack — mode: $MODE  scenario: $SCENARIO"
  if [[ "$SCENARIO" == "origin" ]]; then
    echo "    (gateway is the trace origin)"
  else
    echo "    (upstream → gateway → IBM MQ pipeline)"
  fi

  # shellcheck disable=SC2046
  docker compose $(compose_files) up -d --build

  echo ""
  echo "==> Waiting for IBM MQ (QM1) to be ready..."
  until docker compose -f "$LAB_DIR/docker-compose.yml" exec -T ibmmq \
      dspmq -m QM1 2>/dev/null | grep -q "Running"; do
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
  echo "==> Lab is up [$MODE mode]. IBM MQ takes ~60s to initialise — services retry automatically."
  echo ""
  echo "    Lab Grafana (dashboard):    http://localhost:3001"
  echo "    Lab Prometheus:             http://localhost:9090"
  if $with_plugin; then
    echo "    Tutorial Grafana (plugin):  http://localhost:3000"
  fi
  if [[ "$SCENARIO" == "origin" ]]; then
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
  if [[ "$MODE" == "agent" ]]; then
    echo ""
    echo "    Note: first build downloads the OTel Java agent jar (~60 MB) — Docker caches it."
    echo "    Span names follow JMS semantic conventions (e.g. 'DEV.QUEUE.1 publish') rather"
    echo "    than the custom names used in sdk mode (e.g. 'gateway.send')."
  fi
}

cmd_down() {
  local with_plugin=false
  [[ "$SCENARIO" == "all" ]] && { with_plugin=true; SCENARIO="middle"; }

  if $with_plugin; then
    echo "==> Stopping tutorial Grafana"
    docker compose -f "$PLUGIN_DIR/docker-compose.yaml" down

    if [ -f /tmp/webpack-dev.pid ]; then
      echo "==> Stopping webpack dev server (PID $(cat /tmp/webpack-dev.pid))"
      kill "$(cat /tmp/webpack-dev.pid)" 2>/dev/null || true
      rm -f /tmp/webpack-dev.pid
    fi
  fi

  echo "==> Stopping lab stack [$MODE mode]"
  # shellcheck disable=SC2046
  docker compose $(compose_files) down
}

cmd_status() {
  local with_plugin=false
  [[ "$SCENARIO" == "all" ]] && { with_plugin=true; SCENARIO="middle"; }

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

  echo "==> Lab stack [$MODE mode, $SCENARIO scenario]"
  # shellcheck disable=SC2046
  docker compose $(compose_files) ps
}

cmd_logs() {
  [[ "$SCENARIO" == "all" ]] && SCENARIO="middle"
  echo "==> Tailing lab stack logs — $MODE mode, $SCENARIO scenario (Ctrl+C to stop)"
  # shellcheck disable=SC2046
  docker compose $(compose_files) logs -f
}

# ---------------------------------------------------------------------------
COMMAND="${1:-up}"
shift || true   # consume command; remaining args are mode/scenario

parse_mode_scenario "$@"

# Set LAB_DIR after MODE is resolved.
if [[ "$MODE" == "agent" ]]; then
  LAB_DIR="$ROOT/labs/otel-ibmmq-agent"
else
  LAB_DIR="$ROOT/labs/otel-ibmmq"
fi

case "$COMMAND" in
  up)     cmd_up     ;;
  down)   cmd_down   ;;
  status) cmd_status ;;
  logs)   cmd_logs   ;;
  help|--help|-h) usage ;;
  *) echo "Error: unknown command '$COMMAND'." >&2; usage; exit 1 ;;
esac
