#!/system/bin/sh
# apply.cgi — 「模拟执行」：把已判定的决策在沙箱内真实执行一遍，产出 receipts
# 沙箱内动作，绝不碰 /data/media/0/DCIM 与真实 /data/adb/srv/data
DATA=/data/media/0/nasbak/state
STG=/data/media/0/nasbak/inbox
ARC=/data/media/0/nasbak/archive
WWW=/data/adb/nasbak/www
BB=/data/adb/magisk/busybox
. /data/adb/nasbak/bin/lib-ledger.sh 2>/dev/null

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

if [ "$REQUEST_METHOD" != "POST" ]; then
  echo '{"ok":false,"err":"POST only"}'; exit 0
fi

touch "$DATA/decisions.jsonl" "$DATA/receipts.jsonl" "$DATA/events.jsonl" 2>/dev/null

# 已执行过的 id（幂等：重跑不会二次执行）
DONE=$(sed -n 's/.*"id":"\([0-9a-f]\{16\}\)","action".*/\1/p' "$DATA/receipts.jsonl" | sort -u)
has_done() { printf '%s\n' "$DONE" | grep -qx "$1"; }

# 取出所有被判过的 id（去重，保持首次出现顺序）
IDS=$(sed -n 's/.*"id":"\([0-9a-f]\{16\}\)".*/\1/p' "$DATA/decisions.jsonl" | awk '!seen[$0]++')

NOW=$(date +%s)
EXP=$((NOW + 2592000))
CNT_D=0; CNT_K=0; CNT_H=0; CNT_A=0; CNT_S=0; CNT_E=0
CNT_MISS=0
FIRST=1
printf '{"ok":true,"items":['

for ID in $IDS; do
  if has_done "$ID"; then CNT_S=$((CNT_S+1)); continue; fi

  # 同一 id 以最后一条决策为准
  LINE=$(grep -F "\"id\":\"$ID\"" "$DATA/decisions.jsonl" 2>/dev/null | tail -1)
  [ -z "$LINE" ] && continue
  ACT=$(printf '%s' "$LINE" | sed -n 's/.*"action":"\([a-z]*\)".*/\1/p')
  EV=$(printf '%s' "$LINE" | sed -n 's/.*"event":"\([^"]*\)".*/\1/p')
  TOPIC=$(printf '%s' "$LINE" | sed -n 's/.*"topic":"\([^"]*\)".*/\1/p')
  DCAT=$(printf '%s' "$LINE" | sed -n 's/.*"cat":"\([^"]*\)".*/\1/p')

  # ① 优先从 analysis.jsonl 取（有 AI 判读记录的）
  AL=$(grep -F "\"id\":\"$ID\"" "$DATA/analysis.jsonl" 2>/dev/null | head -1)
  if [ -n "$AL" ]; then
    NAME=$(printf '%s' "$AL" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
    REL=$(printf '%s' "$AL" | sed -n 's/.*"rel":"\([^"]*\)".*/\1/p')
    CAT=$(printf '%s' "$AL" | sed -n 's/.*"cat":"\([^"]*\)".*/\1/p')
    MT=$(printf '%s' "$AL" | sed -n 's/.*"mtime":\([0-9]*\).*/\1/p')
    FD=$(printf '%s' "$AL" | sed -n 's/.*"date":"\([^"]*\)".*/\1/p')
  else
    # ② 兜底：从 pending.queue 取（未判读就直接判定的情况）
    #    队列格式: id <TAB> rel
    #    旧版从 loc-<id>.tsv 取，但 loc 文件已废弃（build 曾因它把重复件混进列表，
    #    现已整体归档到 state/_loc_old/），改从队列取更可靠。
    REL=$(grep -F "$ID	" "$DATA/pending.queue" 2>/dev/null | head -1 | cut -f2)
    if [ -n "$REL" ]; then
      SZ0=0
      NAME=$(basename "$REL" 2>/dev/null)
      CAT=""; MT=""; FD=""
      if [ -f "$STG/$REL" ]; then
        SZ0=$(stat -c %s "$STG/$REL" 2>/dev/null); [ -z "$SZ0" ] && SZ0=0
        MT=$(stat -c %Y "$STG/$REL" 2>/dev/null)
      fi
      [ -z "$MT" ] && MT=$(date +%s)
      # 日期：文件名优先，取不到用 mtime
      case "$NAME" in
        *20[0-9][0-9]-[01][0-9]-[0-3][0-9]*) FD=$(printf '%s' "$NAME" | sed -n 's/.*\(20[0-9][0-9]-[01][0-9]-[0-3][0-9]\).*/\1/p' | head -1) ;;
      esac
      [ -z "$FD" ] && FD=$(printf '%s' "$NAME" | sed -n 's/.*[^0-9]\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_[0-9][0-9][0-9][0-9][0-9][0-9].*/\1-\2-\3/p' | head -1)
      [ -z "$FD" ] && FD=$(printf '%s' "$NAME" | sed -n 's/^\(20[0-9][0-9]\)\([01][0-9]\)\([0-3][0-9]\)_[0-9][0-9][0-9][0-9][0-9][0-9].*/\1-\2-\3/p' | head -1)
      [ -z "$FD" ] && case "$NAME" in
        *1[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
          TSX=$(printf '%s' "$NAME" | sed -n 's/.*[^0-9]\(1[0-9]\{12\}\)[^0-9].*/\1/p' | head -1)
          [ -n "$TSX" ] && FD=$($BB date -d "@$(printf '%s' "$TSX" | sed 's/...$//')" +%Y-%m-%d 2>/dev/null) ;;
      esac
      [ -z "$FD" ] && FD=$($BB date -d "@$MT" +%Y-%m-%d 2>/dev/null)
      [ -z "$FD" ] && FD=$($BB date +%Y-%m-%d)
    else
      # ③ 连 loc 都没有 → 跳过并记录（不再静默）
      CNT_MISS=$((CNT_MISS+1))
      continue
    fi
  fi

  RES=""; PATHOUT=""; NOTE=""

  case "$ACT" in
    del)
      rm -f "$STG/$REL"
      RES="deleted"; PATHOUT=""; NOTE="staging 副本已删；K80 本地待下次回家执行"
      CNT_D=$((CNT_D+1))
      ;;
    keep)
      RES="kept"; PATHOUT="$REL"; NOTE="K40 保留，K80 不动"
      CNT_K=$((CNT_K+1))
      ;;
    hold)
      RES="held"; PATHOUT="$REL"
      NOTE="不备份，K80 保留至 $($BB date -d "@$EXP" +%Y-%m-%d) 后自动删"
      CNT_H=$((CNT_H+1))
      ;;
    arc)
      # 1) 归入已有事件：查 events.jsonl 拿 folder
      FOLDER=""
      if [ -n "$EV" ]; then
        FOLDER=$(sed -n "s/.*\"event_id\":\"$EV\".*\"folder\":\"\([^\"]*\)\".*/\1/p" "$DATA/events.jsonl" | head -1)
      fi
      YYYY=""; YM=""
      if [ -n "$FOLDER" ]; then
        YYYY=$(printf '%s' "$FOLDER" | cut -c1-4)
        YM=$(printf '%s' "$FOLDER" | cut -c1-7)
        NOTE="已归入已有事件"
      else
        # 2) 新建事件：按命名规则生成夹名，并登记 events.jsonl
        #    分类以判定时人工确认的为准（decision 里的 cat），缺失才回落到 AI 判定
        SLUG="$DCAT"
        case "$SLUG" in
          work|home|screenshot|video|other|unclassified) ;;
          *) SLUG="$CAT" ;;
        esac
        case "$SLUG" in
          work|home|screenshot|video|other|unclassified) ;;
          *) SLUG="other" ;;
        esac
        TP="$TOPIC"
        [ -z "$TP" ] && TP="未命名"
        TP=$(printf '%s' "$TP" | sed 's@[/\\:*?"<>|]@@g' | tr -d '\r\n\t')
        [ -z "$TP" ] && TP="未命名"
        TP=$(printf '%s' "$TP" | cut -c1-20)
        DD="$FD"
        [ -z "$DD" ] && DD=$($BB date -d "@$MT" +%Y-%m-%d 2>/dev/null)
        [ -z "$DD" ] && DD=$($BB date +%Y-%m-%d)
        YYYY=$(printf '%s' "$DD" | cut -c1-4)
        YM=$(printf '%s' "$DD" | cut -c1-7)
        FOLDER="${DD}_${SLUG}_${TP}"
        # 同名夹已存在则加序号，不合并（一次事件一个夹）；目录与事件表都算占用
        BASE_FOLDER="$FOLDER"; SEQ=1
        while :; do
          if [ ! -d "$ARC/$YM/$FOLDER" ] && ! grep -qF "\"folder\":\"$FOLDER\"" "$DATA/events.jsonl" 2>/dev/null; then
            break
          fi
          SEQ=$((SEQ+1)); FOLDER="${BASE_FOLDER}_${SEQ}"
          [ "$SEQ" -gt 20 ] && break
        done
        D8=$(printf '%s' "$DD" | tr -d '-')
        N=1
        while grep -qF "\"event_id\":\"ev-$D8-$(printf '%02d' "$N")\"" "$DATA/events.jsonl" 2>/dev/null; do
          N=$((N+1)); [ "$N" -gt 99 ] && break
        done
        EVID="ev-$D8-$(printf '%02d' "$N")"
        printf '{"event_id":"%s","start_date":"%s","slug":"%s","topic":"%s","folder":"%s","status":"open","counts":{"i":0,"v":0},"ts":%s}\n' \
          "$EVID" "$DD" "$SLUG" "$TP" "$FOLDER" "$NOW" >> "$DATA/events.jsonl"
        CNT_E=$((CNT_E+1))
        NOTE="已新建事件 $EVID"
      fi

      mkdir -p "$ARC/$YM/$FOLDER"
      # 3) 移动 + 回读校验（大小必须一致，不一致就搬回去并标 failed）
      SRC_FILE="$STG/$REL"
      if [ -f "$SRC_FILE" ]; then
        OLD=$(stat -c %s "$SRC_FILE")
        if mv -f "$SRC_FILE" "$ARC/$YM/$FOLDER/$NAME" 2>/dev/null; then
          NEW=$(stat -c %s "$ARC/$YM/$FOLDER/$NAME" 2>/dev/null)
          if [ "$OLD" = "$NEW" ]; then
            RES="archived"; PATHOUT="$YM/$FOLDER/$NAME"
            ledger_add "$ID" "$NAME" "$OLD" "arc" "inbox/$REL" "$PATHOUT" 2>/dev/null
            CNT_A=$((CNT_A+1))
          else
            mv -f "$ARC/$YM/$FOLDER/$NAME" "$SRC_FILE" 2>/dev/null
            RES="failed"; PATHOUT=""; NOTE="校验字节数不符，已撤回"
          fi
        else
          RES="failed"; PATHOUT=""; NOTE="移动失败，保持原状"
        fi
      else
        RES="missing"; PATHOUT=""; NOTE="staging 里已无此文件"
      fi
      ;;
  esac

  [ "$FIRST" = "0" ] && printf ','
  FIRST=0
  printf '{"id":"%s","name":"%s","action":"%s","result":"%s","path":"%s","note":"%s"}' \
    "$ID" "$NAME" "$ACT" "$RES" "$PATHOUT" "$NOTE"

  printf '{"id":"%s","action":"%s","result":"%s","path":"%s","ts":%s}\n' \
    "$ID" "$ACT" "$RES" "$PATHOUT" "$NOW" >> "$DATA/receipts.jsonl"
done
printf '],"summary":{"executed":%s,"archived":%s,"deleted":%s,"kept":%s,"held":%s,"new_events":%s,"missing":%s}}' \
  $((CNT_A+CNT_D+CNT_K+CNT_H)) "$CNT_A" "$CNT_D" "$CNT_K" "$CNT_H" "$CNT_E" "$CNT_MISS"

# 清理孤儿事件：某事件既没有对应目录、也没有任何决策引用它 → 判定时建了又被改判留下的空壳
REF=$(sed -n 's/.*"event":"\(ev-[0-9a-zA-Z-]*\)".*/\1/p' "$DATA/decisions.jsonl" | sort -u)
KEEP="$DATA/events.jsonl.tmp"
: > "$KEEP"
while IFS= read -r L; do
  [ -z "$L" ] && continue
  E=$(printf '%s' "$L" | sed -n 's/.*"event_id":"\([^"]*\)".*/\1/p')
  F=$(printf '%s' "$L" | sed -n 's/.*"folder":"\([^"]*\)".*/\1/p')
  USED=0
  printf '%s\n' "$REF" | grep -qx "$E" && USED=1
  [ -d "$ARC/$(printf '%s' "$F" | cut -c1-7)/$F" ] && USED=1
  [ "$USED" = "1" ] && printf '%s\n' "$L" >> "$KEEP"
done < "$DATA/events.jsonl"
mv -f "$KEEP" "$DATA/events.jsonl"

