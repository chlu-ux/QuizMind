#!/usr/bin/env bash
# Build and run the QuizMind server.
#
#   ./run.sh                restart (rebuilds the Go binary first)
#   ./run.sh restart -w     also rebuild the web UIs (make web) first
#   ./run.sh start|stop|status|logs
#
# Start at login and restart after a crash (macOS launchd):
#   ./run.sh install        build, then register ~/Library/LaunchAgents/com.quizmind.server.plist
#   ./run.sh uninstall      remove it again
#   ./run.sh serve          run in the foreground (what launchd runs; handy for debugging)
#   ./run.sh plist          print the launch agent that install would write
#
# Once installed, start/stop/restart/status/logs talk to launchd instead of a
# nohup'd background process; logs go to ~/Library/Logs/quizmind/.
#
# Environment comes from the shell, then ./.env (e.g. ANTHROPIC_API_KEY=...), and
# QUIZMIND_TOKEN falls back to the contents of ./.token. Neither file is committed;
# neither ends up in the plist.
set -euo pipefail
cd "$(dirname "$0")"
DIR=$(pwd)

PATTERN='bin/quizmind -config'
LABEL=com.quizmind.server
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LAUNCHD_LOGDIR="$HOME/Library/Logs/quizmind"
LOG=data/quizmind.log
PORT=$(sed -n 's/^listen:[[:space:]]*[^:]*:\([0-9]*\).*/\1/p' config.yaml)
PORT=${PORT:-8080}

running() { pgrep -f "$PATTERN" >/dev/null; }
installed() { [ -f "$PLIST" ]; }
loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

load_env() {
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
}

wait_gone() {
  for _ in $(seq 1 30); do
    running || return 0
    sleep 0.5
  done
  return 1
}

stop() {
  if installed && loaded; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    wait_gone && { echo "stopped (launchd)"; return; }
    echo "did not stop within 15s; try: pkill -KILL -f '$PATTERN'" >&2
    return 1
  fi
  if ! running; then
    echo "not running"
    return
  fi
  pkill -TERM -f "$PATTERN"
  wait_gone && { echo "stopped"; return; }
  echo "did not stop within 15s; try: pkill -KILL -f '$PATTERN'" >&2
  return 1
}

wait_healthy() {
  for _ in $(seq 1 20); do
    if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
      ip=$(ipconfig getifaddr en0 2>/dev/null || true)
      echo "  admin:  http://127.0.0.1:$PORT/"
      echo "  phone:  http://${ip:-<Mac LAN IP>}:$PORT/m/"
      return 0
    fi
    sleep 0.5
  done
  return 1
}

start() {
  if running; then
    echo "already running (pid $(pgrep -f "$PATTERN" | head -1))"
    return
  fi
  if installed; then
    loaded || launchctl bootstrap "$DOMAIN" "$PLIST"
    if wait_healthy; then
      echo "started (launchd, pid $(pgrep -f "$PATTERN" | head -1)), logs: $LAUNCHD_LOGDIR"
      return
    fi
    echo "started but /healthz did not answer; see $LAUNCHD_LOGDIR/server.err.log" >&2
    tail -n 20 "$LAUNCHD_LOGDIR/server.err.log" >&2 || true
    return 1
  fi
  load_env
  mkdir -p data
  nohup ./bin/quizmind -config config.yaml >>"$LOG" 2>&1 &
  disown
  if wait_healthy; then
    echo "started (pid $(pgrep -f "$PATTERN" | head -1)), log: server/$LOG"
    return
  fi
  echo "started but /healthz did not answer; see server/$LOG" >&2
  tail -n 20 "$LOG" >&2 || true
  return 1
}

build() {
  if [ "${1:-}" = "-w" ]; then make web; else make build; fi
}

# The command launchd runs: environment from .env/.token, then the server in the
# foreground (exec, so launchd supervises the server itself).
serve() {
  load_env
  mkdir -p data
  exec ./bin/quizmind -config config.yaml
}

render_plist() {
  cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DIR/run.sh</string>
    <string>serve</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$DIR</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>$LAUNCHD_LOGDIR/server.log</string>
  <key>StandardErrorPath</key>
  <string>$LAUNCHD_LOGDIR/server.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
PLIST_EOF
}

write_plist() {
  mkdir -p "$(dirname "$PLIST")" "$LAUNCHD_LOGDIR"
  render_plist >"$PLIST"
  plutil -lint "$PLIST" >/dev/null
}

install_agent() {
  build "${1:-}"
  # A background process started by an earlier "./run.sh start" would hold the port.
  if ! (installed && loaded) && running; then
    echo "stopping the running background server first"
    pkill -TERM -f "$PATTERN"
    wait_gone || { echo "could not stop it" >&2; return 1; }
  fi
  loaded && launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  write_plist
  echo "wrote $PLIST"
  launchctl bootstrap "$DOMAIN" "$PLIST"
  if wait_healthy; then
    echo "installed: the server now starts at login and restarts if it crashes (logs: $LAUNCHD_LOGDIR)"
  else
    echo "installed, but /healthz did not answer; see $LAUNCHD_LOGDIR/server.err.log" >&2
    tail -n 20 "$LAUNCHD_LOGDIR/server.err.log" >&2 || true
    return 1
  fi
}

uninstall_agent() {
  if ! installed; then
    echo "not installed"
    return
  fi
  loaded && launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "uninstalled (the server is stopped; ./run.sh start runs it in the background again)"
}

case "${1:-restart}" in
  start) start ;;
  stop) stop ;;
  serve) serve ;;
  plist) render_plist ;;
  install) install_agent "${2:-}" ;;
  uninstall) uninstall_agent ;;
  status)
    mode="background process"
    if installed; then mode="launchd agent, starts at login"; fi
    if running; then echo "running (pid $(pgrep -f "$PATTERN" | head -1)) — $mode"; else echo "not running — $mode"; fi
    ;;
  logs)
    if installed; then tail -n 50 -f "$LAUNCHD_LOGDIR/server.log" "$LAUNCHD_LOGDIR/server.err.log"; else tail -n 50 -f "$LOG"; fi
    ;;
  restart)
    build "${2:-}"
    stop
    start
    ;;
  *)
    echo "usage: $0 [restart [-w]|start|stop|status|logs|install [-w]|uninstall|serve|plist]" >&2
    exit 2
    ;;
esac
