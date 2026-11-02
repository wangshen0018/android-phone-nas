#!/system/bin/sh
# status-collect.sh — 后台采集系统状态，写入缓存 JSON
# 由 daemon 或 crond 周期调用，CGI 只读缓存（避免 CGI 里做重活导致 httpd 超时）

DATA=/data/media/0/nasbak/state
BASE=/data/media/0/nasbak
INBOX=$BASE/inbox
ARC=$BASE/archive
BB=/data/adb/magisk/busybox
OUT=$DATA/status-cache.json
TMP=$OUT.tmp

port_open() { timeout 2 $BB nc -z 127.0.0.1 "$1" 2>/dev/null; }

jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'; }

{
  printf '{"ts":%s,' "$(date +%s)"

  # ---- 服务状态 ----
  printf '"services":['
  F=1
  # httpd 8083：进程检测(本脚本非 CGI，遍历 /proc 安全)
  FOUND=""
  for p in /proc/[0-9]*/cmdline; do
    c=$(tr '\0' ' ' < "$p" 2>/dev/null)
    case "$c" in *"httpd -p 8083"*) FOUND=1; break;; esac
  done 2>/dev/null
  if [ -n "$FOUND" ]; then S=true; D="监听 8083"; else S=false; D="未监听"; fi
  printf '{"name":"判定页 httpd","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"; F=0

  if port_open 5244; then S=true; D="监听 5244 · WebDAV /dav"; else S=false; D="未监听"; fi
  printf ',{"name":"alist","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  if port_open 6800; then S=true; D="监听 6800"; else S=false; D="未监听"; fi
  printf ',{"name":"aria2","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  if port_open 5555; then S=true; D="监听 5555"; else S=false; D="未监听"; fi
  printf ',{"name":"adb 无线调试","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  # crond
  CRONP=""
  for p in /proc/[0-9]*/cmdline; do c=$(tr '\0' ' ' < "$p" 2>/dev/null); case "$c" in *crond*) CRONP="$c";; esac; done 2>/dev/null
  if [ -n "$CRONP" ]; then
    S=true
    TASKS=$($BB crontab -c /data/adb/modules/GGAT_10007/crond -l 2>/dev/null | grep -vc '^#')
    D="运行中 · $TASKS 个任务"
  else S=false; D="未运行"; fi
  printf ',{"name":"crond 定时任务","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  # daemon
  DPID=$(cat /data/adb/nasbak/daemon.pid 2>/dev/null | tr -d ' \r\n')
  if [ -n "$DPID" ] && [ -d "/proc/$DPID" ]; then S=true; D="运行中 · pid $DPID"; else S=false; D="未运行"; fi
  printf ',{"name":"判定调度 daemon","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  # tailscale
  if [ -S /data/adb/tailscale/run/tailscaled.sock ] 2>/dev/null; then S=true; D="tailscaled 运行中"; else S=false; D="未运行"; fi
  printf ',{"name":"tailscale","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  # 电池保护
  if [ -f /data/adb/srv/battguard.pid ] && [ -d "/proc/$(cat /data/adb/srv/battguard.pid 2>/dev/null | tr -d ' \r\n')" ]; then
    S=true; D="运行中"; else S=false; D="未运行"; fi
  printf ',{"name":"电池保护","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  # 光鸭云盘同步
  GYP_LOG=/data/local/tmp/gyp/gyp.log
  if [ -f "$GYP_LOG" ]; then
    LAST=$(tail -1 "$GYP_LOG" 2>/dev/null | cut -c1-19)
    D="最近同步 $LAST"
  else D="无记录"; fi
  S=true
  printf ',{"name":"云盘同步","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  # 磁力搜索：与判定页共用 8083 httpd，检查子目录是否已部署
  if [ -f /data/adb/nasbak/www/magnet/index.html ]; then
    S=true; D="同源 /magnet/ · 与 8083 共用"
  else S=false; D="未部署"; fi
  printf ',{"name":"磁力搜索","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  # AriaNg 下载管理：静态页 + 依赖 6800 RPC
  if [ -f /data/adb/nasbak/www/ariang/index.html ]; then
    if port_open 6800; then S=true; D="页面就绪 · RPC 6800 可连"; else S=false; D="页面就绪 · RPC 未连"; fi
  else S=false; D="未部署"; fi
  printf ',{"name":"下载管理 AriaNg","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"
  printf '],'

  # ---- 存储统计 ----
  IN_N=$(find "$INBOX" -type f ! -path "*/_dup_backup/*" 2>/dev/null | wc -l | tr -d ' ')
  ARC_N=$(find "$ARC" -type f 2>/dev/null | wc -l | tr -d ' ')
  DUP_N=$(find "$INBOX/_dup_backup" -type f 2>/dev/null | wc -l | tr -d ' ')
  TRASH_N=$(find "$BASE/_待删" -type f 2>/dev/null | wc -l | tr -d ' ')
  IN_S=$($BB du -sb "$INBOX" 2>/dev/null | awk '{print $1}'); [ -z "$IN_S" ] && IN_S=0
  DUP_S=$($BB du -sb "$INBOX/_dup_backup" 2>/dev/null | awk '{print $1}'); [ -z "$DUP_S" ] && DUP_S=0
  ARC_S=$($BB du -sb "$ARC" 2>/dev/null | awk '{print $1}'); [ -z "$ARC_S" ] && ARC_S=0

  printf '"files":{"inboxN":%s,"inboxS":%s,"archiveN":%s,"archiveS":%s,"dupN":%s,"dupS":%s,"trashN":%s},' \
    "$IN_N" "$IN_S" "$ARC_N" "$ARC_S" "$DUP_N" "$DUP_S" "$TRASH_N"

  # ---- 判读进度 ----
  # done = analysis 记录数；pending = 待判队列行数（不再遍历 loc-*.tsv，
  # 那个口径会把已出队的历史文件算成"待判"，导致进度永远停在 848）
  DONE=$(ls "$DATA/analysis" 2>/dev/null | grep -c '\.json$')
  PEND=0
  [ -f "$DATA/pending.queue" ] && PEND=$(wc -l < "$DATA/pending.queue" 2>/dev/null | tr -d ' ')
  printf '"judge":{"done":%s,"pending":%s},' "${DONE:-0}" "${PEND:-0}"

  # ---- 分类分布 ----
  printf '"cats":{'
  F=1
  for c in work home screenshot video other unclassified; do
    n=$(grep -c "\"cat\":\"$c\"" "$DATA/analysis.jsonl" 2>/dev/null | tr -d ' ')
    [ "$F" = "1" ] || printf ','
    printf '"%s":%s' "$c" "${n:-0}"; F=0
  done
  printf '},'

  # ---- 模型统计 ----
  printf '"models":{'
  F=1
  for m in zhipu video rule circuit; do
    case "$m" in
      zhipu)  n=$(grep -c '"model":"minicpm-v/zhipu' "$DATA/analysis.jsonl" 2>/dev/null | tr -d ' ');;
      video)  n=$(grep -c '"model":"rule:video"' "$DATA/analysis.jsonl" 2>/dev/null | tr -d ' ');;
      rule)   n=$(grep -c '"model":"minicpm-v"' "$DATA/analysis.jsonl" 2>/dev/null | tr -d ' ');;
      circuit) n=$(grep -c '"model":"circuit-break"' "$DATA/analysis.jsonl" 2>/dev/null | tr -d ' ');;
    esac
    [ "$F" = "1" ] || printf ','
    printf '"%s":%s' "$m" "${n:-0}"; F=0
  done
  printf '},'

  # ---- 磁盘 ----
  # busybox df 输出单位是 1K-block（不是字节）；前端 fmtB() 按字节换算，
  # 直接传会导致 225G 显示成 0.2G。这里一律换算成字节再上报。
  # 注意：mksh 的 $(( )) 是 32 位有符号，225G*1024 会溢出错峰，
  # 必须交给 awk 的双精度做乘法（2^53 以内精确）。
  DF=$($BB df -k /data/media/0 2>/dev/null | tail -1)
  TOTB=$(printf '%s' "$DF" | awk '{printf "%.0f", $2*1024}')
  USEDB=$(printf '%s' "$DF" | awk '{printf "%.0f", $3*1024}')
  AVAILB=$(printf '%s' "$DF" | awk '{printf "%.0f", $4*1024}')
  printf '"disk":{"total":%s,"used":%s,"avail":%s,"unit":"bytes"},' "${TOTB:-0}" "${USEDB:-0}" "${AVAILB:-0}"

  # ---- 台账 ----
  LED=$DATA/ledger.jsonl
  printf '"ledger":{"recv":%s,"mvdate":%s,"arc":%s,"dup":%s},' \
    "$(grep -c '"act":"recv"' "$LED" 2>/dev/null | tr -d ' ' || echo 0)" \
    "$(grep -c '"act":"mvdate"' "$LED" 2>/dev/null | tr -d ' ' || echo 0)" \
    "$(grep -c '"act":"arc"' "$LED" 2>/dev/null | tr -d ' ' || echo 0)" \
    "$(grep -c '"act":"dup"' "$LED" 2>/dev/null | tr -d ' ' || echo 0)"

  EV_N=$(wc -l < "$DATA/events.jsonl" 2>/dev/null | tr -d ' ')
  printf '"events":%s}' "${EV_N:-0}"
} > "$TMP" 2>/dev/null

# 校验 JSON 完整性再落地
if [ -s "$TMP" ] && [ "$(tail -c 1 "$TMP")" = "}" ]; then
  mv -f "$TMP" "$OUT"
  echo "$(date '+%F %T') 状态已更新 $(wc -c < "$OUT") 字节" >> /data/adb/nasbak/logs/status-collect.log
else
  echo "$(date '+%F %T') 采集失败(JSON不完整)" >> /data/adb/nasbak/logs/status-collect.log
  rm -f "$TMP"
fi