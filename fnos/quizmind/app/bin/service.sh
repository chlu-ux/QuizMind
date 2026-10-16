#!/bin/bash
# quizmind 守护进程，由 cmd/main start 拉起：保持 quizmind 在跑，挂了自动重启。
# 数据都在应用数据目录 $TRIM_PKGVAR/data（app.db：题库、作答记录），升级和重装不会覆盖；首次启动从包里的 defaults/seed.db 拷一份题库。
# 后台管理（/）要管理口令（QUIZMIND_TOKEN），刷题页 /m/ 和 App 同步接口不需要。
set -u

APP="$TRIM_APPDEST"
VAR="$TRIM_PKGVAR"
PORT="${TRIM_SERVICE_PORT:-8090}"
DATA="$VAR/data"
ENV_FILE="$TRIM_PKGETC/quizmind.env"
SERVER_PID_FILE="$VAR/quizmind.pid"
SERVER_LOG="$VAR/quizmind.log"

SERVER_PID=""
FAILS=0

log() { echo "$(date '+%F %T') [service] $*"; }

load_env() {
  BIND=0.0.0.0 TOKEN=
  [ -f "$ENV_FILE" ] && . "$ENV_FILE"
}

server_alive() { [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; }

# 内置题库：只在还没有 app.db 时拷一次，不覆盖已有的数据
ensure_data() {
  mkdir -p "$DATA"
  if [ ! -f "$DATA/app.db" ] && [ -f "$APP/defaults/seed.db" ]; then
    log "首次启动：载入内置题库"
    cp "$APP/defaults/seed.db" "$DATA/app.db.tmp" && mv "$DATA/app.db.tmp" "$DATA/app.db"
  fi
}

start_server() {
  ensure_data
  [ -n "$TOKEN" ] || { log "没有管理口令，不启动（请检查 $ENV_FILE）"; return 1; }
  log "启动 quizmind（监听 $BIND:$PORT，数据 $DATA）"
  cd "$VAR" || return 1
  # 口令走环境变量，不出现在进程参数里
  QUIZMIND_LISTEN="$BIND:$PORT" QUIZMIND_DATA_DIR="$DATA" QUIZMIND_TOKEN="$TOKEN" \
    "$APP/bin/quizmind" >> "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!
  echo "$SERVER_PID" > "$SERVER_PID_FILE"
}

# 服务没在跑就拉起来；连续快速失败时放慢重试，免得刷屏
maintain_server() {
  server_alive && { FAILS=0; return; }
  if [ -n "$SERVER_PID" ]; then
    log "quizmind 退出了（pid $SERVER_PID）"
    SERVER_PID=""; rm -f "$SERVER_PID_FILE"
    FAILS=$((FAILS + 1))
  fi
  [ "$FAILS" -ge 3 ] && [ $((SECONDS % 300)) -ge 20 ] && return   # 连败 3 次后约每 5 分钟试一次
  start_server || FAILS=$((FAILS + 1))
}

cleanup() {
  log "收到停止信号"
  if server_alive; then
    kill -TERM "$SERVER_PID" 2>/dev/null   # quizmind 收到 TERM 会先把请求处理完再退出
    for _ in $(seq 1 30); do server_alive || break; sleep 0.5; done
    server_alive && kill -KILL "$SERVER_PID" 2>/dev/null
  fi
  rm -f "$SERVER_PID_FILE"
  exit 0
}
trap cleanup TERM INT

log "守护进程启动（pid $$）"
while true; do
  load_env
  maintain_server
  sleep 10 &
  wait $!
done
