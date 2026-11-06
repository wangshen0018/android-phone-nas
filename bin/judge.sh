#!/system/bin/sh
# judge.sh — 照片判读：登记新文件 → 只判新增 → 重建页面数据
#
# 用法:
#   judge.sh              完整流程（登记 + 判读 + 重建页面数据）
#   judge.sh --ingest     只登记（轻量，扫描建硬链接，不调模型）
#
# 关键设计(2026-11-02):
#   1. 队列优先：ingest 把新文件id写入 state/pending.queue，判读只读队列，
#      不再遍历 3000+ 个 loc-*.tsv（那是一次几十秒的开销）。
#   2. 只判新增：JUDGE_MAXAGE_DAYS 控制只判最近 N 天内 mtime 的文件，
#      历史积压不动。设为 0 则判全部。
#   3. 熔断修好：FAILCNT 是连续失败计数，成功即归零；熔断时本轮跳过不落盘，
#      下次仍可重判（旧版把熔断结果写进 analysis 导致永久无法重判）。
#   4. 不出建议：判读结果只有分类+描述+模型+耗时，没有 suggest 字段。
#
# 幂等保证:
#   - 判读结果落 $ST/analysis/<id>.json，同一 id 覆盖写
#   - $ST/analysis.jsonl 只追加审计轨迹
#   - 已判过的 id 直接跳过，中断后重跑不重复计费
#
# 2026-11-03 改动（互斥锁）：
#   本脚本用固定名中间文件（$LOGD/_data.json.tmp、$LOGD/_scan.txt），
#   两个实例并发时会互相删掉对方正在读的文件，出现「build: 失败(JSON不完整)」
#   这种假报错；两次 --judge 并发还会让同一批照片调两遍 VLM，等于双倍花钱。
#   现在整段流程用 mkdir 原子锁（bin/lib-lock.sh）保护，拿不到锁直接退出。

BASE=/data/media/0/nasbak
# 锁库必须存在，否则宁可整个脚本不跑（并发下的假报错比不跑更难排查）
if [ -r /data/adb/nasbak/bin/lib-lock.sh ]; then
  . /data/adb/nasbak/bin/lib-lock.sh
else
  echo "缺少 /data/adb/nasbak/bin/lib-lock.sh，无法保证单实例，本次退出" >&2
  exit 1
fi
INBOX=$BASE/inbox
ST=$BASE/state
ARC=$BASE/archive
WWW=/data/adb/nasbak/www
LOGD=/data/adb/nasbak/logs
BB=/data/adb/magisk/busybox
VLMSRC=/data/adb/nasbak/bin/vlm_classify.sh
VLM=/data/adb/nasbak/bin/vlm_run.sh
LOG=$LOGD/judge.log
QUEUE=$ST/pending.queue
# ---------- 媒体副本目录（2026-11-03 迁移） ----------
# 副本必须和 inbox/archive 在同一挂载，否则 ln 必失败（Cross-device link）。
# Android 把 /data/media/0（用户存储）与 /data/adb（root 区）刻意隔离，
# 旧版把副本放 $WWW/media，ln 每次失败退化成 cp，3164 份副本白占 7.9G。
# 现在副本实体在 $ST/media（media/0 同侧，ln 实测成功 nlink=2），
# www 根下留 symlink $WWW/media → $ST/media，httpd 的 URL 完全不用改
# （busybox httpd 允许跟随符号链接，SELinux Enforcing 下实测 HTTP 200）。
MEDIA_DIR=$ST/media
WWW_LINK=$WWW/media
ensure_media_layout() {
  mkdir -p "$MEDIA_DIR" 2>/dev/null
  if [ -L "$WWW_LINK" ]; then
    cur=$(readlink "$WWW_LINK" 2>/dev/null)
    [ "$cur" = "$MEDIA_DIR" ] || ln -sfn "$MEDIA_DIR" "$WWW_LINK" 2>/dev/null
  elif [ -d "$WWW_LINK" ]; then
    # 旧实体目录 → 改名让位。mv 失败时绝不 ln：否则 ln -sfn 会钻到目录里
    # 建出 www/media/media 这种嵌套链接。
    if mv -f "$WWW_LINK" "${WWW_LINK}.old-legacy" 2>/dev/null; then
      ln -sfn "$MEDIA_DIR" "$WWW_LINK" 2>/dev/null
    fi
  else
    ln -sfn "$MEDIA_DIR" "$WWW_LINK" 2>/dev/null
  fi
}
ONLY_INGEST=0
ONLY_JUDGE=0
case "${1:-}" in
  --ingest) ONLY_INGEST=1 ;;
  --judge)  ONLY_JUDGE=1 ;;
esac

mkdir -p "$ST" "$ST/analysis" "$MEDIA_DIR" "$LOGD" 2>/dev/null
touch "$LOG" "$ST/analysis.jsonl" "$QUEUE" 2>/dev/null
ensure_media_layout

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'; }
mkid() { printf '%s:%s' "$1" "$2" | $BB sha256sum 2>/dev/null | cut -c1-16; }

# ---------- 单实例锁 ----------
# ingest 与 judge 共用 pending.queue 与 analysis/ 目录，judge 还会重写队列
# （mv -f QKEEP QUEUE），并发跑会丢条目、也会让 build 读到半截 JSON。
# 两次 --judge 并发更糟：同一批照片会调两遍 VLM，直接双倍花钱。
# 拿不到锁就退出（不阻塞、不等待），本轮留到下次调度。
# ingest 允许重试几次（最多约 3 秒）：它最轻、常与手动操作撞车，
# 等一下就能接上；判读可能跑几分钟，就不等了，撞上就让下一轮补。
if [ "$ONLY_INGEST" = "1" ]; then LOCK_TRIES=3; else LOCK_TRIES=1; fi
if ! lock_acquire judge "$LOCK_TRIES"; then
  log "judge: 已有实例在运行，本次退出（未做任何改动）"
  echo "已有实例在运行，本次退出（未做任何改动）"
  exit 0
fi
trap 'lock_release judge' 0
trap 'lock_release judge; exit 1' INT TERM


# 拍摄日期：文件名优先 > mtime
fdate() {
  B=$(basename "$1")
  R=""
  case "$B" in
    *20[0-9][0-9]-[01][0-9]-[0-3][0-9]*)
      R=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]-[01][0-9]-[0-3][0-9]\).*/\1/p' | head -1) ;;
    *20[0-9][0-9][01][0-9][0-3][0-9]_*)
      R=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_.*/\1-\2-\3/p' | head -1) ;;
    *20[0-9][0-9]_[01][0-9]_[0-3][0-9]*)
      R=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]\)_\([01][0-9]\)_\([0-3][0-9]\)_.*/\1-\2-\3/p' | head -1) ;;
    *1[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
      TS=$(printf '%s' "$B" | sed -n 's/.*[^0-9]\(1[0-9]\{12\}\)[^0-9].*/\1/p' | head -1)
      if [ -n "$TS" ]; then
        TS_S=$(printf '%s' "$TS" | sed 's/...$//')
        R=$($BB date -d "@$TS_S" +%Y-%m-%d 2>/dev/null)
      fi ;;
  esac
  [ -z "$R" ] && R=$($BB date -d "@$2" +%Y-%m-%d 2>/dev/null)
  printf '%s' "$R"
}

# ---------- 1. 登记 ----------
ingest() {
  NEW=0; TOTAL=0; OLDING=0
  INGEST_MAXAGE_DAYS=${INGEST_MAXAGE_DAYS:-2}
  ICUT=$(( $(date +%s) - INGEST_MAXAGE_DAYS * 86400 ))
  SCAN=$LOGD/_scan.$$.txt
  # 2026-11-06：迅雷成品已改投 downloads/Thunder，不再进 inbox；
  # 这里再加一层路径排除作防御，防止将来改回 inbox/Thunder 时把视频灌进 VLM 队列。
  find ${INGEST_ROOT:-$INBOX} -type f \
    ! -path '*/Thunder/*' ! -path '*/downloads/*' ! -path '*/_dup_backup/*' \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \
       -o -iname '*.webp' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.3gp' \
       -o -iname '*.m4v' \) 2>/dev/null > "$SCAN"
  while IFS= read -r F; do
    case "$F" in */.trashed*|*/.pending*|*/.thumbnails*) continue ;; esac
    REL=$(printf '%s' "$F" | sed "s#^$INBOX/##")
    # _dup_backup 是去重副本的长期存放处，不是待判素材：既不入队，也不建媒体链接。
    # 之前全部扫进来，导致 1472 个重复件霸占待判列表、还灌了 1101 条熔断伪记录。
    case "$REL" in _dup_backup/*) continue ;; esac
    SZ=$($BB stat -c %s "$F" 2>/dev/null)
    [ -z "$SZ" ] || [ "$SZ" = "0" ] && continue
    ID=$(mkid "$REL" "$SZ")
    TOTAL=$((TOTAL+1))
    EXT=$(printf '%s' "${REL##*.}" | tr 'A-Z' 'a-z')
    # 媒体硬链接供 httpd 直出（同分区零拷贝，失败退化为复制）
    if [ ! -f "$MEDIA_DIR/$ID.$EXT" ]; then
      ln -f "$F" "$MEDIA_DIR/$ID.$EXT" 2>/dev/null || cp -f "$F" "$MEDIA_DIR/$ID.$EXT" 2>/dev/null
    fi
    # 位置映射已废弃：旧版写 loc-*.tsv，build() 遍历它导致重复件混进列表。
    # 现在改为队列(inbox 内)+analysis 双源，loc 文件不再生成（已归档 state/_loc_old/）。
    # 未判过的 → 进队列（判读只读队列，避免每次遍历全量文件）
    # 但只收「新增」：mtime 早于 INGEST_MAXAGE_DAYS 的历史积压不进队列，
    # 否则每次 ingest 都会把几千个老文件重新灌回队列。
    if [ ! -f "$ST/analysis/$ID.json" ]; then
      NEW=$((NEW+1))
      FMT=$($BB stat -c %Y "$F" 2>/dev/null)
      [ -z "$FMT" ] && FMT=$(date +%s)
      if [ "$INGEST_MAXAGE_DAYS" -gt 0 ] && [ "$FMT" -lt "$ICUT" ]; then
        OLDING=$((OLDING+1))
      else
        if ! grep -qF "$ID	" "$QUEUE" 2>/dev/null; then
          printf '%s\t%s\n' "$ID" "$REL" >> "$QUEUE"
        fi
      fi
    fi
  done < "$SCAN"
  rm -f "$SCAN"
  log "ingest: 扫描 $TOTAL 个，新增待判 $NEW 个，历史跳过 $OLDING 个，队列 $(wc -l < "$QUEUE" 2>/dev/null | tr -d ' ') 条"
}

# ---------- 2. 判读 ----------
judge_all() {
  sed 's/^MAXSZ=.*/MAXSZ=12582912/' "$VLMSRC" > "$VLM" 2>/dev/null
  [ -s "$VLM" ] || cp -f "$VLMSRC" "$VLM"
  chmod 755 "$VLM" 2>/dev/null

  touch "$QUEUE" 2>/dev/null
  # 队列去重（同 id 只保留一条，取最新的 rel）
  awk -F'\t' '$1!="" {a[$1]=$0} END{for(k in a) print a[k]}' "$QUEUE" > "$QUEUE.$$.ded" 2>/dev/null
  mv -f "$QUEUE.$$.ded" "$QUEUE" 2>/dev/null

  # 待判数：队列中还没有 analysis 的
  PENDING=0
  while IFS='	' read -r _qi _qr; do
    [ -z "$_qi" ] && continue
    [ -f "$ST/analysis/$_qi.json" ] || PENDING=$((PENDING+1))
  done < "$QUEUE"
  log "judge: 队列待判 $PENDING 个"
  [ "$PENDING" -eq 0 ] && return 0

  BATCH="$(date +%Y-%m-%d)"
  ROUND=0; FAILCNT=0; FAILTOT=0; SKIPCNT=0; OLDCNT=0; OKCNT=0; FAILMAX=3
  JUDGE_MAXAGE_DAYS=${JUDGE_MAXAGE_DAYS:-2}
  CUT=$(( $(date +%s) - JUDGE_MAXAGE_DAYS * 86400 ))

  QKEEP="$QUEUE.$$.keep"
  : > "$QKEEP" 2>/dev/null

  while IFS='	' read -r ID REL; do
    [ -z "$ID" ] && continue
    # 已判过 → 出队
    [ -f "$ST/analysis/$ID.json" ] && continue
    [ -z "$REL" ] && continue

    SRC="$INBOX/$REL"
    if [ ! -f "$SRC" ]; then
      log "  [$((ROUND+1))/$PENDING] 源文件已不在 inbox，出队 $REL"
      continue
    fi
    SZ=$($BB stat -c %s "$SRC" 2>/dev/null)
    EXT=$(printf '%s' "${REL##*.}" | tr 'A-Z' 'a-z')
    NAME=$(basename "$REL")
    MT=$($BB stat -c %Y "$SRC" 2>/dev/null)
    [ -z "$MT" ] && MT=$(date +%s)
    ROUND=$((ROUND+1))
    FDATE=$(fdate "$REL" "$MT")

    # ---- 只判新增：mtime 早于时间窗的直接出队，永不判读 ----
    # 历史积压文件不写回 QKEEP，所以下一轮不会再出现，队列自然收敛
    if [ "$JUDGE_MAXAGE_DAYS" -gt 0 ] && [ "$MT" -lt "$CUT" ]; then
      OLDCNT=$((OLDCNT+1))
      continue
    fi

    T0=$(date +%s)
    CAT=""; DESC=""; MODEL=""; SUG=""

    case "$EXT" in
      jpg|jpeg|png|heic|webp)
        if [ "$FAILCNT" -ge "$FAILMAX" ]; then
          SKIPCNT=$((SKIPCNT+1))
          printf '%s\t%s\n' "$ID" "$REL" >> "$QKEEP"
          log "  [$ROUND/$PENDING] skip | 连续失败达上限($FAILMAX)，留队下次 | $REL"
          continue
        fi
        OUT=$(sh "$VLM" "$SRC" 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -1)
        if [ -n "$OUT" ]; then
          CAT=$(printf '%s' "$OUT" | sed 's/|.*//' | tr -d ' \t')
          DESC=$(printf '%s' "$OUT" | sed 's/^[^|]*|//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
          MODEL="minicpm-v/zhipu"
        fi
        if [ -z "$DESC" ]; then
          sleep 2
          OUT=$(sh "$VLM" "$SRC" 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -1)
          if [ -n "$OUT" ]; then
            CAT=$(printf '%s' "$OUT" | sed 's/|.*//' | tr -d ' \t')
            DESC=$(printf '%s' "$OUT" | sed 's/^[^|]*|//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            MODEL="minicpm-v/zhipu(retry)"
          fi
        fi
        case "$CAT" in work|home|screenshot|video|other) ;; *) CAT="other" ;; esac
        case "$DESC" in
          *过大跳过*) CAT="unclassified"; DESC="超出模型单图上限，未判读" ;;
          *识别失败*|*文件不存在*|*无可用Key*|*b64失败*) CAT="unclassified"; DESC="识别失败，待人工" ;;
        esac
        [ -z "$DESC" ] && { CAT="unclassified"; DESC="模型无返回，待人工"; }
        # 失败：计数、留队、不进 analysis（避免污染，下次可重判）
        if [ "$CAT" = "unclassified" ]; then
          FAILCNT=$((FAILCNT+1)); FAILTOT=$((FAILTOT+1))
          printf '%s\t%s\n' "$ID" "$REL" >> "$QKEEP"
          log "  [$ROUND/$PENDING] fail | $DESC | $REL（留队可重判）"
          continue
        fi
        FAILCNT=0
        ;;
      mp4|mov|3gp|m4v)
        CAT="video"; MODEL="rule:video"
        DESC="视频，$(awk -v s="$SZ" 'BEGIN{printf "%.1f", s/1048576}')MB，未做画面识别"
        FAILCNT=0
        ;;
      *)
        CAT="unclassified"; DESC="(不支持的扩展名)"
        ;;
    esac

    T1=$(date +%s); MS=$(( (T1-T0)*1000 ))
    # 结果：分类+描述+模型+耗时，不含 suggest
    LINE=$(printf '{"id":"%s","name":"%s","rel":"%s","size":%s,"mtime":%s,"date":"%s","type":"%s","cat":"%s","desc":"%s","model":"%s","batch":"%s","ms":%s,"ts":%s}' \
      "$ID" "$(jesc "$NAME")" "$(jesc "$REL")" "$SZ" "$MT" "$FDATE" "$EXT" \
      "$CAT" "$(jesc "$DESC")" "$(jesc "$MODEL")" "$BATCH" "$MS" "$(date +%s)")
    printf '%s\n' "$LINE" > "$ST/analysis/$ID.json"
    printf '%s\n' "$LINE" >> "$ST/analysis.jsonl"
    log "  [$ROUND/$PENDING] $CAT | $DESC | ${MS}ms | $NAME"
    OKCNT=$((OKCNT+1))
    # 成功 → 出队（不写回 QKEEP）
    case "$EXT" in mp4|mov|3gp|m4v) ;; *) sleep 2 ;; esac
  done < "$QUEUE"

  mv -f "$QKEEP" "$QUEUE" 2>/dev/null
  log "judge: 本轮结束 成功=$OKCNT 失败=$FAILTOT 熔断跳过=$SKIPCNT 跳过旧文件=$OLDCNT 处理=$ROUND 待判=$PENDING"
}

# ---------- 3. 重建页面数据 ----------
# 数据源只有一个：pending.queue（真待判）+ analysis 里"文件当前还在 inbox"的记录。
# 早先这里遍历 loc-*.tsv —— 那是旧架构的遗留定位文件，里面 1472 条指向 _dup_backup
# 的重复副本，导致已存档的证件等文件反复出现在待判列表里。loc 已归档到 state/_loc_old/。
build() {
  TMP=$LOGD/_data.json.$$.tmp
  {
    printf '{"port":8083,"batch":"%s","generated":%s,"items":[' "$(date +%Y%m%d-%H%M)" "$(date +%s)"
    FIRST=1

    # (a) 待判队列：pending.queue 每行 "id<TAB>rel"
    if [ -s "$QUEUE" ]; then
      while IFS='	' read -r ID REL; do
        [ -z "$ID" ] && continue
        [ -z "$REL" ] && continue
        SRC="$INBOX/$REL"
        [ -f "$SRC" ] || continue          # 文件已不在（被移动/去重）→ 不列
        # 已有分析结果的走 (b)，避免重复
        [ -s "$ST/analysis/$ID.json" ] && continue
        SZ=$($BB stat -c %s "$SRC" 2>/dev/null); [ -z "$SZ" ] && SZ=0
        MT=$($BB stat -c %Y "$SRC" 2>/dev/null); [ -z "$MT" ] && MT=$(date +%s)
        EXT="${REL##*.}"
        NAME="${REL##*/}"
        FDATE=$(fdate "$REL" "$MT")
        [ "$FIRST" = "1" ] || printf ','
        printf '{"id":"%s","name":"%s","rel":"%s","size":%s,"mtime":%s,"date":"%s","type":"%s","cat":"pending","desc":"待判读（尚未调用 AI）","model":"-","batch":"%s","ms":0,"ts":0}' \
          "$ID" "$(jesc "$NAME")" "$(jesc "$REL")" "$SZ" "$MT" "$FDATE" "$EXT" "$BATCH"
        FIRST=0
      done < "$QUEUE"
    fi

    # (b) 已判但文件仍在 inbox 的：保留在列表里显示描述与判定状态。
    #     条件"文件还在"很关键 —— 已归档/去重的自然消失，不用另做反查。
    #     但 _dup_backup 是去重副本的长期存放处，里面的文件永远"还在"，
    #     必须显式排除，否则重复件会一直霸占待判列表。
    for AJ in "$ST"/analysis/*.json; do
      [ -s "$AJ" ] || continue
      REL=$(sed -n 's/.*"rel":"\([^"]*\)".*/\1/p' "$AJ" | head -1)
      [ -z "$REL" ] && continue
      case "$REL" in _dup_backup/*) continue ;; esac
      [ -f "$INBOX/$REL" ] || continue
      [ "$FIRST" = "1" ] || printf ','
      tr -d '\r\n' < "$AJ"
      FIRST=0
    done

    printf ']}'
  } > "$TMP" 2>/dev/null
  # 末字节校验：不能带结尾换行 —— printf ']}\n' 之后 tail -c 1 取到的是换行符，
  # 命令替换又会把行尾换行剥掉，结果永远是空串，等于校验必然失败（踩过）。
  if [ -s "$TMP" ] && [ "$(tail -c 2 "$TMP")" = "]}" ]; then
    mv -f "$TMP" "$WWW/data.json"
    log "build: data.json $(wc -c < "$WWW/data.json") 字节"
  else
    log "build: 失败(JSON不完整)"
    rm -f "$TMP"
  fi
}

# ---------- 主流程 ----------
if [ "$ONLY_INGEST" = "1" ]; then
  ingest
  exit 0
fi

if [ "$ONLY_JUDGE" = "1" ]; then
  judge_all
  build
  exit 0
fi

ingest
judge_all
build