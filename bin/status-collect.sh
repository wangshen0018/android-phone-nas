#!/system/bin/sh
# status-collect.sh — 后台采集系统状态，写入缓存 JSON
# 由 daemon 或 crond 周期调用，CGI 只读缓存（避免 CGI 里做重活导致 httpd 超时）

DATA=/data/media/0/nasbak/state
BASE=/data/media/0/nasbak
INBOX=$BASE/inbox
ARC=$BASE/archive
BB=/data/adb/magisk/busybox
OUT=$DATA/status-cache.json
TMP=$OUT.$$.tmp

# 锁库缺失就不跑：并发下的半截 JSON 比旧缓存更难排查
if [ -r /data/adb/nasbak/bin/lib-lock.sh ]; then
  . /data/adb/nasbak/bin/lib-lock.sh
else
  echo "$(date '+%F %T') 缺少 lib-lock.sh，本次退出" >> /data/adb/nasbak/logs/status-collect.log
  exit 1
fi
# 每 2 分钟跑一次，若上一轮还没跑完（采集慢）就会被 crond 拉起第二个实例，
# 两个实例抢同一个 status-cache.json.tmp，会写出半截 JSON。
if ! lock_acquire status-collect; then
  echo "$(date '+%F %T') 已有实例在运行，本次退出" >> /data/adb/nasbak/logs/status-collect.log
  exit 0
fi
trap 'lock_release status-collect' 0
trap 'lock_release status-collect; exit 1' INT TERM

# ---------- 看门狗：防止自身卡死后锁被永久占住 ----------
# 2026-11-03 真实事故：本脚本卡在 tr 读 /proc/*/cmdline 上，pid 一直存活，
# lib-lock 的「持锁进程还活着」判断因此永远认为有人在跑，锁再也不释放，
# status-cache.json 停更 3.4 小时，面板全是旧数据。
# 单靠锁看不见"进程活着但不动了"，所以必须在进程内部再设一道时间上限：
#   · 正常采集约 24 秒，给 180 秒足够余量
#   · 超时就 kill -9 自己，trap 0 会释放锁，下一轮 crond 能正常接手
WATCHDOG_MAX=180
SELF=$$
(
  sleep "$WATCHDOG_MAX"
  if [ -d "/proc/$SELF" ]; then
    echo "$(date '+%F %T') 看门狗超时 ${WATCHDOG_MAX}s，强制终止 pid=$SELF" >> /data/adb/nasbak/logs/status-collect.log
    kill -9 "$SELF" 2>/dev/null
    rm -rf "$LOCKDIR/status-collect.lock" 2>/dev/null
  fi
) &
WATCHDOG_PID=$!

port_open() { timeout 2 $BB nc -z 127.0.0.1 "$1" 2>/dev/null; }

jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'; }

# 按命令找到脚本对应的日志文件（找不到就返回空，页面显示"无日志"）
# 候选顺序：nasbak/logs → 同名目录 → srv/data → 首段名兜底 → state
# 兜底那两条是为 fixadb-run.sh→fixadb.log、gyp-backup.sh→gyp/gyp.log 这类命名不一致的脚本。
# 注意：命令可能带参数（如 media-gc.sh --apply），要取带 .sh 的那个路径段，
# 不能取末尾词，否则拿到的是 "--apply"，日志永远找不到。
task_log() {
  _p=$(printf '%s' "$1" | grep -o '[^ ]*\.sh' 2>/dev/null | head -1)
  [ -z "$_p" ] && _p=$(printf '%s' "$1" | awk '{print $NF}')
  _n=$(basename "$_p" .sh 2>/dev/null)
  [ -z "$_n" ] && return 1
  _b=$(printf '%s' "$_n" | cut -d- -f1)
  for _f in \
    "/data/adb/nasbak/logs/$_n.log" \
    "/data/local/tmp/$_n/$_n.log" \
    "/data/adb/srv/data/$_n.log" \
    "/data/adb/srv/data/$_b.log" \
    "/data/local/tmp/$_b/$_b.log" \
    "/data/media/0/nasbak/state/$_n.log" ; do
    [ -f "$_f" ] && { printf '%s' "$_f"; return 0; }
  done
  return 1
}

{
  printf '{"ts":%s,' "$(date +%s)"

  # ---- 服务状态 ----
  printf '"services":['
  F=1
  # 进程检测统一走 busybox pgrep -f，不再遍历 /proc/*/cmdline。
  # 为什么改（2026-11-03 实际卡死 3.4 小时）：
  #   本机约 920 个进程，逐个 `tr '\0' ' ' < /proc/N/cmdline` 要 13 秒，
  #   而且实测有进程会让 tr 永久阻塞 —— 一旦卡住，持锁 pid 一直"存活"，
  #   lib-lock 就永远认为有人在跑，锁不释放、缓存停更。
  #   pgrep -f 是单次 C 实现扫描，15 次调用合计 1 秒，且没有子进程阻塞风险。
  pg() { $BB pgrep -f "$1" 2>/dev/null | head -1; }

  HPID=$(pg "httpd -p 8083")
  if [ -n "$HPID" ]; then S=true; D="监听 8083 · pid $HPID"; else S=false; D="未监听"; fi
  printf '{"name":"判定页 httpd","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"; F=0

  if port_open 5244; then S=true; D="监听 5244 · WebDAV /dav"; else S=false; D="未监听"; fi
  printf ',{"name":"alist","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  if port_open 6800; then S=true; D="监听 6800"; else S=false; D="未监听"; fi
  printf ',{"name":"aria2","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  if port_open 5555; then S=true; D="监听 5555"; else S=false; D="未监听"; fi
  printf ',{"name":"adb 无线调试","ok":%s,"detail":"%s"}' "$S" "$(jesc "$D")"

  # crond
  CPID=$(pg "crond -c")
  if [ -n "$CPID" ]; then
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

  # ---- 定时任务 ----
  # 直接从 crond 实际使用的 crontab 解析，页面不再硬编码（原来写死成 */10，
  # 实际已改成 */2，页面长期在骗人）。这里上报原始表达式、命令与日志留痕，
  # 中文名称、频率白话、下次执行时间都由前端算，改 crontab 页面自动跟着变。
  CRONF=/data/adb/modules/GGAT_10007/crond/root
  printf '"tasks":['
  FT=1
  if [ -f "$CRONF" ]; then
    while IFS= read -r ln; do
      case "$ln" in ''|'#'*) continue ;; esac
      T1=$(printf '%s' "$ln" | awk '{print $1}')
      T2=$(printf '%s' "$ln" | awk '{print $2}')
      T3=$(printf '%s' "$ln" | awk '{print $3}')
      T4=$(printf '%s' "$ln" | awk '{print $4}')
      T5=$(printf '%s' "$ln" | awk '{print $5}')
      TC=$(printf '%s' "$ln" | awk '{$1="";$2="";$3="";$4="";$5="";sub(/^ +/,"");print}')
      [ -z "$TC" ] && continue
      # 上次执行留痕：日志文件的 mtime 决定"多久没跑过"，最后一行说明"跑成什么结果"。
      # 只报事实（时间 + 尾行），是否算失败交给页面判断，避免这里误判。
      # 注意 status-collect 自己的日志在本轮末尾才写，所以读到的正是上一轮的结果。
      TL=$(task_log "$TC")
      LT=0; LL=""
      if [ -n "$TL" ]; then
        LT=$(stat -c %Y "$TL" 2>/dev/null); [ -z "$LT" ] && LT=0
        LL=$(tail -1 "$TL" 2>/dev/null | tr -d '\r\n\t' | cut -c1-120)
      fi
      [ "$FT" = "1" ] || printf ','
      printf '{"min":"%s","hour":"%s","dom":"%s","mon":"%s","dow":"%s","cmd":"%s","log":"%s","lt":%s,"ll":"%s"}' \
        "$(jesc "$T1")" "$(jesc "$T2")" "$(jesc "$T3")" "$(jesc "$T4")" "$(jesc "$T5")" "$(jesc "$TC")" \
        "$(jesc "$TL")" "$LT" "$(jesc "$LL")"
      FT=0
    done < "$CRONF"
  fi
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

# 正常跑完 → 撤掉看门狗（注意结尾不能带换行，否则 tail -c 1 校验会永远失败）
kill -9 "$WATCHDOG_PID" 2>/dev/null

# 校验 JSON 完整性再落地
if [ -s "$TMP" ] && [ "$(tail -c 1 "$TMP")" = "}" ]; then
  mv -f "$TMP" "$OUT"
  echo "$(date '+%F %T') 状态已更新 $(wc -c < "$OUT") 字节" >> /data/adb/nasbak/logs/status-collect.log
else
  echo "$(date '+%F %T') 采集失败(JSON不完整)" >> /data/adb/nasbak/logs/status-collect.log
  rm -f "$TMP"
fi