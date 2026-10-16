#!/bin/bash
# 配置文件 $TRIM_PKGETC/quizmind.env 的读写。
#   quizmind-env.sh write   把环境里的 wizard_* 变量（校验后）合并进配置文件，缺的用默认值；已有的值不丢
# 配置项：BIND、TOKEN（后台管理口令，服务要拿到明文，所以文件权限 600；没设置过就随机生成一个）
ENV_FILE="$TRIM_PKGETC/quizmind.env"

BIND=0.0.0.0 TOKEN=
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# 向导值当作不可信输入，校验通过才采用
[[ "${wizard_bind:-}" =~ ^(0\.0\.0\.0|127\.0\.0\.1)$ ]] && BIND="$wizard_bind"
[[ "${wizard_token:-}" =~ ^[A-Za-z0-9_.@!#%^*+=-]{8,64}$ ]] && TOKEN="$wizard_token"
# 一直没设置过口令：生成一个随机的，保证管理后台不会无口令暴露（用户在应用设置里改成自己的）
if [ -z "$TOKEN" ]; then
  TOKEN="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
  echo "没有设置管理口令，已随机生成一个，请在应用设置里改成自己的" >&2
fi

case "$1" in
  write)
    mkdir -p "$TRIM_PKGETC"
    umask 077
    cat > "$ENV_FILE" <<EOT
BIND="$BIND"
TOKEN='$TOKEN'
EOT
    ;;
  *) echo "usage: $0 write" >&2; exit 1 ;;
esac
