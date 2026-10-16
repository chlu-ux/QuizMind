#!/bin/bash
# 打包飞牛应用 QuizMind。
#   ./fnos/build.sh [x86|arm]     默认 x86，产物 fnos/dist/quizmind-<arch>.fpk
# 包里带：交叉编译的 quizmind（内嵌后台管理和手机网页版）、内置题库 defaults/seed.db。
# 题库取自本机运行库（SEED_DB，默认 ~/Library/Application Support/QuizMind/app.db），只导出题库内容：
# 去掉作答记录、收藏、AI 对话和笔记、任务和调用日志、模型配置里的 API Key，以及已被拆分取代的旧库（SKIP_BANKS）。
# 需要 fnos/tools/bin/fnpack（官方工具，不进 git，见 docs/飞牛应用打包指南.md）和 sqlite3。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FNPACK="${FNPACK:-$HERE/tools/bin/fnpack}"
[ -x "$FNPACK" ] || { echo "没找到 fnpack：$FNPACK" >&2; exit 1; }
command -v sqlite3 >/dev/null || { echo "需要 sqlite3" >&2; exit 1; }

ARCH="${1:-x86}"
case "$ARCH" in
  x86) GOARCH=amd64 ;;
  arm) GOARCH=arm64 ;;
  *) echo "架构只能是 x86 或 arm" >&2; exit 1 ;;
esac
SEED_DB="${SEED_DB:-$HOME/Library/Application Support/QuizMind/app.db}"
# 拆成 Java / C++ 两个库以后被取代的合并库（按题库名，逗号分隔）
SKIP_BANKS="${SKIP_BANKS:-软件设计师·下午题六（设计模式代码填空）}"
[ -f "$SEED_DB" ] || { echo "没找到题库：$SEED_DB（用 SEED_DB 指定）" >&2; exit 1; }

OUT="$HERE/dist"
STAGE="$HERE/.build"
mkdir -p "$OUT"
rm -rf "$STAGE/quizmind"; mkdir -p "$STAGE"; cp -R "$HERE/quizmind" "$STAGE/quizmind"
find "$STAGE/quizmind" -name .DS_Store -delete
S="$STAGE/quizmind"

# 1. 程序（后台管理和手机网页版已内嵌，需要先 make web）
( cd "$ROOT/server" && CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" \
    go build -trimpath -ldflags="-s -w" -o "$S/app/bin/quizmind" ./cmd/quizmind )

# 2. 内置题库：在副本上删掉个人数据和密钥，再整理
mkdir -p "$S/app/defaults"
SEED="$S/app/defaults/seed.db"
rm -f "$SEED"
sqlite3 "$SEED_DB" ".backup '$SEED'"
SKIP_SQL=""
IFS=',' read -ra SKIPS <<< "$SKIP_BANKS"
for b in "${SKIPS[@]}"; do
  [ -n "$b" ] || continue
  b="${b//\'/\'\'}"
  SKIP_SQL="$SKIP_SQL
    DELETE FROM question_state WHERE question_id IN (SELECT id FROM question WHERE bank_id IN (SELECT id FROM bank WHERE title='$b'));
    DELETE FROM question WHERE bank_id IN (SELECT id FROM bank WHERE title='$b');
    DELETE FROM chunk WHERE document_id IN (SELECT id FROM document WHERE bank_id IN (SELECT id FROM bank WHERE title='$b'));
    DELETE FROM document WHERE bank_id IN (SELECT id FROM bank WHERE title='$b');
    DELETE FROM bank WHERE title='$b';"
done
sqlite3 "$SEED" "
  PRAGMA foreign_keys=OFF;
  BEGIN;
  $SKIP_SQL
  DELETE FROM attempt;
  DELETE FROM question_state;
  DELETE FROM question_flag;
  DELETE FROM ai_note;
  DELETE FROM agent_attachment;
  DELETE FROM agent_draft;
  DELETE FROM agent_message;
  DELETE FROM agent_conversation;
  DELETE FROM quiz_session;
  DELETE FROM exam;
  DELETE FROM job;
  DELETE FROM llm_call_log;
  DELETE FROM llm_model;
  DELETE FROM llm_provider;
  DELETE FROM app_setting WHERE key <> 'llm_seeded';
  UPDATE question SET flag_count=0;
  COMMIT;
  VACUUM;" >/dev/null
sqlite3 "$SEED" 'PRAGMA journal_mode=DELETE' >/dev/null
rm -f "$SEED-wal" "$SEED-shm"
[ "$(sqlite3 "$SEED" 'PRAGMA integrity_check')" = ok ] || { echo "种子库完整性检查失败" >&2; exit 1; }
[ "$(sqlite3 "$SEED" 'PRAGMA foreign_key_check' | wc -l | tr -d ' ')" = 0 ] || { echo "种子库有悬空引用" >&2; exit 1; }
echo "题库：$(sqlite3 "$SEED" "select count(*) from bank") 个库，$(sqlite3 "$SEED" "select count(*) from question where status='published'") 道已发布题，$(du -h "$SEED" | cut -f1)"
sqlite3 "$SEED" "select '  '||b.title||'  '||count(*) from question q join bank b on b.id=q.bank_id where q.status='published' group by b.id order by b.created_at"

# 3. 清单、权限、打包
sed -i.bak "s/^platform=.*/platform=$ARCH/" "$S/manifest" && rm -f "$S/manifest.bak"
chmod +x "$S/app/bin/"* "$S/cmd/"*
(cd "$S" && "$FNPACK" build)
mv "$S/quizmind.fpk" "$OUT/quizmind-$ARCH.fpk"
echo "产物：$OUT/quizmind-$ARCH.fpk（$(du -h "$OUT/quizmind-$ARCH.fpk" | cut -f1)）"
