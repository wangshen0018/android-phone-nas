#!/system/bin/sh
# bt-stall.sh — 找出 aria2 里「卡住」的 BT 任务，输出给 8083 页面
#
# 为什么需要：修好 tracker 之后，仍会有一批真正没种 / 元数据都拿不到的死种。
# 这类任务只能交给迅雷体系（光鸭云盘云添加 / 自建迅雷）兜底，但要把链接从
# AriaNg 里翻出来再手工拼磁力很麻烦。本脚本定时扫 RPC，把卡住任务的 infoHash
# 拼成完整磁力链接，落到 www/bt-stall.json，页面直接给「复制磁力」按钮。
#
# 判定口径：
#   no_metadata  totalLength=0 —— 连种子元数据都没拿到（裸磁力 + DHT 不通的典型症状）
#   no_speed     downloadSpeed=0 且 numSeeders=0 持续 >= 20 分钟
#   有速度或有 seeder 时清除计时，不误报
#
# 输出里**只有 gid / infoHash / 数值**，不放文件名：既避开 shell 侧 UTF-8/base64
# 转义问题，也不把下载目录的文件名渲染到页面上。
#
# 由 cron 每 10 分钟调用，输出 /data/adb/nasbak/www/bt-stall.json。

set -u

CONF=/data/adb/srv/aria2.conf
DATA=/data/adb/srv/data
STATE=$DATA/bt-stall-state.txt
OUT=/data/adb/nasbak/www/bt-stall.json
LOG=$DATA/bt-stall.log
TMP=$DATA/_stall.$$
ITEMS=$DATA/_stall_items.$$
LOCKNAME=bt-stall
LOCKFALL=/data/local/tmp/nasbak-locks/$LOCKNAME.lock
HAVE_LIBLOCK=0
STALL_MIN=20
KEYS='["gid","status","totalLength","completedLength","downloadSpeed","numSeeders","connections","infoHash"]'

mkdir -p "$DATA" 2>/dev/null

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
  printf '%s\n' "$*"
}

cleanup() {
  rm -f "$TMP" "$TMP.new" "$TMP.state" "$TMP.obj" "$ITEMS" "$OUT.$$" 2>/dev/null
  if [ "$HAVE_LIBLOCK" = 1 ]; then
    lock_release "$LOCKNAME"
  else
    rm -rf "$LOCKFALL" 2>/dev/null
  fi
}
trap cleanup 0 INT TERM

# ---- 单实例锁 ----
if [ -f /data/adb/nasbak/bin/lib-lock.sh ]; then
  . /data/adb/nasbak/bin/lib-lock.sh
  HAVE_LIBLOCK=1
  if ! lock_acquire "$LOCKNAME"; then
    log "已有实例在运行，本次跳过"
    trap - 0 INT TERM   # 别让 cleanup 误删对方刚建好、还没写 pid 的锁
    exit 0
  fi
else
  mkdir -p /data/local/tmp/nasbak-locks 2>/dev/null
  if ! mkdir "$LOCKFALL" 2>/dev/null; then
    log "已有实例在运行，本次跳过"
    trap - 0 INT TERM
    exit 0
  fi
  echo $$ > "$LOCKFALL/pid" 2>/dev/null
fi

SECRET=$(sed -n 's/^[[:space:]]*rpc-secret[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | tr -d '\r')
PORT=$(sed -n 's/^[[:space:]]*rpc-listen-port[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | tr -d '\r')
[ -n "$PORT" ] || PORT=6800
RPC="http://127.0.0.1:$PORT/jsonrpc"

# 没配 rpc-secret 时绝不能带 token 前缀，否则 aria2 直接鉴权失败
TOKJSON=
[ -n "$SECRET" ] && TOKJSON='"token:'"$SECRET"'",'

rpc() {
  curl -s -m 12 -H 'Content-Type: application/json' -d "$1" "$RPC" 2>/dev/null
}

field() {
  printf '%s' "$1" | sed -n 's/.*"'"$2"'":"\([^"]*\)".*/\1/p' | head -n 1
}

# 逐个补查 infoHash（tellActive 的 keys 里不一定返回该字段）
hash_of() {
  _p=$(printf '{"jsonrpc":"2.0","id":"h","method":"aria2.tellStatus","params":[%s"%s",["infoHash"]]}' "$TOKJSON" "$1")
  rpc "$_p" | sed -n 's/.*"infoHash":"\([0-9a-fA-F]*\)".*/\1/p' | head -n 1
}

P1=$(printf '{"jsonrpc":"2.0","id":"s","method":"aria2.tellActive","params":[%s%s]}' "$TOKJSON" "$KEYS")
P2=$(printf '{"jsonrpc":"2.0","id":"s","method":"aria2.tellWaiting","params":[%s0,100,%s]}' "$TOKJSON" "$KEYS")

ACT=$(rpc "$P1")
WAI=$(rpc "$P2")
if [ -z "$ACT" ]; then
  log "失败：aria2 RPC 无响应，保留上次输出"
  exit 1
fi

# 把 result 数组里的每个任务对象拆成一行
{
  printf '%s' "$ACT" | sed 's/.*"result":\[//; s/\]\}.*$//; s/},{/}\n{/g'
  printf '%s' "$WAI" | sed 's/.*"result":\[//; s/\]\}.*$//; s/},{/}\n{/g'
} | grep -v '^$' > "$TMP.obj"

NOW=$(date +%s)
: > "$ITEMS"
: > "$TMP.state"
COUNT=0

while IFS= read -r obj; do
  g=$(field "$obj" gid)
  [ -n "$g" ] || continue
  st=$(field "$obj" status)
  [ "$st" = "removed" ] && continue

  tot=$(field "$obj" totalLength);      [ -n "$tot" ]    || tot=0
  done_=$(field "$obj" completedLength); [ -n "$done_" ] || done_=0
  spd=$(field "$obj" downloadSpeed);    [ -n "$spd" ]    || spd=0
  seed=$(field "$obj" numSeeders);      [ -n "$seed" ]   || seed=0

  h=$(field "$obj" infoHash)
  [ -n "$h" ] || h=$(hash_of "$g")

  reason=
  mins=0
  prev=$(awk -F '\t' -v g="$g" '$1==g{print $2; exit}' "$STATE" 2>/dev/null)

  if [ "$tot" = "0" ]; then
    reason=no_metadata
    [ -n "$prev" ] || prev=$NOW
    mins=$(( (NOW - prev) / 60 ))
    printf '%s\t%s\n' "$g" "$prev" >> "$TMP.state"
  elif [ "$spd" = "0" ] && [ "$seed" = "0" ]; then
    [ -n "$prev" ] || prev=$NOW
    mins=$(( (NOW - prev) / 60 ))
    if [ "$mins" -ge "$STALL_MIN" ]; then
      reason=no_speed
    fi
    printf '%s\t%s\n' "$g" "$prev" >> "$TMP.state"
  fi
  # 有速度或有 seeder：不写回 state，等于清除计时

  [ -n "$reason" ] || continue
  [ -n "$h" ] || continue

  COUNT=$((COUNT + 1))
  printf '{"gid":"%s","hash":"%s","magnet":"magnet:?xt=urn:btih:%s","reason":"%s","total":%s,"done":%s,"speed":%s,"seeders":%s,"mins":%s},\n' \
    "$g" "$h" "$h" "$reason" "$tot" "$done_" "$spd" "$seed" "$mins" >> "$ITEMS"
done < "$TMP.obj"

[ -f "$STATE" ] || : > "$STATE"
mv -f "$TMP.state" "$STATE" 2>/dev/null

if [ ! -d /data/adb/nasbak/www ]; then
  log "失败：www 目录不存在"
  exit 1
fi

{
  printf '{"ts":"%s","count":%s,"items":[' "$(date '+%Y-%m-%d %H:%M:%S')" "$COUNT"
  if [ -s "$ITEMS" ]; then
    sed '$ s/,$//' "$ITEMS"
  fi
  printf ']}\n'
} > "$OUT.$$" && mv -f "$OUT.$$" "$OUT"
chmod 644 "$OUT" 2>/dev/null

log "扫描完成 stalled=$COUNT -> $OUT"

# 日志轮转
SZ=$(wc -c < "$LOG" 2>/dev/null || echo 0)
if [ "$SZ" -gt 102400 ]; then
  tail -n 120 "$LOG" > "$TMP.new" && cat "$TMP.new" > "$LOG"
fi

exit 0
