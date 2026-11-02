#!/system/bin/sh
# 小批量判读：只判最近 N 个待判项（默认 10 个）
# 不跑完整 judge.sh（那会判 540 个），这里逐条判断

BASE=/data/media/0/nasbak
INBOX=$BASE/inbox
ST=$BASE/state
WWW=/data/adb/nasbak/www
LOGD=/data/adb/nasbak/logs
BB=/data/adb/magisk/busybox
VLM=/data/adb/nasbak/bin/vlm_run.sh
LOG=$LOGD/judge.log
LIMIT=${1:-10}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 拍摄日期（与 judge.sh 一致）
fdate() {
  B=$(basename "$1"); R=""
  case "$B" in
    *20[0-9][0-9]-[01][0-9]-[0-3][0-9]*) R=$(printf '%s' "$B" | sed -n 's/.*\(20[0-9][0-9]-[01][0-9]-[0-3][0-9]\).*/\1/p' | head -1) ;;
  esac
  [ -z "$R" ] && R=$(printf '%s' "$B" | sed -n 's/.*[^0-9]\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_[0-9][0-9][0-9][0-9][0-9][0-9].*/\1-\2-\3/p' | head -1)
  [ -z "$R" ] && R=$(printf '%s' "$B" | sed -n 's/^\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_[0-9][0-9][0-9][0-9][0-9][0-9].*/\1-\2-\3/p' | head -1)
  [ -z "$R" ] && case "$B" in
    *1[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
      TS=$(printf '%s' "$B" | sed -n 's/.*[^0-9]\(1[0-9]\{12\}\)[^0-9].*/\1/p' | head -1)
      [ -n "$TS" ] && R=$($BB date -d "@$(printf '%s' "$TS" | sed 's/...$//')" +%Y-%m-%d 2>/dev/null) ;;
  esac
  [ -z "$R" ] && R=$($BB date -d "@$($BB stat -c %Y "$1" 2>/dev/null || echo 0)" +%Y-%m-%d 2>/dev/null)
  [ -z "$R" ] && R="unknown"
  printf '%s' "$R"
}
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'; }

# 取最近的 N 个待判项（按文件 mtime 倒序）
LIST=/data/local/tmp/_todo.txt
: > "$LIST"
for L in "$ST"/loc-*.tsv; do
  [ -s "$L" ] || continue
  ID=$(basename "$L" .tsv | sed 's/^loc-//')
  [ -f "$ST/analysis/$ID.json" ] && continue
  IFS='	' read -r ID2 REL SZ EXT < "$L"
  SRC="$INBOX/$REL"
  [ -f "$SRC" ] || continue
  MT=$($BB stat -c %Y "$SRC" 2>/dev/null || echo 0)
  printf '%s\t%s\t%s\t%s\t%s\n' "$MT" "$ID" "$REL" "$SZ" "$EXT" >> "$LIST"
done

TOTAL=$(wc -l < "$LIST")
echo "待判总数: $TOTAL，本次处理前 $LIMIT 个"
echo ""

sort -rn "$LIST" | head -$LIMIT > "$LIST.n"
N=0
while IFS='	' read -r MT ID REL SZ EXT; do
  N=$((N+1))
  SRC="$INBOX/$REL"
  NAME=$(basename "$REL")
  FD=$(fdate "$REL" "$MT")
  echo "[$N/$LIMIT] $NAME"

  T0=$(date +%s)
  CAT=""; DESC=""; MODEL=""
  case "$EXT" in
    mp4|mov|3gp|m4v)
      CAT="video"; DESC="视频，未做画面识别"; MODEL="rule:video"
      ;;
    *)
      OUT=$(sh "$VLM" "$SRC" 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -1)
      if [ -n "$OUT" ]; then
        CAT=$(printf '%s' "$OUT" | sed 's/|.*//' | tr -d ' \t')
        DESC=$(printf '%s' "$OUT" | sed 's/^[^|]*|//' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        MODEL="minicpm-v"
      fi
      case "$CAT" in work|home|screenshot|other) ;; *) CAT="other" ;; esac
      [ -z "$DESC" ] && { CAT="unclassified"; DESC="识别失败，待人工"; }
      ;;
  esac
  MS=$(( ($(date +%s) - T0) * 1000 ))

  # 决定 suggest
  case "$CAT" in
    work|home) SUG="keep" ;;
    screenshot) SUG="del" ;;
    *) SUG="hold" ;;
  esac

  # 写 analysis/<id>.json
  printf '{"id":"%s","name":"%s","rel":"%s","size":%s,"mtime":%s,"date":"%s","type":"%s","cat":"%s","desc":"%s","model":"%s","suggest":"%s","batch":"%s","ms":%s,"ts":%s}\n' \
    "$ID" "$(jesc "$NAME")" "$(jesc "$REL")" "${SZ:-0}" "${MT:-0}" "$FD" "${EXT:-jpg}" \
    "$CAT" "$(jesc "$DESC")" "$MODEL" "$SUG" "$(date +%F)" "$MS" "$(date +%s)" \
    > "$ST/analysis/$ID.json"

  # 同时追加到 analysis.jsonl（审计）
  cat "$ST/analysis/$ID.json" >> "$ST/analysis.jsonl"

  echo "     → $CAT | $DESC"
  log "  [$N/$LIMIT] $CAT | $DESC | ${MS}ms | $NAME"
done < "$LIST.n"

rm -f "$LIST" "$LIST.n"
echo ""
echo "=== 完成 $N 个 ==="
echo "已判总数: $(ls "$ST"/analysis/*.json 2>/dev/null | wc -l)"
