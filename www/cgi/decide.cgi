#!/system/bin/sh
# decide.cgi — 接收一条人工判定，追加写 decisions.jsonl
# 若判定为「存档」且选择新建事件，则**当场登记事件**，后续存档可直接在下拉里选到
DATA=/data/media/0/nasbak/state
ARC=/data/media/0/nasbak/archive
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

if [ "$REQUEST_METHOD" != "POST" ]; then
  echo '{"ok":false,"err":"POST only"}'; exit 0
fi

LEN=${CONTENT_LENGTH:-0}
case "$LEN" in ''|*[!0-9]*) LEN=0 ;; esac
[ "$LEN" -gt 8192 ] && { echo '{"ok":false,"err":"body too large"}'; exit 0; }
BODY=$(head -c "$LEN" 2>/dev/null)

getf() {
  printf '%s' "$BODY" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | head -1
}

ID=$(getf id)
ACT=$(getf action)
EV=$(getf event)
TOPIC=$(getf topic)
CATIN=$(getf cat)

# --- 校验：分类白名单（人工可纠正 AI 判错的类别） ---
case "$CATIN" in
  work|home|screenshot|video|other) ;;
  *) CATIN="" ;;
esac

# --- 校验：id 必须是 16 位小写十六进制 ---
case "$ID" in
  ''|*[!0-9a-f]*) echo '{"ok":false,"err":"bad id"}'; exit 0 ;;
esac
[ ${#ID} -eq 16 ] || { echo '{"ok":false,"err":"bad id len"}'; exit 0; }

# --- 校验：动作白名单 ---
case "$ACT" in
  del|keep|hold|arc) ;;
  *) echo '{"ok":false,"err":"bad action"}'; exit 0 ;;
esac

# --- 清洗：event 只允许 ev- 开头 + 数字，其余丢弃 ---
case "$EV" in
  ev-[0-9]*) case "$EV" in *[!0-9a-zA-Z-]*) EV="" ;; esac ;;
  *) EV="" ;;
esac

# --- 清洗：topic 去危险字符，截断 20 字 ---
TOPIC=$(printf '%s' "$TOPIC" | sed 's/[/\\:*?"<>|]//g' | tr -d '\r\n\t' | cut -c1-60)

NOW=$(date +%s)
touch "$DATA/decisions.jsonl" "$DATA/events.jsonl" 2>/dev/null

# --- 校验：存档必须二选一，不能既不选事件也不填主题 ---
# 缺了这道，apply 会兜底建出「未命名」夹，事后没法追溯是哪个事件
if [ "$ACT" = "arc" ] && [ -z "$EV" ] && [ -z "$TOPIC" ]; then
  echo '{"ok":false,"err":"存档需选择已有事件或填写主题"}'; exit 0
fi

# --- 校验：指定的已有事件必须真实存在 ---
# 前端下拉可能已过期（比如事件被清理），放过去就会静默新建一个空主题事件
if [ "$ACT" = "arc" ] && [ -n "$EV" ]; then
  if ! grep -qF "\"event_id\":\"$EV\"" "$DATA/events.jsonl" 2>/dev/null; then
    echo '{"ok":false,"err":"所选事件不存在，请刷新页面后重选"}'; exit 0
  fi
fi

# 本条生效的分类：人工选的优先，没传就回落到 AI 判的
AL=$(grep -F "\"id\":\"$ID\"" "$DATA/analysis.jsonl" 2>/dev/null | head -1)
if [ -n "$CATIN" ]; then
  CATSEL="$CATIN"
else
  CATSEL=$(printf '%s' "$AL" | sed -n 's/.*"cat":"\([^"]*\)".*/\1/p')
  case "$CATSEL" in
    work|home|screenshot|video|other|unclassified) ;;
    *) CATSEL="other" ;;
  esac
fi

EVID=""
if [ "$ACT" = "arc" ] && [ -z "$EV" ] && [ -n "$TOPIC" ]; then
  # 取该文件的拍摄日期（类别用上面算好的 CATSEL）
  CAT="$CATSEL"
  DD=$(printf '%s' "$AL" | sed -n 's/.*"date":"\([^"]*\)".*/\1/p')
  [ -z "$DD" ] && DD=$(date +%Y-%m-%d 2>/dev/null)
  case "$CAT" in
    work|home|screenshot|video|other|unclassified) ;;
    *) CAT="other" ;;
  esac
  TP=$(printf '%s' "$TOPIC" | sed 's@[/\\:*?"<>|]@@g' | tr -d '\r\n\t' | cut -c1-20)
  [ -z "$TP" ] && TP="未命名"
  YYYY=$(printf '%s' "$DD" | cut -c1-4)
  YM=$(printf '%s' "$DD" | cut -c1-7)

  # 夹名唯一：同一天同主题重复出现时加序号（查目录 + 查事件表，两者皆算占用）
  BASE="${DD}_${CAT}_${TP}"
  FOLDER="$BASE"; SEQ=1
  while :; do
    if [ ! -d "$ARC/$YM/$FOLDER" ] && ! grep -qF "\"folder\":\"$FOLDER\"" "$DATA/events.jsonl" 2>/dev/null; then
      break
    fi
    SEQ=$((SEQ+1)); FOLDER="${BASE}_${SEQ}"
    [ "$SEQ" -gt 30 ] && break
  done

  # 事件 id 按当天序号递增，避免不同主题撞号
  D8=$(printf '%s' "$DD" | tr -d '-')
  N=1
  while grep -qF "\"event_id\":\"ev-$D8-$(printf '%02d' "$N")\"" "$DATA/events.jsonl" 2>/dev/null; do
    N=$((N+1)); [ "$N" -gt 99 ] && break
  done
  EVID="ev-$D8-$(printf '%02d' "$N")"

  printf '{"event_id":"%s","start_date":"%s","slug":"%s","topic":"%s","folder":"%s","status":"open","counts":{"i":0,"v":0},"ts":%s}\n' \
    "$EVID" "$DD" "$CAT" "$TP" "$FOLDER" "$NOW" >> "$DATA/events.jsonl"

  # 用新建的事件 id 作为本条的 event 落盘
  EV="$EVID"
fi

# 同一 id 允许覆盖：新判定先写，读取时取最后一条
printf '{"id":"%s","action":"%s","event":"%s","topic":"%s","cat":"%s","by":"web","ts":%s}\n' \
  "$ID" "$ACT" "$EV" "$TOPIC" "$CATSEL" "$NOW" >> "$DATA/decisions.jsonl"

# 去重后计数（同一 id 多条取最后一条）
UNIQ=$(sed -n 's/.*"id":"\([0-9a-f]\{16\}\)".*/\1/p' "$DATA/decisions.jsonl" | sort -u | wc -l | tr -d ' ')

printf '{"ok":true,"id":"%s","action":"%s","event_id":"%s","cat":"%s","decided":%s}\n' \
  "$ID" "$ACT" "$EVID" "$CATSEL" "$UNIQ"
