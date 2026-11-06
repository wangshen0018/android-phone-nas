#!/system/bin/sh
# thunder.cgi — 把磁力/种子链接投给本机迅雷（利用其 P2SP 通道加速冷门资源）
#
# 为什么要这条路（2026-11-05 实测）：
#   同一个冷门种子 aria2 卡 190 分钟拿不到元数据（0 peer），
#   迅雷秒级解析出元数据并 1.1MB/s 开始下载。
#   原因不是 trackers 少，而是冷门资源在全网做种归零，
#   只剩迅雷自己的服务器缓存节点能供数据 —— aria2 看不到这些节点。
#
# 动作：
#   ?a=add&h=<info_hash>[&force=1]     投递单条磁力（32/40 位十六进制）
#   ?a=add&u=<urlencoded链接>          投递单条 thunder:// 或 magnet: 链接
#   ?a=status                          返回迅雷任务概况与下载目录占用
#   ?a=last[&rid=<id>]                 返回最近一次投递的确认结果
#   ?a=log                             返回自动确认日志尾部
#   ?a=clear                           强停迅雷（中止全部下载）
#   ?a=ping                            存活探测
#
# 响应：JSON。成功 {"ok":true,...}，失败 {"ok":false,"err":"..."}
#
# 2026-11-06 改进：
#   · 只接受单条链接（原来 h=a,b,c 每次 force-stop 会杀掉前一个面板）
#   · 单实例锁 thunder-add，防两个请求交错 force-stop / am start
#   · ping / status / last / log 不再被「迅雷未安装」前置检查拦住
#   · 有活动下载时不再静默 force-stop，改为拒绝 + 页面二次确认（force=1）
#   · Activity 名改由 resolve-activity 动态解析，硬编码仅作兜底
#   · u= 严格字符集校验，未编码的 & 会被识别并拒绝
#   · 投递先写 pending 状态，thunder-confirm.sh 回写 confirmed/failed，
#     页面按 rid 轮询，不再显示「已投递 ✓」这种假成功
#
# 安全：
#   · 外部输入不能拼进任何 shell 命令；am start 的 -d 参数整体加引号
#   · am start 用 --user 0（CI 上下文是 root/magisk，不指定用户会投到别的用户空间）

printf 'Content-Type: application/json\r\n'
printf 'Cache-Control: no-store\r\n'
printf 'X-Content-Type-Options: nosniff\r\n'
printf '\r\n'

PKG=com.xunlei.downloadprovider
ACT_FALLBACK=com.xunlei.downloadprovider.launch.LaunchActivity2
DLDIR=/sdcard/Android/data/$PKG/files/ThunderDownload
ST=/data/media/0/nasbak/state
LASTF=$ST/thunder-last.json
CONFLOG=$ST/thunder-confirm.log
LOCKLIB=/data/adb/nasbak/bin/lib-lock.sh
BB=/data/adb/magisk/busybox

QS="${QUERY_STRING:-}"

getp() {
  _k="$1"
  printf '%s' "$QS" | tr '&' '\n' | sed -n "s/^$_k=//p" | head -1
}

# URL 解码（busybox 没有现成工具，逐字节 printf）
urldec() {
  _s="$1"
  case "$_s" in *%*) ;; *) printf '%s' "$_s"; return 0 ;; esac
  _out=""
  while :; do
    case "$_s" in
      *%[0-9a-fA-F][0-9a-fA-F]*)
        _pre="${_s%%\%*}"; _r="${_s#*\%}"
        _hx=$(printf '%s' "$_r" | cut -c1-2)
        _ch=$(printf "\\x$_hx" 2>/dev/null)
        _out="$_out$_pre$_ch"; _s=$(printf '%s' "$_r" | cut -c3-)
        ;;
      *) _out="$_out$_s"; break ;;
    esac
  done
  printf '%s' "$_out"
}

jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'; }

installed() { pm list packages 2>/dev/null | grep -q "^package:$PKG$"; }

# 动态解析 magnet: 的默认处理 Activity（App 升级换了类名也不必改代码）
resolve_act() {
  _r=$(cmd package resolve-activity --brief -a android.intent.action.VIEW \
       -d 'magnet:?xt=urn:btih:0000000000000000000000000000000000000000' 2>/dev/null \
       | grep -F "$PKG/" | head -1)
  case "$_r" in
    "$PKG/"*) : ;;
    *) _r="" ;;
  esac
  if [ -n "$_r" ]; then printf '%s' "$_r"; else printf '%s/%s' "$PKG" "$ACT_FALLBACK"; fi
}

# 下载目录里最近 10 分钟还在变的文件数（排除隐藏索引与已搬运标记）
active_count() {
  [ -d "$DLDIR" ] || { echo 0; return 0; }
  find "$DLDIR" -type f ! -name '.*' ! -name '*.nasbak-done' -mmin -10 2>/dev/null | wc -l
}

write_state() { # $1=state  $2=msg  $3=rid
  _ts=$(date '+%Y-%m-%d %H:%M:%S')
  _tmp="$LASTF.$$"
  printf '{"ok":true,"rid":"%s","ts":"%s","state":"%s","msg":"%s"}\n' \
    "$(jesc "$3")" "$_ts" "$(jesc "$1")" "$(jesc "$2")" > "$_tmp" 2>/dev/null \
    && mv -f "$_tmp" "$LASTF" 2>/dev/null
}

ACTN=$(getp a)
[ -z "$ACTN" ] && ACTN="status"

case "$ACTN" in

  add)
    if ! installed; then
      echo '{"ok":false,"err":"迅雷未安装"}'
      exit 0
    fi

    H=$(getp h)
    U=$(getp u)
    FORCE=$(getp force)

    # 未编码的 & 会把链接截断成 query 里的伪参数。白名单之外的 key 一律拒绝。
    EXTRA=$(printf '%s' "$QS" | tr '&' '\n' | sed 's/=.*//' \
            | grep -vE '^(a|u|h|force|rid)$' | head -1)
    if [ -n "$EXTRA" ]; then
      echo '{"ok":false,"err":"链接含未编码的 &（请用 encodeURIComponent 编码，& 写成 %26）"}'
      exit 0
    fi

    URL=""
    if [ -n "$H" ]; then
      case "$H" in
        *,*) echo '{"ok":false,"err":"一次只投一条：h 不接受逗号分隔的多个 hash"}'; exit 0 ;;
      esac
      case "$H" in
        *[!0-9a-fA-F]*) echo '{"ok":false,"err":"h 只能是 32/40 位十六进制"}'; exit 0 ;;
      esac
      L=${#H}
      if [ "$L" -ne 32 ] && [ "$L" -ne 40 ]; then
        echo '{"ok":false,"err":"h 长度必须是 32 或 40 位"}'
        exit 0
      fi
      URL="magnet:?xt=urn:btih:$H"
    fi

    if [ -n "$U" ]; then
      if [ -n "$URL" ]; then
        echo '{"ok":false,"err":"h 与 u 只能二选一"}'
        exit 0
      fi
      U=$(urldec "$U")
      case "$U" in
        magnet:\?xt=urn:btih:*)
          # u= 通道也必须和 h= 一样严格校验 info_hash：
          # 只验前缀会把 magnet:?xt=urn:btih:abc 这种无效链接投进迅雷。
          UH=$(printf '%s' "$U" | sed 's/^magnet:?xt=urn:btih://; s/&.*//')
          case "$UH" in
            *[!0-9a-fA-F]*) echo '{"ok":false,"err":"magnet 的 btih 只能是十六进制"}'; exit 0 ;;
          esac
          UL=${#UH}
          if [ "$UL" -ne 32 ] && [ "$UL" -ne 40 ]; then
            echo '{"ok":false,"err":"magnet 的 btih 必须是 32/40 位"}'
            exit 0
          fi
          ;;
        thunder://*) : ;;
        *) echo '{"ok":false,"err":"u 必须是完整且已编码的 magnet: 或 thunder:// 链接"}'; exit 0 ;;
      esac
      # tr -d 而不是 case 字符集：mksh 会把字符集里的 & 当后台操作符
      BAD=$(printf '%s' "$U" | tr -d 'A-Za-z0-9:/._?=+&%')
      if [ -n "$BAD" ]; then
        echo '{"ok":false,"err":"链接含非法字符"}'
        exit 0
      fi
      URL="$U"
    fi

    if [ -z "$URL" ]; then
      echo '{"ok":false,"err":"缺少 h 或 u"}'
      exit 0
    fi

    # 上一次还在等确认 → 拒绝，否则新的 force-stop 会杀掉刚拉起的面板
    if [ -f "$LASTF" ] && [ "$FORCE" != "1" ]; then
      PST=$(grep -o '"state":"[^"]*"' "$LASTF" 2>/dev/null | head -1 | sed 's/.*:"//; s/"//')
      PMT=$($BB stat -c %Y "$LASTF" 2>/dev/null)
      PAGE=$(( $(date +%s) - ${PMT:-0} ))
      if [ "$PST" = "pending" ] && [ "$PAGE" -lt 60 ]; then
        echo '{"ok":false,"err":"上一次投递还在等迅雷确认，请稍候再投"}'
        exit 0
      fi
    fi

    # 有活动下载时不静默 force-stop（force-stop 是面板必弹的前提，但不能中断在下的任务）
    ACTIVE=$(active_count)
    if [ "$ACTIVE" -gt 0 ] && [ "$FORCE" != "1" ]; then
      echo "{\"ok\":false,\"err\":\"迅雷正在下载（${ACTIVE} 个近期活动文件），投递会强制停止它。确认继续请重试并允许强制。\",\"active\":$ACTIVE,\"needForce\":true}"
      exit 0
    fi

    # 单实例锁：两个请求交错 force-stop / am start 会互相杀面板
    if [ -r "$LOCKLIB" ]; then
      . "$LOCKLIB"
    else
      echo '{"ok":false,"err":"缺少 lib-lock.sh，拒绝无保护投递"}'
      exit 0
    fi
    if ! lock_acquire thunder-add; then
      echo '{"ok":false,"err":"已有投递在进行中，请稍候"}'
      exit 0
    fi
    trap 'lock_release thunder-add' 0 INT TERM

    RID="$(date +%s)_$$"
    mkdir -p "$ST" 2>/dev/null
    write_state pending "已拉起迅雷，等待确认面板" "$RID"

    TARGET=$(resolve_act)
    # 息屏状态下 am start 会返回成功但 Activity 不真正起来，先无条件唤醒
    input keyevent KEYCODE_WAKEUP 2>/dev/null

    # 迅雷已在前台时 am start 会被主界面吞掉，不弹「添加链接任务」面板；
    # 实测 force-stop 之后再 start 面板必定弹出，所以默认仍走这条。
    am force-stop "$PKG" 2>/dev/null
    sleep 1
    STOPPED=1

    O=$(am start --user 0 -a android.intent.action.VIEW -d "$URL" -n "$TARGET" 2>&1)
    case "$O" in
      *Error*|*error*|*Exception*)
        # 动态解析出的组件可能不被接受，回退硬编码再试一次
        O=$(am start --user 0 -a android.intent.action.VIEW -d "$URL" -n "$PKG/$ACT_FALLBACK" 2>&1)
        ;;
    esac
    case "$O" in
      *Error*|*error*|*Exception*)
        EMSG=$(jesc "$O")
        write_state failed "am start 失败：${EMSG}" "$RID"
        echo '{"ok":false,"err":"拉起迅雷失败，详见 a=log"}'
        exit 0
        ;;
    esac

    # 必须异步：uiautomator dump 单轮 3~5 秒，同步等会让浏览器先超时。
    # rid 传下去，confirm 结束时回写真实结果。
    setsid nohup sh /data/adb/nasbak/bin/thunder-confirm.sh "$RID" >/dev/null 2>&1 < /dev/null &

    sleep 1
    N=$(ls -1 "$DLDIR" 2>/dev/null | grep -vc '^\.')
    echo "{\"ok\":true,\"submitted\":1,\"rid\":\"$RID\",\"interrupted\":$STOPPED,\"tasks\":${N:-0},\"state\":\"pending\"}"
    ;;

  status)
    INST=0
    installed && INST=1
    if $BB pgrep -f "xunlei" >/dev/null 2>&1; then RUN=1; else RUN=0; fi
    N=0; SZ=0
    if [ -d "$DLDIR" ]; then
      N=$(ls -1 "$DLDIR" 2>/dev/null | grep -vc '^\.')
      SZ=$($BB du -sb "$DLDIR" 2>/dev/null | awk '{print $1}')
      [ -z "$SZ" ] && SZ=0
    fi
    echo "{\"ok\":true,\"installed\":$INST,\"running\":$RUN,\"tasks\":${N:-0},\"bytes\":${SZ:-0},\"dir\":\"$(jesc "$DLDIR")\"}"
    ;;

  last)
    RID=$(getp rid)
    if [ ! -f "$LASTF" ]; then
      echo '{"ok":true,"state":"none","msg":"暂无投递记录"}'
    elif [ -z "$RID" ]; then
      cat "$LASTF"
    elif grep -q "\"rid\":\"$RID\"" "$LASTF" 2>/dev/null; then
      cat "$LASTF"
    else
      echo '{"ok":true,"state":"pending","msg":"等待本次投递的确认结果"}'
    fi
    ;;

  log)
    # 换行转成 | 带回前端再还原，避免 JSON 里出现裸换行
    if [ -f "$CONFLOG" ]; then
      TXT=$(tail -n 20 "$CONFLOG" 2>/dev/null \
            | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r' | tr '\n' '|')
    else
      TXT="（暂无确认日志）"
    fi
    echo "{\"ok\":true,\"log\":\"$TXT\"}"
    ;;

  clear)
    if ! installed; then
      echo '{"ok":false,"err":"迅雷未安装"}'
      exit 0
    fi
    am force-stop "$PKG" 2>/dev/null
    sleep 1
    echo '{"ok":true,"msg":"已强停迅雷（下载中止，已下载文件保留在下载目录）"}'
    ;;

  ping)
    echo '{"ok":true,"msg":"thunder.cgi alive"}'
    ;;

  *)
    echo '{"ok":false,"err":"未知动作"}'
    ;;
esac

exit 0
