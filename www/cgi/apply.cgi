#!/system/bin/sh
. "$(dirname "$0")/../../bin/lib-path.sh"
# apply.cgi — 执行已判定的决策，产出 receipts
#
# 注意：STG 指向真实 inbox，不是沙箱。del 会真删文件、arc 会真移文件。
# （早期注释写"沙箱内动作"是错的，2026-11-06 更正。所以前端必须先预览再执行。）
#
# 两种模式：
#   POST ?a=preview   只统计"将要发生什么"，不动任何文件 —— 前端用它弹确认框
#   POST ?a=apply     真正执行（默认，兼容旧调用）
DATA=$NASBAK_ROOT/state
STG=$NASBAK_ROOT/inbox
ARC=$NASBAK_ROOT/archive
WWW=$NASBAK_HOME/www
MEDIA=$WWW/media
. $NASBAK_HOME/bin/lib-ledger.sh 2>/dev/null

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

if [ "$REQUEST_METHOD" != "POST" ]; then
  echo '{"ok":false,"err":"POST only"}'; exit 0
fi

# 动作由 querystring 决定（POST 的 body 本脚本不使用）
MODE=apply
case "${QUERY_STRING:-}" in
  *a=preview*) MODE=preview ;;
esac

touch "$DATA/decisions.jsonl" "$DATA/receipts.jsonl" "$DATA/events.jsonl" 2>/dev/null

# 已执行过的 id（幂等：重跑不会二次执行）
DONE=$(sed -n 's/.*"id":"\([0-9a-f]\{16\}\)","action".*/\1/p' "$DATA/receipts.jsonl" | sort -u)
has_done() { printf '%s\n' "$DONE" | grep -qx "$1"; }

# 取出所有被判过的 id（去重，保持首次出现顺序）
IDS=$(sed -n 's/.*"id":"\([0-9a-f]\{16\}\)".*/\1/p' "$DATA/decisions.jsonl" | awk '!seen[$0]++')

# 安全阀（2026-11-06 血的教训）：支持 ids=<id,id,...> 只处理指定文件。
# 不加这个参数就处理【整个队列】—— 我做端到端测试时就是因此误执行了
# 26 条待判定（19 归档 + 7 删除），恢复花了很久。
# 现在前端自动执行一律显式传 ids，绝不裸调。
IDSEL=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^ids=//p' | head -1)
if [ -n "$IDSEL" ]; then
  # 只保留合法 16 位 hex，并用换行拼成待处理列表
  IDS=$(printf '%s' "$IDSEL" | tr ',' '\n' | sed -n 's/^\([0-9a-f]\{16\}\)$/\1/p')
  [ -z "$IDS" ] && { echo '{"ok":false,"err":"ids 参数不含合法 id"}'; exit 0; }
  RESTRICT=1
else
  RESTRICT=0
fi

NOW=$(date +%s)
EXP=$((NOW + 2592000))
CNT_D=0; CNT_K=0; CNT_H=0; CNT_A=0; CNT_S=0; CNT_E=0
CNT_MISS=0
# 预览模式用的累加器（事件夹名、涉及日期）
AFOLDER=""; PDATES=""; APDATES=""
# 分组累加器：GRP = "日期|事件|数量" 的行；GRPDEL = "日期|数量"
# 目的：前端能说「11月5日备份的 12 个文件将移入 家庭 › 2024 生日」
GRP=""; GRPDEL=""; GRPKEEP=""; GRPHOLD=""
FIRST=1
[ "$MODE" = "apply" ] && printf '{"ok":true,"items":['

for ID in $IDS; do
  if has_done "$ID"; then CNT_S=$((CNT_S+1)); continue; fi

  # 同一 id 以最后一条决策为准
  LINE=$(grep -F "\"id\":\"$ID\"" "$DATA/decisions.jsonl" 2>/dev/null | tail -1)
  [ -z "$LINE" ] && continue
  ACT=$(printf '%s' "$LINE" | sed -n 's/.*"action":"\([a-z]*\)".*/\1/p')
  # 撤销记录（action=none）不是真实判定，直接跳过，不能当成"待执行动作"
  [ "$ACT" = "none" ] && continue
  case "$ACT" in del|keep|hold|arc) ;; *) continue ;; esac
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

  # ---------- 预览模式：只统计，不动任何文件 ----------
  # 前端用它拼出「X 月 X 日备份的 N 个文件将移入 XXX 事件」这样的确认文案
  if [ "$MODE" = "preview" ]; then
    case "$ACT" in
      del)
        CNT_D=$((CNT_D+1))
        # 记录该文件所属的日期目录，前端按日期分组展示
        PDATE=$(printf '%s' "$REL" | cut -d/ -f1)
        PDATES="$PDATES $PDATE"
        GRPDEL="${GRPDEL}${PDATE}"$'\n'
        ;;
      keep)
        CNT_K=$((CNT_K+1))
        GRPKEEP="${GRPKEEP}$(printf '%s' "$REL" | cut -d/ -f1)"$'\n'
        ;;
      hold)
        CNT_H=$((CNT_H+1))
        GRPHOLD="${GRPHOLD}$(printf '%s' "$REL" | cut -d/ -f1)"$'\n'
        ;;
      arc)
        CNT_A=$((CNT_A+1))
        FOLDER=""
        if [ -n "$EV" ]; then
          # 用整行 grep 定位事件，再逐字段 sed —— 避免贪婪匹配串到别的字段
          EL=$(grep -F "\"event_id\":\"$EV\"" "$DATA/events.jsonl" 2>/dev/null | head -1)
          if [ -n "$EL" ]; then
            FOLDER=$(printf '%s' "$EL" | sed -n 's/.*"folder":"\([^"]*\)".*/\1/p')
            # 归入已有事件时，分类与主题以事件本身的 slug/topic 为准
            # （决策行里的 cat 是 AI 对单文件的判断，可能和事件分类不一致）
            ET=$(printf '%s' "$EL" | sed -n 's/.*"topic":"\([^"]*\)".*/\1/p')
            ES=$(printf '%s' "$EL" | sed -n 's/.*"slug":"\([^"]*\)".*/\1/p')
            [ -n "$ET" ] && TOPIC="$ET"
            [ -n "$ES" ] && DCAT="$ES"
          fi
        fi
        if [ -z "$FOLDER" ]; then
          CNT_E=$((CNT_E+1))   # 将新建事件
          [ -z "$TOPIC" ] && continue
          FOLDER="$TOPIC"
          AFOLDER="${AFOLDER}${TOPIC}|"
        else
          AFOLDER="${AFOLDER}${FOLDER}|"
        fi
        APDATE=$(printf '%s' "$REL" | cut -d/ -f1)
        APDATES="$APDATES $APDATE"
        # 记下 folder/topic/cat，前端才能显示「工作 › project-survey」而不是文件夹原名
        # topic 为空（归入已有事件）时退化成 folder 名
        GRP="${GRP}${APDATE}|${FOLDER}|${TOPIC}|${DCAT}"$'\n'
        ;;
    esac
    continue
  fi

  case "$ACT" in
    del)
      # 「删除」= 移进回收站，不是真删（2026-11-06 用户明确要求：
      # 隔离区当回收站用，暂存 30 天后自动清理）。
      #
      # 关键发现：media/ 里的副本是【硬链接】（实测 nlink=2、inode 相同），
      # 所以只要把其中一个链接 mv 进回收站，内容就完整保留了。
      # 之前的写法是先 rm 源文件、再 mv 副本 —— 中间那一刻只剩一个链接，
      # 如果 mv 失败文件就真没了。现在改成：先把【源文件】mv 进回收站，
      # 成功后再处理 media 副本（两者本是同一 inode，mv 任何一个都够）。
      #
      # 回收站路径带日期分组，30 天后由 trash-gc.sh 清理。
      TRASHD="$DATA/_media_gc_trash/$(date +%Y%m%d)"
      mkdir -p "$TRASHD" 2>/dev/null
      SRC_FILE="$STG/$REL"
      if [ -f "$SRC_FILE" ]; then
        # 保留原文件名，同时把 id 前缀写进名字，方便撤销时反查。
        # 必须用 ${ID}__${NAME} 花括号形式：写成 $ID__$NAME 时 shell 会把
        # "ID__" 当成一个变量名（下划线是合法变量字符），结果前缀变成空（2026-11-06 实测）。
        BNKEEP="$TRASHD/${ID}__${NAME}"
        if mv -f "$SRC_FILE" "$BNKEEP" 2>/dev/null; then
          RES="deleted"
          # 记录回收站相对路径，撤销时据此找回
          PATHOUT=$(printf '%s' "$BNKEEP" | sed "s#^$DATA/##")
          NOTE="已移入回收站（30 天后自动清理）"
          CNT_D=$((CNT_D+1))
        else
          RES="failed"; PATHOUT=""; NOTE="移入回收站失败，文件保持原状"
        fi
        # media 里的硬链接：源文件已经 mv 走，剩下的这个链接也移进回收站，
        # 否则会变成孤儿（页面上缩略图还会显示）。mv 失败无所谓，内容已在回收站。
        EXT="${NAME##*.}"
        if [ -f "$MEDIA/$ID.$EXT" ]; then
          mv -f "$MEDIA/${ID}.${EXT}" "$TRASHD/${ID}.thumb.${EXT}" 2>/dev/null
        fi
      else
        RES="missing"; PATHOUT=""; NOTE="inbox 里已无此文件"
      fi
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
            . $NASBAK_HOME/bin/lib-sidecar.sh 2>/dev/null; sidecar_append 2>/dev/null
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

# ---------- 输出 ----------
if [ "$MODE" = "preview" ]; then
  # 预览：返回统计 + 涉及的事件夹名 + 涉及日期，供前端拼确认文案
  # 事件名同理去重（同一事件可能被多个文件引用）
  AFU=""
  _old=$IFS; IFS='|'
  for _x in $AFOLDER; do
    [ -z "$_x" ] && continue
    case "|$AFU|" in *"|$_x|"*) ;; *) AFU="${AFU}${_x}|" ;; esac
  done
  IFS=$_old

  # 日期去重并排序
  ADS=$(printf '%s\n' $PDATES $APDATES | grep -v '^$' | sort -u | tr '\n' ' ')

  # 聚合分组 → {"kind":"arc","date":"2024-11-05","event":"家庭/生日","n":12}
  # 前端拿这个直接生成「11月5日备份的 12 个文件将移入 家庭 › 生日」，
  # 比给一堆散日期和散事件名有用得多（用户明确要求这一句，2026-11-06）。
  GRPS=""
  if [ -n "$GRP" ]; then
    # 按 日期+事件夹 聚合，带出 cat/topic 供前端显示人话名称
    printf '%s' "$GRP" | grep -v '^$' \
    | $BB awk -F'|' '
        { k=$1"|"$2; n[k]++; if($3!="") tp[k]=$3; if($4!="") ct[k]=$4;
          if(!(k in seen)){ seen[k]=1; ord[++m]=k } }
        END{ for(i=1;i<=m;i++){ k=ord[i]; split(k,a,"|");
               printf "{\"kind\":\"arc\",\"date\":\"%s\",\"event\":\"%s\",\"cat\":\"%s\",\"topic\":\"%s\",\"n\":%d}\n",
                      a[1], a[2], ct[k], tp[k], n[k] } }' \
    > "$DATA/.preview_grp.$$"
    while IFS= read -r _g; do
      [ -z "$_g" ] && continue
      [ -z "$GRPS" ] || GRPS="${GRPS},"
      GRPS="${GRPS}${_g}"
    done < "$DATA/.preview_grp.$$"
    rm -f "$DATA/.preview_grp.$$"
  fi
  for _pair in "del:$GRPDEL" "keep:$GRPKEEP" "hold:$GRPHOLD"; do
    _k=${_pair%%:*}; _v=${_pair#*:}
    [ -z "$_v" ] && continue
    printf '%s' "$_v" | grep -v '^$' | sort | uniq -c \
    | while read -r _n _d; do
        printf '{"kind":"%s","date":"%s","event":"","n":%s}\n' "$_k" "$_d" "$_n"
      done > "$DATA/.preview_grp2.$$"
    while IFS= read -r _g; do
      [ -z "$_g" ] && continue
      [ -z "$GRPS" ] || GRPS="${GRPS},"
      GRPS="${GRPS}${_g}"
    done < "$DATA/.preview_grp2.$$"
    rm -f "$DATA/.preview_grp2.$$"
  done

  printf '{"ok":true,"preview":true,"summary":{"executed":%s,"archived":%s,"deleted":%s,"kept":%s,"held":%s,"new_events":%s,"missing":%s},' \
    $((CNT_A+CNT_D+CNT_K+CNT_H)) "$CNT_A" "$CNT_D" "$CNT_K" "$CNT_H" "$CNT_E" "$CNT_MISS"
  printf '"dates":"%s","events":"%s","groups":[%s]}' \
    "$(printf '%s' "$ADS" | sed 's/ *$//')" "$(printf '%s' "$AFU" | sed 's/|$//')" "$GRPS"
  exit 0
fi

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

