#!/system/bin/sh
# move-by-date.sh — 把 inbox 各来源目录里的新文件按「拍摄日期」移入 inbox/<拍摄日期>/
#
# 设计（用户 2026-11-01/02 确认）：
#   · K80 只把文件塞进 inbox 的固定来源子目录，不按日期建夹
#   · 按拍摄日期分目录在 K40 端做（就是这个脚本）
#   · K80 只传「上次备份后新增」的文件（按 mtime 时间窗），源目录被清空也不会重传
#
# 台账：每个文件记 recv（K80→inbox来源目录）+ mvdate（→日期目录）/dup（→_dup_backup）
#
# 用法: sh move-by-date.sh           干跑
#       sh move-by-date.sh --apply   真正移动并记台账

BASE=/data/media/0/nasbak
INBOX=$BASE/inbox
DUPBK=$INBOX/_dup_backup
BB=/data/adb/magisk/busybox
LOG=$BASE/state/move-by-date.log
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

. /data/adb/nasbak/bin/lib-ledger.sh
mkdir -p "$BASE/state" 2>/dev/null
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

fdate() {
  B=$(basename "$1"); MR=""
  case "$B" in
    *20[0-9][0-9]-[01][0-9]-[0-3][0-9]*) MR=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]-[01][0-9]-[0-3][0-9]\).*/\1/p' | head -1);;
  esac
  [ -z "$MR" ] && case "$B" in
    *20[0-9][0-9][01][0-9][0-3][0-9]_*) MR=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_.*/\1-\2-\3/p' | head -1);;
  esac
  [ -z "$MR" ] && case "$B" in
    *20[0-9][0-9]_[01][0-9]_[0-3][0-9]*) MR=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]\)_\([01][0-9]\)_\([0-3][0-9]\)_.*/\1-\2-\3/p' | head -1);;
  esac
  [ -z "$MR" ] && case "$B" in
    *1[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
      TS=$(printf '%s' "$B" | sed -n 's/.*[^0-9]\(1[0-9]\{12\}\)[^0-9].*/\1/p' | head -1)
      [ -n "$TS" ] && MR=$($BB date -d "@$(printf '%s' "$TS" | sed 's/...$//')" +%Y-%m-%d 2>/dev/null);;
  esac
  [ -z "$MR" ] && MR=$($BB date -d "@$2" +%Y-%m-%d 2>/dev/null)
  printf '%s' "$MR"
}

log "=== 开始 (apply=$APPLY) ==="
MOVED=0; DUPN=0; FAILN=0; SKIPN=0
# 按来源统计本轮移了多少（2026-11-06 加）：
# 通知要在归位之后发，那时源目录已经空了，靠回头扫目录永远数不到；
# 所以在搬运的当下就累积，最后把 "相机 9 · 扫描 2" 这样的串交给 notify.sh。
N_CAM=0; N_SCAN=0; N_SON=0; N_ID=0

# Pantry = 用户端 App 传上来的目录（2026-11-10 加），和相机导入分开便于看来源
for SRC in Camera CamScanner scanner family-kid id-card Pantry; do
  D="$INBOX/$SRC"
  DEVTAG=K80
  [ "$SRC" = "Pantry" ] && DEVTAG=PantryApp
  [ -d "$D" ] || continue
  SRC_CNT=0
  for F in "$D"/*; do
    [ -f "$F" ] || continue
    B=$(basename "$F")
    case "$B" in .trashed-*|.pending-*|.nomedia|*.tmp) continue ;; esac
    S=$(stat -c %s "$F" 2>/dev/null)
    [ -z "$S" ] || [ "$S" = "0" ] && continue
    MT=$(stat -c %Y "$F" 2>/dev/null); [ -z "$MT" ] && MT=$(date +%s)
    DD=$(fdate "$F" "$MT")
    [ -z "$DD" ] && { echo "SKIP(无日期): $B"; SKIPN=$((SKIPN+1)); continue; }
    DST="$INBOX/$DD/$B"

    # ---- 补 recv 记录：K80 上传到 inbox/<来源> ----
    if [ "$APPLY" = "1" ]; then
      RELSRC="inbox/$SRC/$B"
      ID=$(printf '%s:%s' "$DEVTAG:$SRC/$B" "$S" | "$BB" sha256sum | cut -c1-16)
      # 同 id 已有 recv 记录就跳过，避免重复膨胀
      if ! grep -Fq "\"id\":\"$ID\"" "$LEDGER" 2>/dev/null; then
        ledger_add "$ID" "$B" "$S" "recv" "$DEVTAG/$SRC" "$RELSRC" "$DEVTAG 上传"
      fi
    fi

    if [ -e "$DST" ]; then
      S2=$(stat -c %s "$DST" 2>/dev/null)
      if [ "$S" = "$S2" ]; then
        M1=$("$BB" md5sum "$F" 2>/dev/null | cut -d' ' -f1)
        M2=$("$BB" md5sum "$DST" 2>/dev/null | cut -d' ' -f1)
        if [ -n "$M1" ] && [ "$M1" = "$M2" ]; then
          echo "DUP-identical: $SRC/$B (已在 $DD/)"
          if [ "$APPLY" = "1" ]; then
            mkdir -p "$DUPBK/$SRC" 2>/dev/null
            mv -f "$F" "$DUPBK/$SRC/$B" 2>/dev/null
            ID=$(printf '%s:%s' "$DEVTAG:$SRC/$B" "$S" | "$BB" sha256sum | cut -c1-16)
            ledger_add "$ID" "$B" "$S" "dup" "inbox/$SRC/$B" "inbox/_dup_backup/$SRC/$B" "与 $DD/ 内同文件重复，md5 一致"
          fi
          DUPN=$((DUPN+1)); continue
        fi
      fi
      N=1
      while [ -e "$INBOX/$DD/${B%.*}_$N.${B##*.}" ]; do N=$((N+1)); [ $N -gt 50 ] && break; done
      DST="$INBOX/$DD/${B%.*}_$N.${B##*.}"
    fi

    if [ "$APPLY" = "1" ]; then
      mkdir -p "$INBOX/$DD" 2>/dev/null
      if mv -f "$F" "$DST" 2>/dev/null; then
        RELDST=$(printf '%s' "$DST" | sed "s#^$INBOX/##")
        ID=$(printf '%s:%s' "$DEVTAG:$SRC/$B" "$S" | "$BB" sha256sum | cut -c1-16)
        ledger_add "$ID" "$B" "$S" "mvdate" "inbox/$SRC/$B" "$RELDST" "按拍摄日期 $DD 归位"
        log "MOVED $SRC/$B -> $RELDST"
        MOVED=$((MOVED+1))
        SRC_CNT=$((SRC_CNT+1))
      else
        log "FAIL  $SRC/$B"; echo "FAIL  $F"; FAILN=$((FAILN+1))
      fi
    else
      echo "PLAN  $SRC/$B -> $DD/"
    fi
  done
  # 本来源有搬动才记数，中文名给用户看。
  # CamScanner 与 scanner 都叫「扫描」，用统一计数器累加，避免出现两条「扫描」。
  if [ "$SRC_CNT" -gt 0 ]; then
    case "$SRC" in
      Camera|Pantry)      N_CAM=$((N_CAM + SRC_CNT)) ;;
      CamScanner|scanner) N_SCAN=$((N_SCAN + SRC_CNT)) ;;
      family-kid)               N_SON=$((N_SON + SRC_CNT)) ;;
      id-card)             N_ID=$((N_ID + SRC_CNT)) ;;
    esac
  fi
done

ledger_rotate 2>/dev/null
log "=== 完成: moved=$MOVED dup=$DUPN fail=$FAILN skip=$SKIPN ==="
# 拼来源明细，最后一行是给 daemon.sh 解析的机器可读串
SRCLIST=""
[ "$N_CAM" -gt 0 ]  && SRCLIST="${SRCLIST}相机 ${N_CAM} · "
[ "$N_SCAN" -gt 0 ] && SRCLIST="${SRCLIST}扫描 ${N_SCAN} · "
[ "$N_SON" -gt 0 ]  && SRCLIST="${SRCLIST}family-kid ${N_SON} · "
[ "$N_ID" -gt 0 ]   && SRCLIST="${SRCLIST}id-card ${N_ID} · "
SRCLIST=$(printf '%s' "$SRCLIST" | sed 's/ · $//')
echo "moved=$MOVED dup=$DUPN fail=$FAILN skip=$SKIPN src=$SRCLIST"