#!/system/bin/sh
# media-gc.sh — 回收 www/media 里失去引用的副本
#
# 背景：ingest 会给每个文件在 $WWW/media/ 建一份副本供 httpd 直出。实测 media 下
#   3173 个文件全部 nlink=1，说明当初 ln 硬链接失败后走了 cp 复制分支 ——
#   每个都是独立占空间的副本，全流程又没有回收逻辑。后果：
#     1) 文件判 del 后源文件删了，media 里的副本仍在 → 空间不释放
#     2) 归档后每张照片留一份副本
#     3) 目录项无限增长
#
# 谁在用 media 里的东西（这是判定能否回收的唯一依据，全部核对过源码）：
#   · judge.html   mediaURL = 'media/' + it.id + '.' + it.type   → 用 ingest 时的 id
#   · archive.html mediaSrc = '/media/' + f.mid + '.' + f.e      → 用归档时重算的 mid
#
#   ⚠ 关键：mid 由 archive.cgi 生成，公式是 sha256("$YM/$事件夹/$文件名:$大小")[:16]，
#     因为输入是归档路径而非 inbox 路径，所以 mid != id，且不会存在 analysis/<mid>.json。
#     早期版本只用 analysis 判定，会把归档页正在用的图当孤儿全部清掉（实测会误伤 66 个）。
#     所以这里必须先构建归档 mid 集合，命中即保留。
#
# 保留规则（任一命中即保留）：
#   1) 文件名是归档 mid                                        → archive.html 要用
#   2) analysis/<id>.json 存在 且 其 rel 指向的 inbox 文件仍在  → judge.html 要用
#   3) id 在 pending.queue 里                                  → 判读中
#   4) 无分析结果，但 _loc_old/loc-<id>.tsv 记的源文件仍在 inbox → 保留
#   5) 既无分析结果也无 loc 记录                                → 无法判断来源，保留
# 只有「源确实已不在 inbox」的副本才回收。
#
#   ⚠ 为什么"源还在 inbox"不能删：judge.sh:91-92 的 ingest 会对每个 inbox 文件
#     执行 `[ ! -f media/$ID.$EXT ]` 后 ln/cp 补建。inbox 现有 3034 个文件、
#     副本约 350MB，删掉只会让下轮 ingest 白复制一遍，持续无用 I/O 换不来收益。
#     只有源已经不在了（判 del 后删除、mvdate 后路径失效）才是稳定孤儿。
#
# 回收方式：mv 到 $ST/_media_gc_trash/<时间戳>/，不是 rm。
#   media 副本一旦删掉不会被自动重建（源已不在 inbox，ingest 不会再遍历到），
#   所以要留一次反悔机会。确认无影响后，把 _media_gc_trash 整个删掉即可。
#
# 用法:
#   sh media-gc.sh            干跑，只统计和写日志
#   sh media-gc.sh --apply    真正执行（移入隔离区）
#
# 2026-11-03 改动：
#   · 加 mkdir 原子锁（bin/lib-lock.sh），两个实例不再抢同一批中间文件
#   · 中间文件名加 $$ 后缀，即使锁失效也不会互相删除

BASE=/data/media/0/nasbak
# 锁库必须存在，否则宁可整个脚本不跑（并发下的假统计比不跑更难排查）
if [ -r /data/adb/nasbak/bin/lib-lock.sh ]; then
  . /data/adb/nasbak/bin/lib-lock.sh
else
  echo "缺少 /data/adb/nasbak/bin/lib-lock.sh，无法保证单实例，本次退出" >&2
  exit 1
fi
INBOX=$BASE/inbox
ARC=$BASE/archive
ST=$BASE/state
WWW=/data/adb/nasbak/www
MEDIA=$ST/media    # 实体目录（2026-11-03 迁移：与照片同挂载走硬链接；www/media 只是 httpd 用的 symlink）
QUEUE=$ST/pending.queue
LOCT=$ST/_loc_old
LOG=$ST/media-gc.log
BB=/data/adb/magisk/busybox
TS=$(date +%Y%m%d%H%M%S)
TRASH=$ST/_media_gc_trash/$TS

APPLY=0
case "${1:-}" in
  --apply) APPLY=1 ;;
  --help|-h) echo "用法: sh media-gc.sh [--apply]"; exit 0 ;;
esac

[ -d "$MEDIA" ] || { echo "media 目录不存在: $MEDIA"; exit 0; }

mkdir -p "$ST" 2>/dev/null
touch "$LOG" 2>/dev/null
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# ---------- 单实例锁 ----------
# 之前两个实例同时跑会互相删掉对方正在读的中间文件（_media_gc.list / _arc_mids.txt），
# 表现为「kept=0 kept_archive=0 would_drop=0」这种与真实值完全不符的假统计。
# 拿不到锁就退出，不阻塞、不等待。
if ! lock_acquire media-gc; then
  log "media-gc: 已有实例在运行，本次退出"
  echo "已有实例在运行，本次退出（未做任何改动）"
  exit 0
fi
trap 'lock_release media-gc' 0
trap 'lock_release media-gc; exit 1' INT TERM

# 让路判定：judge.sh 正在往 media/ 里建副本时，本脚本搬走副本可能把刚建的
# 一并当成孤儿（虽然新副本因无 analysis 记录会被保守保留，但没必要冒险）。
# 判读通常只跑几分钟，撞上了就跳过这一轮，留到下周。
if lock_busy judge; then
  log "media-gc: 判读正在进行中，本次让路跳过"
  echo "判读正在进行中，本次让路跳过（未做任何改动）"
  exit 0
fi

# 日志轮转：>2MB 只留最后 3000 行
if [ -f "$LOG" ]; then
  SZ=$($BB stat -c %s "$LOG" 2>/dev/null)
  if [ -n "$SZ" ] && [ "$SZ" -gt 2097152 ]; then
    tail -n 3000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
fi

# ---------- 1. 构建归档 mid 集合 ----------
# 文件名带 $$ ：即使锁意外失效，也不会与另一个实例抢同一个文件
ARCMIDS=$ST/_arc_mids.$$.txt
: > "$ARCMIDS" 2>/dev/null
ARCN=0
if [ -d "$ARC" ]; then
  for M in "$ARC"/*/; do
    [ -d "$M" ] || continue
    YM=$(basename "$M")
    for D in "$M"*/; do
      [ -d "$D" ] || continue
      F=$(basename "$D")
      for FP in "$D"*; do
        [ -f "$FP" ] || continue
        N=$(basename "$FP")
        SZ2=$($BB stat -c %s "$FP" 2>/dev/null); [ -z "$SZ2" ] && SZ2=0
        printf '%s:%s' "$YM/$F/$N" "$SZ2" | "$BB" sha256sum 2>/dev/null | cut -c1-16 >> "$ARCMIDS"
        ARCN=$((ARCN+1))
      done
    done
  done
fi

KEEP=0
KEEPARC=0
DROP=0
BYTES=0
SKIP=0
TAB=$(printf '\t')

LIST=$ST/_media_gc.$$.list
ls -1 "$MEDIA" > "$LIST" 2>/dev/null

while IFS= read -r FN; do
  [ -z "$FN" ] && continue

  ID=$(printf '%s' "$FN" | sed -n 's/^\([0-9a-f]\{16\}\)\..*$/\1/p')
  if [ -z "$ID" ]; then
    SKIP=$((SKIP+1))
    continue
  fi

  # 规则 1：归档 mid
  if [ -s "$ARCMIDS" ] && grep -qxF "$ID" "$ARCMIDS" 2>/dev/null; then
    KEEPARC=$((KEEPARC+1))
    continue
  fi

  AJ="$ST/analysis/$ID.json"
  REASON=""

  if [ -f "$AJ" ]; then
    # 有分析结果：看它记录的 rel 指向的文件还在不在 inbox
    REL=$(sed -n 's/.*"rel":"\([^"]*\)".*/\1/p' "$AJ" | head -1)
    if [ -n "$REL" ] && [ -f "$INBOX/$REL" ]; then
      KEEP=$((KEEP+1))
      continue
    fi
    REASON="已离开 inbox(rel=${REL:-未知})"
  else
    if [ -s "$QUEUE" ] && grep -qF "$ID$TAB" "$QUEUE" 2>/dev/null; then
      KEEP=$((KEEP+1))
      continue
    fi
    # 没有分析结果：用废弃的 loc 表回溯源路径
    L=$(ls "$LOCT"/loc-"$ID".tsv 2>/dev/null | head -1)
    if [ -n "$L" ]; then
      REL=$(cut -f2 "$L" 2>/dev/null | head -1)
      if [ -n "$REL" ] && [ -f "$INBOX/$REL" ]; then
        # 源还在 inbox → 保留。ingest 的 [ ! -f ] 补建逻辑会把它重建，
        # 删了只会让下轮 ingest 白复制一遍，没有收益。
        KEEP=$((KEEP+1))
        continue
      fi
      REASON="源不在 inbox(rel=${REL:-未知})"
    else
      # 既无分析结果也无 loc 记录，无法判断来源，保守保留
      KEEP=$((KEEP+1))
      continue
    fi
  fi

  SZ=$($BB stat -c %s "$MEDIA/$FN" 2>/dev/null)
  [ -z "$SZ" ] && SZ=0

  if [ "$APPLY" = "1" ]; then
    mkdir -p "$TRASH" 2>/dev/null
    if mv -f "$MEDIA/$FN" "$TRASH/$FN" 2>/dev/null; then
      DROP=$((DROP+1))
      BYTES=$((BYTES + SZ))
      log "GC   $FN  ${SZ}B  $REASON"
    else
      log "FAIL $FN  $REASON"
    fi
  else
    DROP=$((DROP+1))
    BYTES=$((BYTES + SZ))
    log "DRY  $FN  ${SZ}B  $REASON"
  fi
done < "$LIST"

rm -f "$LIST" 2>/dev/null
# mid 集合用完即删：文件名带 $$，不删会在 state 里每周堆一个垃圾文件
rm -f "$ARCMIDS" 2>/dev/null
MB=$((BYTES / 1048576))

if [ "$APPLY" = "1" ]; then
  log "=== media-gc: 保留 $KEEP / 保留(归档) $KEEPARC / 移入隔离 $DROP / 涉及 ${MB}MB / 跳过 $SKIP ==="
  echo "kept=$KEEP kept_archive=$KEEPARC moved=$DROP involved=${MB}MB skipped=$SKIP"
  [ "$DROP" -gt 0 ] && echo "隔离区: $TRASH（确认无影响后整个删除即可）"
else
  log "=== media-gc(干跑): 拟保留 $KEEP / 拟保留(归档) $KEEPARC / 拟回收 $DROP / 涉及 ${MB}MB / 跳过 $SKIP ==="
  echo "DRY-RUN kept=$KEEP kept_archive=$KEEPARC would_drop=$DROP involved=${MB}MB skipped=$SKIP"
  echo "确认后加 --apply 执行（移入隔离区，不直接删除）"
fi
echo "归档 mid 集合: $ARCN 个"
