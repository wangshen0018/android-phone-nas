#!/system/bin/sh
# thunder-sync.sh — 把迅雷下完的文件搬进 nasbak/downloads/Thunder
#
# 为什么需要（2026-11-05）：
#   迅雷的下载目录固定为 /sdcard/Android/data/com.xunlei.downloadprovider/files/ThunderDownload
#   （官方明确「存储路径不支持修改」），下载物必须搬一次才进得了自己的存储区。
#   实测 DLDIR 与 /data/media/0 不同挂载（dev 101 vs 64553），
#   所以必须「复制 + 校验 + 删源」，不能 mv。
#
# 2026-11-06 改进（本轮四项必做之二）：
#   · 目标从 inbox/Thunder 改到 downloads/Thunder —— 原来 mp4/mov 会被
#     judge.sh --ingest 扫进照片判读队列，≤12MB 的还会真调 VLM（产生费用、
#     污染 data.json），而 move-by-date.sh 又不扫 Thunder，文件永久滞留。
#   · 「已下完」判据从「连续两轮大小不变」改为四条同时满足：
#       1) 无同名分片索引（.<文件名>.js / .xltd）—— 有就说明仍在写
#       2) mtime 冷却 ≥ MIN_AGE_SEC（默认 300 秒）
#       3) 大小 ≥ MINBYTES（默认 64KB）
#       4) 连续 STABLE_ROUNDS（默认 3 轮 / 15 分钟）size 与 mtime 都不变
#     原判据遇到「迅雷暂停 / 限速到 0 / P2SP 断供」会把半成品搬走，
#     随后 rm 源、迅雷任务还在 → 很可能重新下载，形成循环。
#     注：设备无 sqlite3，且迅雷任务库是 WAL 模式、结构未验证，
#         故没有采用「读 DB 判完成」，改用上面这组可观测的组合判据。
#   · 搬运成功后不再立即 rm 源，改为改名 .nasbak-done 并记台账，
#     KEEP_HOURS（默认 24 小时）后才删除：万一误判，有一整天可人工挽回。
#   · --dry 完全只读：不写快照、不写日志、不写台账、不改文件名、不调 ingest
#   · 扫描改为递归 find，顶层单文件任务不再漏掉（原来只扫 DLDIR/*/ 一层）
#
# 用法：
#   sh thunder-sync.sh            搬（默认）
#   sh thunder-sync.sh --dry      只报告，不动任何文件
#
# 可调环境变量：MINBYTES / STABLE_ROUNDS / MIN_AGE_SEC / KEEP_HOURS

BASE=/data/media/0/nasbak
ST=$BASE/state
DLDIR=/sdcard/Android/data/com.xunlei.downloadprovider/files/ThunderDownload
DESTROOT=$BASE/downloads/Thunder
DONE_SUFFIX=.nasbak-done
LOG=$ST/thunder-sync.log
STATEF=$ST/_thunder_sizes.tsv
DONEF=$ST/_thunder_done.tsv
LEDGER=$ST/ledger.jsonl
BB=/data/adb/magisk/busybox
MINBYTES=${MINBYTES:-65536}
STABLE_ROUNDS=${STABLE_ROUNDS:-3}
MIN_AGE_SEC=${MIN_AGE_SEC:-300}
KEEP_HOURS=${KEEP_HOURS:-24}
TAB=$(printf '\t')

APPLY=1
case "${1:-}" in
  --dry|--dry-run) APPLY=0 ;;
  --help|-h) echo "用法: sh thunder-sync.sh [--dry]"; exit 0 ;;
esac

# 单实例锁（复用统一锁库；缺库就不跑，宁可不动也不能并发搬错）
if [ -r /data/adb/nasbak/bin/lib-lock.sh ]; then
  . /data/adb/nasbak/bin/lib-lock.sh
else
  echo "缺少 lib-lock.sh，本次退出" >&2
  exit 1
fi
if ! lock_acquire thunder-sync; then
  echo "已有实例在运行，本次退出"
  exit 0
fi

LIST=/data/local/tmp/_xl_sync.$$.list
PREV=$STATEF.prev.$$
TMPD=$DONEF.$$
trap 'rm -f "$LIST" "$PREV" "$TMPD" 2>/dev/null; lock_release thunder-sync' 0
trap 'lock_release thunder-sync; exit 1' INT TERM

mkdir -p "$ST" 2>/dev/null

log() {
  if [ "$APPLY" = "1" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
  else
    printf 'DRY %s\n' "$*"
  fi
}
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'; }

# 日志轮转（干跑不碰文件）
if [ "$APPLY" = "1" ] && [ -f "$LOG" ]; then
  LSZ=$($BB stat -c %s "$LOG" 2>/dev/null)
  if [ -n "$LSZ" ] && [ "$LSZ" -gt 1048576 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv -f "$LOG.tmp.$$" "$LOG"
  fi
fi

[ -d "$DLDIR" ] || { log "下载目录不存在，跳过"; exit 0; }

# ---------- 快照：正式运行才滚动；干跑只读上一轮 ----------
if [ "$APPLY" = "1" ]; then
  [ -f "$STATEF" ] && mv -f "$STATEF" "$PREV" 2>/dev/null
  : > "$STATEF" 2>/dev/null
  SNAP=$STATEF
else
  PREV=$STATEF
  SNAP=/dev/null
fi

# 记录格式：size \t mtime \t 连续稳定轮数 \t 路径
prevrec() {
  [ -f "$PREV" ] || return 0
  grep -F "$TAB$1" "$PREV" 2>/dev/null | head -1
}

mark_done() { # $1=源路径 $2=大小 → 改名保留，不在本轮删
  _fp=$1; _sz=$2
  _dst="$_fp$DONE_SUFFIX"
  mv -f "$_fp" "$_dst" 2>/dev/null || return 1
  printf '%s\t%s\t%s\n' "$(date +%s)" "$_sz" "$_dst" >> "$DONEF" 2>/dev/null
  return 0
}

write_ledger() { # $1=相对路径 $2=文件名 $3=大小
  [ -f /data/adb/nasbak/bin/lib-ledger.sh ] || return 0
  _id=$(printf '%s:%s' "Thunder/$1" "$3" | $BB sha256sum 2>/dev/null | cut -c1-16)
  printf '{"ts":%s,"t":"%s","id":"%s","name":"%s","size":%s,"act":"thunder","from":"%s","to":"%s","note":"%s"}\n' \
    "$(date +%s)" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$_id" \
    "$(jesc "$2")" "$3" \
    "$(jesc "Android/data/com.xunlei.downloadprovider/files/ThunderDownload/$1")" \
    "$(jesc "downloads/Thunder/$1")" "迅雷下载搬运（源改名保留 ${KEEP_HOURS}h）" \
    >> "$LEDGER" 2>/dev/null
}

# 清理过期 .nasbak-done：只在正式运行、且每轮顺手做，不另加 cron
purge_done() {
  [ -f "$DONEF" ] || return 0
  _keep=$(( $(date +%s) - KEEP_HOURS * 3600 ))
  : > "$TMPD" 2>/dev/null
  while IFS= read -r _ln; do
    [ -n "$_ln" ] || continue
    _ts=$(printf '%s' "$_ln" | cut -f1)
    _p=$(printf '%s' "$_ln" | cut -f3-)
    [ -f "$_p" ] || continue
    if [ -n "$_ts" ] && [ "$_ts" -le "$_keep" ]; then
      rm -f "$_p" 2>/dev/null && PURGED=$((PURGED+1))
    else
      printf '%s\n' "$_ln" >> "$TMPD"
    fi
  done < "$DONEF"
  mv -f "$TMPD" "$DONEF" 2>/dev/null || rm -f "$TMPD" 2>/dev/null
}

# 递归扫描：顶层单文件、任务子目录里的文件都能扫到。
# 排除点开头的索引、已搬运标记、迅雷自身的中间格式。
find "$DLDIR" -type f \
  ! -name '.*' \
  ! -name "*$DONE_SUFFIX" \
  ! -name '*.torrent' ! -name '*.js' ! -name '*.xltd' ! -name '*.td' \
  ! -name '*.cfg' ! -name '*.downloading' ! -name '*.part' ! -name '*.!ut' \
  2>/dev/null > "$LIST"

NOW=$(date +%s)
MOVED=0; SKIP=0; WAIT=0; BYTES=0; PURGED=0

while IFS= read -r FP; do
  [ -n "$FP" ] || continue
  [ -f "$FP" ] || continue
  N=$(basename "$FP")
  REL=$(printf '%s' "$FP" | sed "s#^$DLDIR/##")
  TASKDIR=$(dirname "$FP")
  SZ=$($BB stat -c %s "$FP" 2>/dev/null)
  MT=$($BB stat -c %Y "$FP" 2>/dev/null)
  [ -n "$SZ" ] || continue
  [ -n "$MT" ] || MT=0
  SZ=$((SZ))

  # 先记本轮观测（无论是否符合搬运条件，供下一轮比对）
  PR=$(prevrec "$FP")
  CNT=1
  if [ -n "$PR" ]; then
    PSZ=$(printf '%s' "$PR" | cut -f1)
    PMT=$(printf '%s' "$PR" | cut -f2)
    PCNT=$(printf '%s' "$PR" | cut -f3)
    [ -n "$PCNT" ] || PCNT=0
    if [ "$PSZ" = "$SZ" ] && [ "$PMT" = "$MT" ]; then CNT=$((PCNT+1)); fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$SZ" "$MT" "$CNT" "$FP" >> "$SNAP"

  # 判据 1：同名分片索引还在 → 正在下载
  if [ -f "$TASKDIR/.$N.js" ] || [ -f "$FP.xltd" ] || [ -f "$TASKDIR/.$N.xltd" ]; then
    WAIT=$((WAIT+1)); continue
  fi
  # 判据 2：mtime 冷却，刚写完的文件可能还在刷盘
  AGE=$((NOW-MT))
  if [ "$AGE" -lt "$MIN_AGE_SEC" ]; then WAIT=$((WAIT+1)); continue; fi
  # 判据 3：太小当碎片
  if [ "$SZ" -lt "$MINBYTES" ]; then SKIP=$((SKIP+1)); continue; fi
  # 判据 4：连续 N 轮 size + mtime 都没变
  if [ "$CNT" -lt "$STABLE_ROUNDS" ]; then WAIT=$((WAIT+1)); continue; fi

  DEST="$DESTROOT/$REL"
  DESTDIR=$(dirname "$DEST")
  [ "$APPLY" = "1" ] && mkdir -p "$DESTDIR" 2>/dev/null

  # 目标已有同名同大小 → 之前搬过（或迅雷重新下载了同一份），只标记源不重复搬
  if [ -f "$DEST" ]; then
    DSZ=$($BB stat -c %s "$DEST" 2>/dev/null)
    if [ "$DSZ" = "$SZ" ]; then
      if [ "$APPLY" = "1" ]; then
        mark_done "$FP" "$SZ" || log "失败(源改名) $REL"
      fi
      SKIP=$((SKIP+1))
      continue
    fi
    # 大小不同 → 保留旧副本，新副本加时间戳，绝不覆盖
    DEST="$DESTDIR/$(date +%Y%m%d%H%M%S)_$N"
  fi

  if [ "$APPLY" != "1" ]; then
    MOVED=$((MOVED+1)); BYTES=$((BYTES+SZ))
    log "可搬 $REL  ${SZ}B  稳定${CNT}轮 静默${AGE}s"
    continue
  fi

  if cp -f "$FP" "$DEST" 2>/dev/null; then
    DSZ=$($BB stat -c %s "$DEST" 2>/dev/null)
    if [ "$DSZ" = "$SZ" ]; then
      if mark_done "$FP" "$SZ"; then
        MOVED=$((MOVED+1)); BYTES=$((BYTES+SZ))
        log "搬入 $REL  ${SZ}B（源改名保留 ${KEEP_HOURS}h）"
        write_ledger "$REL" "$N" "$SZ"
      else
        rm -f "$DEST" 2>/dev/null
        log "失败(源改名) $REL，副本已回滚，源保留"
      fi
    else
      rm -f "$DEST" 2>/dev/null
      log "失败(大小不符) $REL 期望${SZ}B 实际${DSZ}B，源保留"
    fi
  else
    log "失败(复制) $REL，源保留"
  fi
done < "$LIST"

rm -f "$LIST" "$PREV" 2>/dev/null
MB=$((BYTES / 1048576))

if [ "$APPLY" = "1" ]; then
  purge_done
  log "=== thunder-sync: 搬入 $MOVED / 等待稳定 $WAIT / 跳过 $SKIP / 清理旧源 $PURGED / 共 ${MB}MB ==="
  echo "moved=$MOVED waiting=$WAIT skipped=$SKIP purged=$PURGED involved=${MB}MB"
else
  echo "DRY moved=$MOVED waiting=$WAIT skipped=$SKIP involved=${MB}MB"
fi

# 不再调 judge.sh --ingest：downloads/ 不在 inbox 下，本来就不该进照片判读队列。
# judge.sh 里另加了一层路径排除作为防御（见其 ingest()）。

exit 0
