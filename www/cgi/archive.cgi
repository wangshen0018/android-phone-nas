#!/system/bin/sh
. "$(dirname "$0")/../../bin/lib-path.sh"
# archive.cgi — 已存档管理接口
#
# 动作（POST 或 GET 均可，通过 action 参数区分）：
#   list                      列出所有事件夹与文件
#   rename                    重命名事件夹（同步 events.jsonl 的 folder / start_date / event_id）
#   renamefile                重命名单个文件
#   move                      把文件移到另一个事件夹
#   delete                    删除文件（移到 _待删 回收区，不真删）
#   newevent                  新建事件夹
#
# 所有移动/重命名都写台账 state/ledger.jsonl

DATA=$NASBAK_ROOT/state
ARC=$NASBAK_ROOT/archive
TRASH=$NASBAK_ROOT/_待删

. $NASBAK_HOME/bin/lib-ledger.sh 2>/dev/null

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

# 解析参数：POST 用 body，GET 用 QUERY_STRING
QS="${QUERY_STRING:-}"
BODY=""
if [ "$REQUEST_METHOD" = "POST" ]; then
  LEN=${CONTENT_LENGTH:-0}
  case "$LEN" in ''|*[!0-9]*) LEN=0 ;; esac
  [ "$LEN" -gt 65536 ] && LEN=65536
  BODY=$(head -c "$LEN" 2>/dev/null)
  QS="$BODY"
fi

# 取参数值（兼容 JSON 与 a=b&c=d 两种格式）
getp() {
  _k="$1"
  # JSON 形式 "key":"value"
  _v=$(printf '%s' "$QS" | sed -n 's/.*"'"$_k"'":"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$_v" ]; then
    # 表单形式 key=value
    _v=$(printf '%s' "$QS" | tr '&' '\n' | sed -n "s/^$_k=//p" | head -1)
    # URL 解码（%XX 和 +）
    _v=$(printf '%s' "$_v" | sed 's/+/ /g')
  fi
  urldec "$_v"
}

# URL 解码：%XX -> 字符（用 printf 的 \xNN 转义逐字节还原）
urldec() {
  _s="$1"
  case "$_s" in *%*) ;; *) printf '%s' "$_s"; return 0 ;; esac
  _out=""
  while :; do
    case "$_s" in
      *%[0-9a-fA-F][0-9a-fA-F]*)
        _pre="${_s%%\%*}"
        _r="${_s#*\%}"
        _hx=$(printf '%s' "$_r" | cut -c1-2)
        _ch=$(printf "\\x$_hx" 2>/dev/null)
        _out="$_out$_pre$_ch"
        _s=$(printf '%s' "$_r" | cut -c3-)
        ;;
      *) _out="$_out$_s"; break ;;
    esac
  done
  printf '%s' "$_out"
}

# 事件行定位（busybox sed 对 UTF-8 中文的 .* 匹配不可靠，改用 grep -F 先定位行）
evline() { grep -F "\"folder\":\"$1\"" "$DATA/events.jsonl" 2>/dev/null | head -1; }
evfield() { evline "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
evym() { _f=$(evfield "$1" folder); printf '%s' "$_f" | cut -c1-7; }

# JSON 转义
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'; }

# ---------- 归档时间（存入批次）----------
# 「这个文件是什么时候进到这个事件夹的」有两个来源：
#   1) receipts.jsonl 的 action=arc —— judge 正常归档，path = 归档相对路径
#   2) ledger.jsonl 的 act=arc-move / arc-renamefile —— 在页面里手工跨事件移动或改名，
#      文件换了目录，path 变了，必须用台账里的 `to` 重新对上
#   只看回执会漏掉手工移动过的文件，表现就是明明在事件里却显示「无存档回执」（2026-11-07 反馈）。
#
# 同一文件可能有多条记录（先归档、后移动），取 ts 最大的一条，即「最后一次进入当前位置的时间」。
# 这一步用 awk 一次聚合，避免逐条 grep（87 个文件 × N 条记录会拖慢接口）。
ARCTSV=$NASBAK_TMP/_arcts_$$.tsv
build_arcidx() {
  : > "$ARCTSV" 2>/dev/null
  {
    if [ -f "$DATA/receipts.jsonl" ]; then
      grep -F '"action":"arc"' "$DATA/receipts.jsonl" 2>/dev/null \
        | sed -n 's/.*"path":"\([^"]*\)".*"ts":\([0-9]*\).*/\1\t\2/p'
    fi
    if [ -f "$DATA/ledger.jsonl" ]; then
      # 台账里的 to 带 "archive/" 前缀（回执里的 path 不带），要剥掉才能对上同一个键
      grep -E '"act":"arc-move"|"act":"arc-renamefile"' "$DATA/ledger.jsonl" 2>/dev/null \
        | sed -n 's/.*"ts":\([0-9]*\).*"to":"\([^"]*\)".*/\2\t\1/p' \
        | sed 's|^archive/||'
    fi
  } | awk -F'\t' 'NF>=2 && $1!="" { if($2+0>m[$1]) m[$1]=$2+0 } END{ for(k in m) printf "%s\t%d\n", k, m[k] }' > "$ARCTSV" 2>/dev/null
}
# 查某归档相对路径的存入时间（多条回执取最后一条）；查不到返回空
arcts_of() {
  [ -s "$ARCTSV" ] || return 0
  grep -F "$1	" "$ARCTSV" 2>/dev/null | tail -1 | cut -f2
}
# 拍摄日期：优先从文件名解析（IMG_20261102_103213 / VID_20261105_070508 / 微信 mmexport<13位>）
# 解析不出就退回文件 mtime 的日期。输出 YYYY-MM-DD。
shot_of() {
  _n="$1"; _mt="$2"
  _d=$(printf '%s' "$_n" | sed -n 's/^[A-Za-z]*_\(20[0-9][0-9]\)\([0-9][0-9]\)\([0-9][0-9]\)_.*/\1-\2-\3/p')
  if [ -z "$_d" ]; then
    # 微信导出的 mmexport<毫秒时间戳>
    _ms=$(printf '%s' "$_n" | sed -n 's/^mmexport\(1[0-9]\{12\}\).*/\1/p')
    if [ -n "$_ms" ]; then
      # mksh 的 $(( )) 是 32 位有符号，13 位毫秒直接除会溢出成负值（坑 2.11），
      # 交给 awk 走双精度再传给 date。
      _sec=$(printf '%s' "$_ms" | awk '{printf "%.0f", $1/1000}')
      _d=$($BB date -d "@$_sec" +%Y-%m-%d 2>/dev/null)
    fi
  fi
  [ -z "$_d" ] && [ -n "$_mt" ] && _d=$($BB date -d "@$_mt" +%Y-%m-%d 2>/dev/null)
  # busybox date 不支持 -d 时（Android 自带的不支持）退回 stat 的 %y 前 10 位
  [ -z "$_d" ] && _d=$(printf '%s' "$3" | cut -c1-10)
  printf '%s' "$_d"
}

ACTN=$(getp action)

case "$ACTN" in

# ---------- 列表 ----------
list)
  build_arcidx
  printf '{"ok":true,"events":['
  FIRST=1
  if [ -f "$DATA/events.jsonl" ]; then
    while IFS= read -r ln; do
      [ -z "$ln" ] && continue
      F=$(printf '%s' "$ln" | sed -n 's/.*"folder":"\([^"]*\)".*/\1/p')
      [ -z "$F" ] && continue
      YM=$(printf '%s' "$F" | cut -c1-7)
      D="$ARC/$YM/$F"
      [ -d "$D" ] || continue
      # 计数要排除 _manifest.jsonl 这类元数据，否则和 files 返回的条数对不上
      N=$(find "$D" -maxdepth 1 -type f ! -name '_*' 2>/dev/null | wc -l | tr -d ' ')
      SZ=$($BB du -sb "$D" 2>/dev/null | awk '{print $1}')
      [ -z "$SZ" ] && SZ=0
      # 最近存入时间：优先取回执里该事件夹所有文件的最大 ts（真正的"存入"），
      # 没有回执才退回文件 mtime 最大值（那是拍摄时间，语义不同，前端会标出来）。
      # 不能用目录 mtime —— 实测 6 个事件夹的目录 mtime 全等于同一次批量操作的时间。
      LAST=$(awk -F'\t' -v p="$YM/$F/" 'index($1,p)==1 && $2+0>m {m=$2+0} END{print m+0}' "$ARCTSV" 2>/dev/null)
      LASTSRC=arc
      case "$LAST" in ''|0)
        LAST=$($BB find "$D" -maxdepth 1 -type f -exec $BB stat -c %Y {} + 2>/dev/null | sort -n | tail -1)
        [ -z "$LAST" ] && LAST=0
        LASTSRC=file
        ;;
      esac
      # 封面：取事件夹内第一张图片，按归档 mid 公式生成预览链接。
      # 供存档页的图形化事件选择器显示缩略图，避免逐个事件再拉一次 files。
      # mid 公式必须与 files 动作完全一致，否则 media-gc 的归档 mid 集合对不上。
      CVMID=""; CVEXT=""
      for CFP in "$D"/*; do
        [ -f "$CFP" ] || continue
        CEX=$(printf '%s' "${CFP##*.}" | tr 'A-Z' 'a-z')
        case "$CEX" in jpg|jpeg|png|webp|gif|bmp) ;; *) continue ;; esac
        CN=$(basename "$CFP")
        CS=$(stat -c %s "$CFP" 2>/dev/null); [ -z "$CS" ] && CS=0
        CVMID=$(printf '%s:%s' "$YM/$F/$CN" "$CS" | $BB sha256sum 2>/dev/null | cut -c1-16)
        CVEXT="$CEX"
        WWMDIR=$NASBAK_ROOT/state/media   # 实体目录与照片同挂载，ln 必成（旧版在 /data/adb 下必失败）
        mkdir -p "$WWMDIR" 2>/dev/null
        [ -f "$WWMDIR/$CVMID.$CVEXT" ] || {
          ln -f "$CFP" "$WWMDIR/$CVMID.$CVEXT" 2>/dev/null || cp -f "$CFP" "$WWMDIR/$CVMID.$CVEXT" 2>/dev/null
        }
        break
      done
      [ "$FIRST" = "1" ] || printf ','
      printf '{"folder":"%s","ym":"%s","count":%s,"size":%s,"last":%s,"lastSrc":"%s","cover":"%s","coverExt":"%s","meta":%s}' \
        "$(jesc "$F")" "$YM" "$N" "$SZ" "$LAST" "$LASTSRC" "$CVMID" "$CVEXT" "$ln"
      FIRST=0
    done < "$DATA/events.jsonl"
  fi
  printf '],"trash":'
  if [ -d "$TRASH" ]; then
    TN=$(find "$TRASH" -type f 2>/dev/null | wc -l | tr -d ' ')
    TS=$($BB du -sb "$TRASH" 2>/dev/null | awk '{print $1}'); [ -z "$TS" ] && TS=0
    printf '{"count":%s,"size":%s}' "$TN" "$TS"
  else
    printf '{"count":0,"size":0}'
  fi
  printf '}\n'
  rm -f "$ARCTSV"
  ;;

# ---------- 事件夹内文件列表 ----------
files)
  F=$(getp folder)
  case "$F" in ''|*/*) echo '{"ok":false,"err":"bad folder"}'; exit 0 ;; esac
  # 从 events.jsonl 找对应月份
  YM=$(evym "$F")
  [ -z "$YM" ] && { echo '{"ok":false,"err":"event not found"}'; exit 0; }
  D="$ARC/$YM/$F"
  [ -d "$D" ] || { echo '{"ok":false,"err":"folder not exists"}'; exit 0; }
  build_arcidx
  WWMDIR=$NASBAK_ROOT/state/media   # 实体目录与照片同挂载，ln 必成（旧版在 /data/adb 下必失败）
  THUMBDIR=$NASBAK_ROOT/state/thumb
  mkdir -p "$WWMDIR" "$THUMBDIR" 2>/dev/null
  # 先收到临时表再排序：按拍摄时间正序（mt），同一时刻按文件名，观感与手机相册一致。
  # 直接边遍历边输出会得到 glob 顺序（jpg/mp4 混杂），看不出时间线。
  TMPF=$NASBAK_TMP/_files_$$.tsv
  : > "$TMPF"
  for fp in "$D"/*; do
    [ -f "$fp" ] || continue
    N=$(basename "$fp")
    # 归档时写的 _manifest.jsonl 之类的元数据不是媒体，别混进缩略图网格
    case "$N" in _*) continue ;; esac
    S=$(stat -c %s "$fp" 2>/dev/null); [ -z "$S" ] && S=0
    E=$(printf '%s' "${N##*.}" | tr 'A-Z' 'a-z')
    # 为该文件准备一个媒体硬链接（按 事件夹相对路径:大小 生成确定 id）
    MID=$(printf '%s:%s' "$YM/$F/$N" "$S" | $BB sha256sum 2>/dev/null | cut -c1-16)
    if [ ! -f "$WWMDIR/$MID.$E" ]; then
      ln -f "$fp" "$WWMDIR/$MID.$E" 2>/dev/null || cp -f "$fp" "$WWMDIR/$MID.$E" 2>/dev/null
    fi
    MT=$(stat -c %Y "$fp" 2>/dev/null); [ -z "$MT" ] && MT=0
    MY=$(stat -c %y "$fp" 2>/dev/null)
    SHOT=$(shot_of "$N" "$MT" "$MY")
    AR=$(arcts_of "$YM/$F/$N")
    # 别写成 `TH=0; [ -f x ] && TH=1`：条件为假时整行返回非 0，
    # 在部分 sh 下会让后续 read 拿不到第 8 个字段（实测 _manifest 那行 thumb 输出为空）。
    TH=0
    if [ -f "$THUMBDIR/$MID.jpg" ]; then TH=1; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$N" "$S" "$E" "$MID" "$MT" "$SHOT" "$AR" "$TH" >> "$TMPF"
  done
  printf '{"ok":true,"folder":"%s","files":[' "$(jesc "$F")"
  FIRST=1
  # -k5,5n 按 mt 升序；文件名含空格/中文都安全，因为字段用 TAB 分隔
  LC_ALL=C sort -t "$(printf '\t')" -k5,5n "$TMPF" 2>/dev/null | while IFS="$(printf '\t')" read -r N S E MID MT SHOT AR TH; do
    [ -z "$N" ] && continue
    [ "$FIRST" = "1" ] || printf ','
    printf '{"name":"%s","size":%s,"ext":"%s","mid":"%s","mt":%s,"shot":"%s","arcTs":%s,"thumb":%s}' \
      "$(jesc "$N")" "${S:-0}" "$E" "$MID" "${MT:-0}" "$SHOT" "${AR:-0}" "${TH:-0}"
    FIRST=0
  done
  printf ']}\n'
  rm -f "$TMPF" "$ARCTSV"
  ;;

# ---------- 重命名事件夹 ----------
rename)
  OLD=$(getp folder); NEWF=$(getp newname)
  case "$OLD" in ''|*/*) echo '{"ok":false,"err":"bad folder"}'; exit 0 ;; esac
  NEWF=$(printf '%s' "$NEWF" | sed 's@[/\\:*?"<>|]@@g' | tr -d '\r\n\t')
  [ -z "$NEWF" ] && { echo '{"ok":false,"err":"empty name"}'; exit 0; }
  YM=$(evym "$OLD")
  [ -z "$YM" ] && { echo '{"ok":false,"err":"event not found"}'; exit 0; }
  SRC="$ARC/$YM/$OLD"; DST="$ARC/$YM/$NEWF"
  [ -d "$SRC" ] || { echo '{"ok":false,"err":"src missing"}'; exit 0; }
  [ -e "$DST" ] && { echo '{"ok":false,"err":"target exists"}'; exit 0; }
  cp "$DATA/events.jsonl" "$DATA/events.jsonl.bak-rename-$(date +%Y%m%d%H%M%S)" 2>/dev/null
  if mv "$SRC" "$DST" 2>/dev/null; then
    # 更新 events.jsonl 的 folder（以及从新名解析出的日期/分类/主题）
    D=$(printf '%s' "$NEWF" | sed -n 's/^\(20[0-9][0-9]-[01][0-9]-[0-3][0-9]\).*/\1/p')
    SL=$(printf '%s' "$NEWF" | sed -n 's/^20[0-9][0-9]-[01][0-9]-[0-3][0-9]_\([a-z]*\)_.*/\1/p')
    TP=$(printf '%s' "$NEWF" | sed -n 's/^20[0-9][0-9]-[01][0-9]-[0-3][0-9]_[a-z]*_\(.*\)/\1/p')
    [ -z "$SL" ] && SL=$(sed -n "s/.*\"folder\":\"$OLD\".*\"slug\":\"\([^\"]*\)\".*/\1/p" "$DATA/events.jsonl" | head -1)
    [ -z "$TP" ] && TP=$(sed -n "s/.*\"folder\":\"$OLD\".*\"topic\":\"\([^\"]*\)\".*/\1/p" "$DATA/events.jsonl" | head -1)
    NEWL=$(sed -n "s/.*\"folder\":\"$OLD\".*/&/p" "$DATA/events.jsonl" | head -1)
    # 用 sed 就地替换该行三个字段
    TMPL="$DATA/events.jsonl.tmp"
    : > "$TMPL"
    while IFS= read -r ln; do
      case "$ln" in
        *"\"folder\":\"$OLD\""*)
          nf=$(printf '%s' "$ln" | sed "s|\"folder\":\"$OLD\"|\"folder\":\"$NEWF\"|")
          [ -n "$D" ] && nf=$(printf '%s' "$nf" | sed "s|\"start_date\":\"[^\"]*\"|\"start_date\":\"$D\"|")
          [ -n "$SL" ] && nf=$(printf '%s' "$nf" | sed "s|\"slug\":\"[^\"]*\"|\"slug\":\"$SL\"|")
          printf '%s\n' "$nf" >> "$TMPL"
          ;;
        *) printf '%s\n' "$ln" >> "$TMPL" ;;
      esac
    done < "$DATA/events.jsonl"
    mv -f "$TMPL" "$DATA/events.jsonl"
    ledger_add "" "$NEWF" 0 "arc-rename" "archive/$YM/$OLD" "archive/$YM/$NEWF" "事件夹重命名" 2>/dev/null
    printf '{"ok":true,"folder":"%s","ym":"%s"}\n' "$(jesc "$NEWF")" "$YM"
  else
    echo '{"ok":false,"err":"mv failed"}'
  fi
  ;;

# ---------- 重命名单个文件 ----------
renamefile)
  F=$(getp folder); OLDN=$(getp file); NEWN=$(getp newname)
  case "$F" in ''|*/*) echo '{"ok":false,"err":"bad folder"}'; exit 0 ;; esac
  case "$OLDN" in ''|*/*) echo '{"ok":false,"err":"bad file"}'; exit 0 ;; esac
  NEWN=$(printf '%s' "$NEWN" | sed 's@[/\\:*?"<>|]@@g' | tr -d '\r\n\t')
  [ -z "$NEWN" ] && { echo '{"ok":false,"err":"empty name"}'; exit 0; }
  YM=$(evym "$F")
  D="$ARC/$YM/$F"
  SRC="$D/$OLDN"; DST="$D/$NEWN"
  [ -f "$SRC" ] || { echo '{"ok":false,"err":"file missing"}'; exit 0; }
  [ -e "$DST" ] && { echo '{"ok":false,"err":"target exists"}'; exit 0; }
  if mv "$SRC" "$DST" 2>/dev/null; then
    S=$(stat -c %s "$DST" 2>/dev/null)
    ledger_add "" "$NEWN" "$S" "arc-renamefile" "archive/$YM/$F/$OLDN" "archive/$YM/$F/$NEWN" "文件重命名" 2>/dev/null
    printf '{"ok":true,"name":"%s"}\n' "$(jesc "$NEWN")"
  else
    echo '{"ok":false,"err":"mv failed"}'
  fi
  ;;

# ---------- 删除（移到回收区） ----------
delete)
  F=$(getp folder); FILES=$(getp files)
  YM=$(evym "$F")
  [ -z "$YM" ] && { echo '{"ok":false,"err":"event not found"}'; exit 0; }
  D="$ARC/$YM/$F"
  [ -d "$D" ] || { echo '{"ok":false,"err":"folder missing"}'; exit 0; }
  TD="$TRASH/$(date +%Y%m%d)/$F"
  mkdir -p "$TD" 2>/dev/null
  N=0
  printf '%s\n' "$FILES" | tr ',' '\n' | while IFS= read -r n; do
    [ -z "$n" ] && continue
    case "$n" in */*) continue ;; esac
    if [ -f "$D/$n" ] && mv -f "$D/$n" "$TD/$n" 2>/dev/null; then
      S=$(stat -c %s "$TD/$n" 2>/dev/null)
      ledger_add "" "$n" "$S" "arc-trash" "archive/$YM/$F/$n" "$(printf '%s' "$TD/$n" | sed 's|$NASBAK_ROOT/||')" "归档内删除，移入回收区" 2>/dev/null
    fi
  done
  # 统计剩余
  LEFT=$(find "$D" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  printf '{"ok":true,"left":%s}\n' "$LEFT"
  ;;

# ---------- 移动文件到其他事件 ----------
move)
  FROM=$(getp from); TO=$(getp to); FILES=$(getp files)
  case "$FROM" in ''|*/*) echo '{"ok":false,"err":"bad from"}'; exit 0 ;; esac
  case "$TO" in ''|*/*) echo '{"ok":false,"err":"bad to"}'; exit 0 ;; esac
  YM1=$(evym "$FROM")
  YM2=$(evym "$TO")
  [ -z "$YM1" ] && { echo '{"ok":false,"err":"from not found"}'; exit 0; }
  [ -z "$YM2" ] && { echo '{"ok":false,"err":"to not found"}'; exit 0; }
  D1="$ARC/$YM1/$FROM"; D2="$ARC/$YM2/$TO"
  [ -d "$D2" ] || { echo '{"ok":false,"err":"to folder missing"}'; exit 0; }
  M=0; SK=0; ER=0
  printf '%s\n' "$FILES" | tr ',' '\n' > $NASBAK_TMP/_mv.list
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    case "$n" in */*) continue ;; esac
    [ -f "$D1/$n" ] || { ER=$((ER+1)); continue; }
    if [ -e "$D2/$n" ]; then SK=$((SK+1)); continue; fi
    if mv -f "$D1/$n" "$D2/$n" 2>/dev/null; then
      M=$((M+1))
      ledger_add "" "$n" 0 "arc-move" "archive/$YM1/$FROM/$n" "archive/$YM2/$TO/$n" "跨事件移动" 2>/dev/null
    else ER=$((ER+1)); fi
  done < $NASBAK_TMP/_mv.list
  rm -f $NASBAK_TMP/_mv.list
  printf '{"ok":true,"moved":%s,"skip":%s,"err":%s}\n' "$M" "$SK" "$ER"
  ;;

# ---------- 新建事件夹 ----------
newevent)
  DDATE=$(getp date); SLUG=$(getp slug); TOPIC=$(getp topic)
  case "$DDATE" in 20[0-9][0-9]-[01][0-9]-[0-3][0-9]) ;; *) echo '{"ok":false,"err":"bad date"}'; exit 0 ;; esac
  case "$SLUG" in work|home|screenshot|video|other) ;; *) SLUG="other" ;; esac
  TOPIC=$(printf '%s' "$TOPIC" | sed 's@[/\\:*?"<>|]@@g' | tr -d '\r\n\t' | cut -c1-20)
  [ -z "$TOPIC" ] && TOPIC="未命名"
  YM=$(printf '%s' "$DDATE" | cut -c1-7)
  BASE="${DDATE}_${SLUG}_${TOPIC}"
  FOLDER="$BASE"; SEQ=1
  while [ -d "$ARC/$YM/$FOLDER" ] || grep -qF "\"folder\":\"$FOLDER\"" "$DATA/events.jsonl" 2>/dev/null; do
    SEQ=$((SEQ+1)); FOLDER="${BASE}_${SEQ}"
    [ "$SEQ" -gt 30 ] && break
  done
  D8=$(printf '%s' "$DDATE" | tr -d '-')
  N=1
  while grep -qF "\"event_id\":\"ev-$D8-$(printf '%02d' "$N")\"" "$DATA/events.jsonl" 2>/dev/null; do
    N=$((N+1)); [ "$N" -gt 99 ] && break
  done
  EVID="ev-$D8-$(printf '%02d' "$N")"
  mkdir -p "$ARC/$YM/$FOLDER" 2>/dev/null
  printf '{"event_id":"%s","start_date":"%s","slug":"%s","topic":"%s","folder":"%s","status":"open","counts":{"i":0,"v":0},"ts":%s}\n' \
    "$EVID" "$DDATE" "$SLUG" "$TOPIC" "$FOLDER" "$(date +%s)" >> "$DATA/events.jsonl"
  ledger_add "" "$FOLDER" 0 "arc-newevent" "" "archive/$YM/$FOLDER" "新建事件夹" 2>/dev/null
  printf '{"ok":true,"folder":"%s","event_id":"%s","ym":"%s"}\n' "$(jesc "$FOLDER")" "$EVID" "$YM"
  ;;

*)
  echo '{"ok":false,"err":"unknown action"}'
  ;;
esac
