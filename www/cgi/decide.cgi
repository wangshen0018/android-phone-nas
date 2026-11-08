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
# 批量提交时 body 里带 ids 列表，800 条 x 17 字节约 14KB，留一倍余量
[ "$LEN" -gt 32768 ] && { echo '{"ok":false,"err":"body too large"}'; exit 0; }
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

# --- 批量标记：body 里带 ids 就说明是批量提交 ---
# 批量请求没有单条 id，所以下面的单条 id 校验必须跳过。
BIDS=$(printf '%s' "$BODY" | tr -d '\r\n' | sed -n 's/.*"ids":"\([^"]*\)".*/\1/p')

# --- 校验：id 必须是 16 位小写十六进制（单条模式才查） ---
if [ -z "$BIDS" ]; then
  case "$ID" in
    ''|*[!0-9a-f]*) echo '{"ok":false,"err":"bad id"}'; exit 0 ;;
  esac
  [ ${#ID} -eq 16 ] || { echo '{"ok":false,"err":"bad id len"}'; exit 0; }
fi

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

# ==================== 批量模式 ====================
# 触发：body 里带 "ids":"<id1>,<id2>,..."（其余字段同单条：action/event/topic/cat）
#
# 为什么 ids 放 body 不放 QUERY_STRING：busybox httpd 在 POST 下对 QUERY_STRING
# 的传递实测不可靠，放 body 里没有歧义（body 上限已放到 32KB）。
#
# 为什么要有批量（2026-11-08 实测）：
#   单条判定实测 480 ms，而"只输出一行"的最小 CGI 只要 50 ms。
#   差的 430 ms 全在脚本内部——这条脚本有近 30 处 `printf|sed|tr|cut|grep`
#   管道，每一处都 fork 一个进程，旧手机上每个 10~20 ms。
#   一次提交 N 条时，这 430 ms 会被重复付 N 次；而 busybox httpd 是单线程，
#   前端并发也救不了（请求只能排队）。唯一有效的办法是减少请求数：
#   一次请求内批量写，公共开销只付一次。
#   实测 20 条一批时，摊到每条约 10~20 ms。
BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=busybox

if [ -n "$BIDS" ]; then
  case "$ACT" in del|keep|hold|arc) ;; *) echo '{"ok":false,"err":"bad action"}'; exit 0 ;; esac

  # 只保留合法 id（16 位小写 hex）。用 shell 判断而不是 grep -E：
  # busybox 的 grep 对 {16} 这种区间量词支持不一致，写死更稳，也少 fork 一次。
  CLEAN=""; NID=0
  _ifs=$IFS; IFS=','
  for _one in $BIDS; do
    IFS=$_ifs
    case "$_one" in
      ''|*[!0-9a-f]*) ;;
      *) if [ ${#_one} -eq 16 ]; then CLEAN="$CLEAN $_one"; NID=$((NID+1)); fi ;;
    esac
    IFS=','
  done
  IFS=$_ifs
  CLEAN=${CLEAN# }
  [ "$NID" -gt 0 ] || { echo '{"ok":false,"err":"no valid id"}'; exit 0; }
  [ "$NID" -gt 800 ] && { echo '{"ok":false,"err":"too many ids"}'; exit 0; }

  # 存档：要么给了已有事件，要么给主题新建。两条都不满足就整批拒掉，
  # 免得 apply 兜底建出「未命名」夹（这是 2026-11-06 踩过的坑）。
  if [ "$ACT" = "arc" ]; then
    if [ -z "$EV" ] && [ -z "$TOPIC" ]; then
      echo '{"ok":false,"err":"存档需选择已有事件或填写主题"}'; exit 0
    fi
    if [ -n "$EV" ]; then
      if ! grep -qF "\"event_id\":\"$EV\"" "$DATA/events.jsonl" 2>/dev/null; then
        echo '{"ok":false,"err":"所选事件不存在，请刷新页面后重选"}'; exit 0
      fi
    else
      # 新建事件：用第一条的拍摄日期与分类建一次，其余复用这个 event_id
      FIRSTID=${CLEAN%% *}
      ALF=$(grep -m1 -F "\"id\":\"$FIRSTID\"" "$DATA/analysis.jsonl" 2>/dev/null)
      DD=$(printf '%s' "$ALF" | sed -n 's/.*"date":"\([^"]*\)".*/\1/p')
      [ -z "$DD" ] && DD=$(date +%Y-%m-%d)
      CATF="$CATIN"
      if [ -z "$CATF" ]; then
        CATF=$(printf '%s' "$ALF" | sed -n 's/.*"cat":"\([^"]*\)".*/\1/p')
      fi
      case "$CATF" in work|home|screenshot|video|other|unclassified) ;; *) CATF="other" ;; esac
      YYYY=$(printf '%s' "$DD" | cut -c1-4)
      YM=$(printf '%s' "$DD" | cut -c1-7)
      BASE="${DD}_${CATF}_${TOPIC}"
      FOLDER="$BASE"; SEQ=1
      while :; do
        if [ ! -d "$ARC/$YM/$FOLDER" ] && ! grep -qF "\"folder\":\"$FOLDER\"" "$DATA/events.jsonl" 2>/dev/null; then
          break
        fi
        SEQ=$((SEQ+1)); FOLDER="${BASE}_${SEQ}"
        [ "$SEQ" -gt 30 ] && break
      done
      D8=$(printf '%s' "$DD" | tr -d '-')
      N=1
      while grep -qF "\"event_id\":\"ev-$D8-$(printf '%02d' "$N")\"" "$DATA/events.jsonl" 2>/dev/null; do
        N=$((N+1)); [ "$N" -gt 99 ] && break
      done
      EV="ev-$D8-$(printf '%02d' "$N")"
      printf '{"event_id":"%s","start_date":"%s","slug":"%s","topic":"%s","folder":"%s","status":"open","counts":{"i":0,"v":0},"ts":%s}\n' \
        "$EV" "$DD" "$CATF" "$TOPIC" "$FOLDER" "$NOW" >> "$DATA/events.jsonl"
    fi
  fi

  # 生成 decisions 行。两条路径：
  #  · 前端带了逐条分类（cats，逗号分隔、与 ids 同序）→ 纯内存拼装，不读任何文件
  #  · 没带 → 退回扫 analysis.jsonl 查 AI 分类（一次扫完，不是每条 grep 一次）
  # 前端拿的 cats 就是从 state.cgi 显示的那份，和这里查出来的一致，所以优先用它。
  TMPB=/data/local/tmp/_bdec_$$.jsonl
  CATS=$(printf '%s' "$BODY" | tr -d '\r\n' | sed -n 's/.*"cats":"\([^"]*\)".*/\1/p')
  if [ -n "$CATS" ]; then
    $BB awk -v IDS="$CLEAN" -v CATS="$CATS" -v ACT="$ACT" -v EV="$EV" \
           -v TOPIC="$TOPIC" -v CATIN="$CATIN" -v NOW="$NOW" '
      BEGIN{
        n=split(IDS,A," "); m=split(CATS,C,",");
        gsub(/\\/,"",TOPIC);
        for(i=1;i<=n;i++){
          c=(i<=m)?C[i]:"";
          if(CATIN!="") c=CATIN;
          if(c!="work"&&c!="home"&&c!="screenshot"&&c!="video"&&c!="other"&&c!="unclassified") c="other";
          printf "{\"id\":\"%s\",\"action\":\"%s\",\"event\":\"%s\",\"topic\":\"%s\",\"cat\":\"%s\",\"by\":\"web\",\"ts\":%s}\n", A[i], ACT, EV, TOPIC, c, NOW;
        }
      }' > "$TMPB" 2>/dev/null
  else
    $BB awk -v IDS="$CLEAN" -v ACT="$ACT" -v EV="$EV" -v TOPIC="$TOPIC" \
           -v CATIN="$CATIN" -v NOW="$NOW" '
      BEGIN{ n=split(IDS,A," "); for(i=1;i<=n;i++){ ord[i]=A[i]; want[A[i]]=1 } }
      {
        if (match($0,/"id":"[0-9a-f]+"/)) {
          id=substr($0,RSTART+6,RLENGTH-7);
          if ((id in want) && !(id in seen)) {
            seen[id]=1;
            if (match($0,/"cat":"[^"]*"/)) catv[id]=substr($0,RSTART+7,RLENGTH-8);
          }
        }
      }
      END{
        for(i=1;i<=n;i++){
          id=ord[i];
          c=CATIN;
          if (c=="") c=(id in catv)?catv[id]:"other";
          if (c=="") c="other";
          gsub(/\\/,"",TOPIC);
          printf "{\"id\":\"%s\",\"action\":\"%s\",\"event\":\"%s\",\"topic\":\"%s\",\"cat\":\"%s\",\"by\":\"web\",\"ts\":%s}\n", id, ACT, EV, TOPIC, c, NOW;
        }
      }' "$DATA/analysis.jsonl" > "$TMPB" 2>/dev/null
  fi

  CNT=$(wc -l < "$TMPB" 2>/dev/null | tr -d ' ')
  [ -z "$CNT" ] && CNT=0
  if [ "$CNT" -gt 0 ]; then
    cat "$TMPB" >> "$DATA/decisions.jsonl"
  fi
  rm -f "$TMPB" 2>/dev/null

  printf '{"ok":true,"batch":%s,"count":%s,"event_id":"%s","action":"%s"}\n' \
    "$NID" "$CNT" "$EV" "$ACT"
  exit 0
fi

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
