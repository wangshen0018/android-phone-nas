#!/system/bin/sh
# ingest-backlog.sh — 把 K80 备份来的历史照片搬进 nasbak/inbox（按年份分目录）
# ---------------------------------------------------------------
# 与 judge.sh 的关系：
#   · 本脚本只「搬文件」，**不登记、不判读**
#   · 搬完后 inbox/<YYYY-MM-DD>/ 下有文件，但 state/ 里没有 loc-*.tsv
#   · 所以 judge.sh 不会自动判读它们（它只认 loc-*.tsv）
#   · 想判哪一年，用 judge-year.sh <YYYY> 手动触发
#
# 设计：
#   · mv 不 copy（同分区，不占双份）
#   · 幂等：inbox 里已有同名就跳过
#   · 按文件名里的拍摄日期归入 inbox/<YYYY-MM-DD>/
#
# 用法:
#   ingest-backlog.sh --dry [年]     只预览
#   ingest-backlog.sh [年]           搬移（默认全部历史）
#   ingest-backlog.sh --recent N     只搬最近 N 天
#   年 可省略；给 2026 则只搬 2026 年的

BASE=/data/media/0/nasbak
INBOX=$BASE/inbox
ST=$BASE/state
LOGD=/data/adb/nasbak/logs
LOG=$LOGD/backlog.log
BB=/data/adb/magisk/busybox

DRY=0; YEAR=""; RECENT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry) DRY=1; shift ;;
    --recent) RECENT="$2"; shift 2 ;;
    [0-9][0-9][0-9][0-9]) YEAR="$1"; shift ;;
    *) shift ;;
  esac
done

mkdir -p "$INBOX" "$ST" "$LOGD" 2>/dev/null
touch "$LOG" 2>/dev/null
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

fdate() {
  B=$(basename "$1"); R=""
  # ① 完整 YYYY-MM-DD（最明确）
  case "$B" in
    *20[0-9][0-9]-[01][0-9]-[0-3][0-9]*)
      R=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]-[01][0-9]-[0-3][0-9]\).*/\1/p' | head -1) ;;
  esac
  # ② YYYYMMDD_HHMMSS —— 小米相机命名，必须紧跟下划线6位数字
  [ -z "$R" ] && R=$(printf '%s' "$B" | sed -n 's/.*[^0-9]\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_[0-9][0-9][0-9][0-9][0-9][0-9].*/\1-\2-\3/p' | head -1)
  [ -z "$R" ] && R=$(printf '%s' "$B" | sed -n 's/^\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_[0-9][0-9][0-9][0-9][0-9][0-9].*/\1-\2-\3/p' | head -1)
  # ③ 13 位毫秒时间戳 —— 必须在通用 YYYYMMDD 之前，否则 1732083090 会被误读成 2083
  [ -z "$R" ] && case "$B" in
    *1[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
      TS=$(printf '%s' "$B" | sed -n 's/.*[^0-9]\(1[0-9]\{12\}\)[^0-9].*/\1/p' | head -1)
      [ -z "$TS" ] && TS=$(printf '%s' "$B" | sed -n 's/.*[^0-9]\(1[0-9]\{12\}\)$/\1/p' | head -1)
      if [ -n "$TS" ]; then
        R=$($BB date -d "@$(printf '%s' "$TS" | sed 's/...$//')" +%Y-%m-%d 2>/dev/null)
        # 合理性校验：时间戳解出的年份必须在 2000-2100
        case "$R" in 20[0-9][0-9]-*) ;; *) R="" ;; esac
      fi ;;
  esac
  # ④ YYYY_MM_DD
  [ -z "$R" ] && case "$B" in
    *20[0-9][0-9]_[01][0-9]_[0-3][0-9]*)
      R=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]\)_\([01][0-9]\)_\([0-3][0-9]\)_.*/\1-\2-\3/p' | head -1) ;;
  esac
  # ⑤ 兜底：名字里任意 2000-2099 的 YYYYMMDD（放最后，避免误抓）
  [ -z "$R" ] && R=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\).*/\1-\2-\3/p' | head -1)
  # ⑥ 最后用 mtime
  [ -z "$R" ] && R=$($BB date -d "@$($BB stat -c %Y "$1" 2>/dev/null || echo 0)" +%Y-%m-%d 2>/dev/null)
  [ -z "$R" ] && R="unknown"
  printf '%s' "$R"
}

MOVED=0; SKIP=0; ERR=0

handle_dir() {
  SRCDIR="$1"
  [ -d "$SRCDIR" ] || return 0
  log "扫描: $SRCDIR"
  find "$SRCDIR" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \
       -o -iname '*.webp' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.3gp' \
       -o -iname '*.m4v' \) 2>/dev/null | while IFS= read -r F; do
    B=$(basename "$F")
    case "$B" in .*|*.tmp|.pending-*|.nomedia) continue ;; esac

    D=$(fdate "$F")
    # 年份过滤
    if [ -n "$YEAR" ]; then
      case "$D" in "$YEAR"-*) ;; *) continue ;; esac
    fi
    # 最近 N 天过滤
    if [ -n "$RECENT" ]; then
      CUT=$($BB date -d "@$(( $(date +%s) - RECENT * 86400 ))" +%Y-%m-%d 2>/dev/null)
      [ -n "$CUT" ] && case "$D" in
        unknown) continue ;;
      esac
      if [ -n "$CUT" ] && [ "$D" \< "$CUT" ]; then continue; fi
    fi

    REL="$D/$B"
    if [ -f "$INBOX/$REL" ]; then SKIP=$((SKIP+1)); continue; fi

    DEST="$INBOX/$D"
    if [ "$DRY" = "1" ]; then
      echo "  [DRY] $B -> $D/"
    else
      mkdir -p "$DEST" 2>/dev/null
      if mv -f "$F" "$DEST/$B" 2>/dev/null; then
        MOVED=$((MOVED+1))
      else
        ERR=$((ERR+1)); log "FAIL: mv $F"
      fi
    fi
  done
}

handle_dir /data/media/0/DCIM/Camera
handle_dir /data/media/0/DCIM/CamScanner
handle_dir /data/media/0/Pictures/scanner
handle_dir /data/media/0/Pictures/Gallery/owner/family-kid
handle_dir /data/media/0/Pictures/Gallery/owner/id-card

if [ "$DRY" = "1" ]; then
  echo ""
  echo "=== DRY RUN 完成（未动任何文件）==="
else
  log "=== 搬移完成: moved=$MOVED skip=$SKIP err=$ERR year=${YEAR:-all} recent=${RECENT:-none} ==="
  echo ""
  echo "搬移统计: moved=$MOVED skip=$SKIP err=$ERR"
fi

echo ""
echo "--- inbox 目录(按日期) ---"
ls -1 "$INBOX" 2>/dev/null | sort | head -20
echo "  共 $(ls -1 "$INBOX" 2>/dev/null | wc -l) 个日期目录"
echo ""
echo "--- 已登记待判(loc-*.tsv) 数量: $(ls "$ST"/loc-*.tsv 2>/dev/null | wc -l) ---"
echo "--- 已判读(analysis/*.json) 数量: $(ls "$ST"/analysis/*.json 2>/dev/null | wc -l) ---"
