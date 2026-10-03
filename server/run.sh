#!/usr/bin/env bash
# Build and run the QuizMind server in the background.
#
#   ./run.sh                restart (rebuilds the Go binary first)
#   ./run.sh restart -w     also rebuild the web UIs (make web) first
#   ./run.sh start|stop|status|logs
#
# Environment comes from the shell, then ./.env (e.g. ANTHROPIC_API_KEY=...), and
# QUIZMIND_TOKEN falls back to the contents of ./.token. Neither file is committed.
set -euo pipefail
cd "$(dirname "$0")"

PATTERN='bin/quizmind -config'
LOG=data/quizmind.log
PORT=$(sed -n 's/^listen:[[:space:]]*[^:]*:\([0-9]*\).*/\1/p' config.yaml)
PORT=${PORT:-8080}

running() { pgrep -f "$PATTERN" >/dev/null; }

stop() {
  if ! running; then
    echo "not running"
    return
  fi
  pkill -TERM -f "$PATTERN"
  for _ in $(seq 1 30); do
    running || { echo "stopped"; return; }
    sleep 0.5
  done
  echo "did not stop within 15s; try: pkill -KILL -f '$PATTERN'" >&2
  return 1
}

start() {
  if running; then
    echo "already running (pid $(pgrep -f "$PATTERN" | head -1))"
    return
  fi
  if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
  fi
  if [ -z "${QUIZMIND_TOKEN:-}" ] && [ -f .token ]; then
    QUIZMIND_TOKEN=$(tr -d '\r\n' <.token)
    export QUIZMIND_TOKEN
  fi
  mkdir -p data
  nohup ./bin/quizmind -config config.yaml >>"$LOG" 2>&1 &
  disown
  for _ in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
      ip=$(ipconfig getifaddr en0 2>/dev/null || true)
      echo "started (pid $(pgrep -f "$PATTERN" | head -1)), log: server/$LOG"
      echo "  admin:  http://127.0.0.1:$PORT/"
      echo "  phone:  http://${ip:-<Mac LAN IP>}:$PORT/m/"
      return
    fi
    sleep 0.5
  done
  echo "started but /healthz did not answer; see server/$LOG" >&2
  tail -n 20 "$LOG" >&2 || true
  return 1
}

build() {
  if [ "${1:-}" = "-w" ]; then make web; else make build; fi
}

case "${1:-restart}" in
  start) start ;;
  stop) stop ;;
  status)
    if running; then echo "running (pid $(pgrep -f "$PATTERN" | head -1))"; else echo "not running"; fi
    ;;
  logs) tail -n 50 -f "$LOG" ;;
  restart)
    build "${2:-}"
    stop
    start
    ;;
  *)
    echo "usage: $0 [restart [-w]|start|stop|status|logs]" >&2
    exit 2
    ;;
esac
