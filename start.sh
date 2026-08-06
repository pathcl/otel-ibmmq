#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$ROOT/tutorial-miniops-app"
LAB_DIR="$ROOT/labs/otel-ibmmq"

usage() {
  cat <<EOF
Usage: $0 [command]

Commands:
  up      Start everything (default)
  down    Stop everything
  status  Show container status
  logs    Tail logs from all containers

EOF
}

cmd_up() {
  echo "==> Starting lab stack (IBM MQ + OTel Collector + Tempo + Prometheus + Grafana:3001)"
  docker-compose -f "$LAB_DIR/docker-compose.yml" up -d --build

  echo ""
  echo "==> Building tutorial plugin"
  cd "$PLUGIN_DIR"
  npm run build

  echo ""
  echo "==> Starting tutorial Grafana (port 3000)"
  docker-compose -f "$PLUGIN_DIR/docker-compose.yaml" up -d

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
  echo "    Gateway (send messages):    http://localhost:8080"
  echo "    IBM MQ console:             https://localhost:9443  (admin / passw0rd)"
  echo ""
  echo "Send a test message:"
  echo "    curl -X POST http://localhost:8080/send -H 'X-Tenant-ID: acme' -H 'X-User-ID: user1'"
}

cmd_down() {
  echo "==> Stopping tutorial Grafana"
  docker-compose -f "$PLUGIN_DIR/docker-compose.yaml" down

  echo "==> Stopping lab stack"
  docker-compose -f "$LAB_DIR/docker-compose.yml" down

  if [ -f /tmp/webpack-dev.pid ]; then
    echo "==> Stopping webpack dev server (PID $(cat /tmp/webpack-dev.pid))"
    kill "$(cat /tmp/webpack-dev.pid)" 2>/dev/null || true
    rm -f /tmp/webpack-dev.pid
  fi
}

cmd_status() {
  echo "==> Tutorial stack"
  docker-compose -f "$PLUGIN_DIR/docker-compose.yaml" ps
  echo ""
  echo "==> Lab stack"
  docker-compose -f "$LAB_DIR/docker-compose.yml" ps
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
  echo "==> Tailing lab stack logs (Ctrl+C to stop)"
  docker-compose -f "$LAB_DIR/docker-compose.yml" logs -f
}

case "${1:-up}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  logs)   cmd_logs ;;
  *)      usage; exit 1 ;;
esac
