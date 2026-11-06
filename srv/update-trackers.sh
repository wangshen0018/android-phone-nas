#!/system/bin/sh
# update-trackers.sh — 刷新 aria2 的公共 BT tracker 列表（在 K40 设备侧执行）
#
# 背景（2026-11-05 实测）：srv/aria2.conf 里 bt-tracker 为空，磁力搜索页提交的
# 又是不带 tr= 的裸磁力，导致 aria2 只能靠 DHT；带种子的任务则沿用种子内置的
# 2010 年代老 tracker（demonoid / publicbt / 10.rarbg / h33t ...），日志里全是
# DNS 失败、403、超时，表现为「添加任务后长期 0 速度」。
# aria2 的 --bt-tracker 是在 --bt-exclude-tracker 之后追加到 announce 列表的，
# 对裸磁力和带老 tracker 的种子同时生效，因此只改全局配置就能覆盖两个入口。
#
# 源：XIU2/TrackersListCollection 的 best_aria2.txt（项目每天更新，已是逗号分隔格式）
#   设备实测 2026-11-05：cdn.jsdelivr.net 可达（HTTP 200 / 2725B / 70 条）；
#   cf.trackerslist.com、raw.githubusercontent.com 在设备和本机都超时。
#   因此主源与备源全部走 jsdelivr 的三个 CDN 域名，不要用官方 cf 域名。
#
# 做两件事：
#   1) 把 bt-tracker= 写回 aria2.conf（重启后仍然有效）
#   2) 用 aria2.changeGlobalOption 热改（立即生效，不重启、不丢现有任务）
#
# 用法：sh update-trackers.sh [--check]
#   --check  只拉取并校验，打印结果，不改配置、不热改
#
# 由 cron 每周一 04:20 调用；备份与日志都在 /data/adb/srv/data/。

set -u

CONF=/data/adb/srv/aria2.conf
DATA=/data/adb/srv/data
LISTFILE=$DATA/trackers.txt
LOG=$DATA/trackers-update.log
BB=/data/adb/magisk/busybox
TMP=$DATA/_tk.$$
LOCKNAME=update-trackers
LOCKFALL=/data/local/tmp/nasbak-locks/$LOCKNAME.lock
HAVE_LIBLOCK=0

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

mkdir -p "$DATA" 2>/dev/null

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
  printf '%s\n' "$*"
}

cleanup() {
  rm -f "$TMP" "$TMP.conf" 2>/dev/null
  if [ "$HAVE_LIBLOCK" = 1 ]; then
    lock_release "$LOCKNAME"
  else
    rm -rf "$LOCKFALL" 2>/dev/null
  fi
}
trap cleanup 0 INT TERM

# ---- 单实例锁：优先复用 nasbak 的 lib-lock.sh，缺文件时用 mkdir 原子锁兜底 ----
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

# ---- 拉取（三个 jsdelivr 域名依次重试）----
URLS='https://cdn.jsdelivr.net/gh/XIU2/TrackersListCollection/best_aria2.txt
https://fastly.jsdelivr.net/gh/XIU2/TrackersListCollection/best_aria2.txt
https://gcore.jsdelivr.net/gh/XIU2/TrackersListCollection/best_aria2.txt'

LIST=
SRC=
for u in $URLS; do
  rm -f "$TMP"
  curl -sS -m 20 -o "$TMP" "$u" 2>/dev/null || continue
  [ -s "$TMP" ] || continue
  _l=$(tr -d '\r\n' < "$TMP" | tr -d ' ')
  # 校验一：只含 URL 安全字符，挡掉错误页 / HTML / 被劫持的内容
  # 不用 case + [!...]：设备上的 mksh 会把字符集里的 & 解析成后台操作符，
  # 实测报 "syntax error: unexpected '&'"（2026-11-05）。改用 tr 删除合法字符后看残留。
  _bad=$(printf '%s' "$_l" | tr -d 'A-Za-z0-9:/.,_?=&%@#-')
  if [ -n "$_bad" ]; then
    log "内容含非法字符，换下一个源：$u"
    continue
  fi
  # 校验二：至少 10 条，且总长合理
  _n=$(printf '%s' "$_l" | tr ',' '\n' | grep -c '://')
  [ "$_n" -ge 10 ] || { log "条目过少($_n)，换下一个源：$u"; continue; }
  [ "${#_l}" -lt 20000 ] || { log "内容过长，换下一个源：$u"; continue; }
  LIST=$_l
  SRC=$u
  break
done

if [ -z "$LIST" ]; then
  log "失败：三个源都不可用，保持现有配置不变"
  exit 1
fi

CNT=$(printf '%s' "$LIST" | tr ',' '\n' | grep -c '://')
log "拉取成功 src=$SRC count=$CNT bytes=${#LIST}"

if [ "$CHECK" = 1 ]; then
  printf 'CHECK OK  count=%s  bytes=%s\n' "$CNT" "${#LIST}"
  exit 0
fi

# ---- 写回 aria2.conf（先备份，只保留最近 3 份）----
cp -f "$CONF" "$DATA/aria2.conf.bak-tk-$(date +%Y%m%d%H%M%S)" 2>/dev/null
ls -t "$DATA"/aria2.conf.bak-tk-* 2>/dev/null | tail -n +4 | while read f; do rm -f "$f"; done

if grep -q '^bt-tracker=' "$CONF" 2>/dev/null; then
  $BB awk -v v="$LIST" '/^bt-tracker=/{print "bt-tracker=" v; next} {print}' "$CONF" > "$TMP.conf"
  if [ -s "$TMP.conf" ]; then
    cat "$TMP.conf" > "$CONF"
  else
    log "失败：awk 生成空文件，配置未改动"
    exit 1
  fi
else
  printf '\nbt-tracker=%s\n' "$LIST" >> "$CONF"
fi

printf '%s\n' "$LIST" > "$LISTFILE"
grep -q '^bt-tracker=' "$CONF" || { log "失败：写回后仍找不到 bt-tracker 行"; exit 1; }
log "已写回 $CONF"

# ---- 热改运行中的 aria2（不重启、不丢任务）----
SECRET=$(sed -n 's/^[[:space:]]*rpc-secret[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | tr -d '\r')
PORT=$(sed -n 's/^[[:space:]]*rpc-listen-port[[:space:]]*=[[:space:]]*//p' "$CONF" | head -n 1 | tr -d '\r')
[ -n "$PORT" ] || PORT=6800

if [ -n "$SECRET" ]; then
  PARAMS='["token:'"$SECRET"'",{"bt-tracker":"'"$LIST"'"}]'
else
  PARAMS='[{"bt-tracker":"'"$LIST"'"}]'
fi
PAYLOAD='{"jsonrpc":"2.0","id":"tk","method":"aria2.changeGlobalOption","params":'"$PARAMS"'}'

R=$(curl -s -m 12 -H 'Content-Type: application/json' -d "$PAYLOAD" "http://127.0.0.1:$PORT/jsonrpc" 2>/dev/null)
case "$R" in
  *'"result"'*) log "热改成功：$R" ;;
  *)            log "热改未确认（aria2 可能在重启中），配置已落盘，下次启动生效：$R" ;;
esac

# ---- 日志轮转：超过 100KB 只留最后 120 行 ----
SZ=$($BB stat -c %s "$LOG" 2>/dev/null || echo 0)
if [ "$SZ" -gt 102400 ]; then
  tail -n 120 "$LOG" > "$TMP.log" && cat "$TMP.log" > "$LOG"
  rm -f "$TMP.log"
fi

exit 0
