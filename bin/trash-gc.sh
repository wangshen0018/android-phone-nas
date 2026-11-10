#!/system/bin/sh
. "$(dirname "$0")/lib-path.sh"
# trash-gc.sh — 回收站（_media_gc_trash）自动清理，保留 30 天
#
# 背景（2026-11-06 用户决定）：
#   「删除」不再是 rm，而是把文件 mv 进回收站，保留 30 天后自动清掉。
#   所以回收站是用户最后一次反悔的机会 —— 清理策略必须保守：
#   · 只按【目录名里的日期】判断，不看文件 mtime（mv 会保留原 mtime，
#     老照片的 mtime 可能是好几年前，按 mtime 会立刻被误删）
#   · 解析不出日期的目录一律保留，宁可占空间也不误删
#   · 默认干跑，加 --apply 才真删
#
# 目录命名（两种来源）：
#   <YYYYMMDD>            apply.cgi 的删除操作（按执行当天分组）
#   <YYYYMMDDHHMMSS>      media-gc.sh 的孤儿副本回收
# 老代码还产生过 applied-YYYYMMDD 格式，一并兼容。

DATA=$NASBAK_ROOT/state
TRASH="$DATA/_media_gc_trash"
KEEP_DAYS=30
LOG=$NASBAK_HOME/logs/trash-gc.log
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

[ -d "$TRASH" ] || { echo '{"ok":true,"err":"回收站不存在","removed":0}'; exit 0; }

NOW=$(date +%s)
CUT=$((NOW - KEEP_DAYS * 86400))
DELN=0; KEEPN=0; SKIPN=0; FREED=0
LIST=""

for d in "$TRASH"/*/; do
  [ -d "$d" ] || continue
  N=$(basename "$d")

  # 从目录名解析出「这一批是什么时候放进来的」
  # 注意：Android 自带的 date 不支持 -d，必须用 busybox（实测踩到）。
  TS=""
  case "$N" in
    applied-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
      D8=${N#applied-}; TS=$($BB date -d "${D8} 00:00:00" +%s 2>/dev/null) ;;
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
      D8=${N:0:8}; TS=$($BB date -d "${D8:0:4}-${D8:4:2}-${D8:6:2} ${N:8:2}:${N:10:2}:${N:12:2}" +%s 2>/dev/null) ;;
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
      D8=$N; TS=$($BB date -d "${D8:0:4}-${D8:4:2}-${D8:6:2} 00:00:00" +%s 2>/dev/null) ;;
  esac
  [ -z "$TS" ] && TS=$($BB date -d "$N" +%s 2>/dev/null)

  # 解析不出来 → 保守保留
  if [ -z "$TS" ]; then
    KEEPN=$((KEEPN+1)); SKIPN=$((SKIPN+1))
    printf '%s 跳过（目录名无日期）: %s\n' "$(date '+%F %T')" "$N" >> "$LOG" 2>/dev/null
    continue
  fi

  if [ "$TS" -lt "$CUT" ]; then
    SZ=$(du -sk "$d" 2>/dev/null | cut -f1)
    [ -z "$SZ" ] && SZ=0
    DAYS=$(( (NOW - TS) / 86400 ))
    if [ "$APPLY" = "1" ]; then
      if rm -rf "$d" 2>/dev/null; then
        DELN=$((DELN+1)); FREED=$((FREED + SZ))
        printf '%s 清理 %s（%s 天前，%s KB）\n' "$(date '+%F %T')" "$N" "$DAYS" "$SZ" >> "$LOG" 2>/dev/null
      fi
    else
      DELN=$((DELN+1)); FREED=$((FREED + SZ))
      LIST="${LIST}${N}(${DAYS}天前) "
    fi
  else
    KEEPN=$((KEEPN+1))
  fi
done

HU=$(awk -v k="$FREED" 'BEGIN{
  if (k >= 1048576) printf "%.1f GB", k/1048576;
  else if (k >= 1024) printf "%.0f MB", k/1024;
  else printf "%d KB", k }' 2>/dev/null)
[ -z "$HU" ] && HU="${FREED}KB"

if [ "$APPLY" = "1" ]; then
  echo "{\"ok\":true,\"removed\":$DELN,\"kept\":$KEEPN,\"skipped\":$SKIPN,\"freed\":\"$HU\"}"
else
  echo "{\"ok\":true,\"dry\":true,\"would_remove\":$DELN,\"kept\":$KEEPN,\"skipped\":$SKIPN,\"freed\":\"$HU\",\"list\":\"$(printf '%s' "$LIST" | sed 's/ $//')\"}"
fi
exit 0
