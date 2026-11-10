#!/system/bin/sh
. "$(dirname "$0")/lib-path.sh"
# thunder-confirm.sh — 点掉迅雷「添加链接任务」面板上的「立即下载」
#
# 为什么单独成文件（2026-11-05）：
#   busybox httpd 是单线程的，CGI 里 fork 的后台子进程不会被"丢弃"——
#   httpd 会一直等它们退出才结束响应。实测把 auto_confirm 放在 CGI 里 & 掉，
#   浏览器仍然要等 40 秒以上才收到 JSON，前端早已超时。
#   所以确认动作必须由外部进程做：CGI 只负责 am start 后立刻返回，
#   本脚本用 setsid + nohup 完全脱离 httpd 的进程组，独立跑完。
#
# 触发方式（thunder.cgi 投递成功后，带 rid）：
#   setsid nohup sh $NASBAK_HOME/bin/thunder-confirm.sh "$RID" >/dev/null 2>&1 < /dev/null &
#
# 2026-11-06 改进：
#   · 单实例锁 thunder-confirm：两个实例抢同一个 uiautomator dump 会互相踩
#   · 中间文件加 $$：多实例不再删掉对方的 XML
#   · 结果回写 state/thunder-last.json（原子替换），页面按 rid 轮询，
#     CGI 不再显示「已投递 ✓」这种未经确认的假成功
#   · 面板标题 / 按钮文案改为多候选，App 小幅改版不必立刻改代码
#
# 节点特征（迅雷 25.2.91 实测）：
#   面板标题  text="添加链接任务"
#   确认按钮  text="立即下载"  resource-id=.../link_hub_after_cta  clickable=false
#   按钮容器可点，按 cta 的 bounds 取中心 tap 必中（两者重叠）

ST=$NASBAK_ROOT/state
LASTF=$ST/thunder-last.json
LOG=$ST/thunder-confirm.log
TMPU=$NASBAK_TMP/_xl_confirm.$$.xml
LOCKLIB=$NASBAK_HOME/bin/lib-lock.sh
RID="${1:-}"

# 多候选文案：App 改版或不同入口时不必立刻改代码
PANEL_RE='添加链接任务|新建下载任务|添加下载任务|添加任务|创建下载'
BTN_RE='立即下载|开始下载|立即开始|确定下载|立刻下载'

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$RID] $*" >> "$LOG" 2>/dev/null; }
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n\t'; }

set_state() { # $1=state  $2=msg
  _ts=$(date '+%Y-%m-%d %H:%M:%S')
  _tmp="$LASTF.$$"
  printf '{"ok":true,"rid":"%s","ts":"%s","state":"%s","msg":"%s"}\n' \
    "$(jesc "$RID")" "$_ts" "$(jesc "$1")" "$(jesc "$2")" > "$_tmp" 2>/dev/null \
    && mv -f "$_tmp" "$LASTF" 2>/dev/null
  log "$1: $2"
}

mkdir -p "$ST" 2>/dev/null

# 单实例锁：拿不到锁直接退出，且不写状态（否则会覆盖正在跑的那个实例的结果）
if [ -r "$LOCKLIB" ]; then
  . "$LOCKLIB"
else
  log "缺少 lib-lock.sh，无法保证单实例，本次退出"
  set_state failed "缺少锁库，未执行自动确认"
  exit 1
fi
if ! lock_acquire thunder-confirm; then
  log "已有确认实例在运行，本次退出（不改写状态）"
  exit 0
fi
trap 'rm -f "$TMPU"; lock_release thunder-confirm' 0 INT TERM

rm -f "$TMPU" 2>/dev/null

# 面板要先加载出来（含向服务器拉种子元数据），实测 2~8 秒
sleep 2

_try=0
_seen=0
while [ "$_try" -lt 8 ]; do
  uiautomator dump "$TMPU" >/dev/null 2>&1
  if [ ! -s "$TMPU" ]; then
    _try=$((_try+1)); sleep 1; continue
  fi

  if $BB grep -qE "$PANEL_RE" "$TMPU" 2>/dev/null; then
    _seen=1
  elif [ "$_seen" = "1" ]; then
    # 见过面板、现在没了 → 已经被确认（或用户手动点了）
    rm -f "$TMPU" 2>/dev/null
    set_state confirmed "面板已关闭，任务已建立"
    exit 0
  else
    # 从没出现过，可能还在加载，继续等而不是提前放弃
    _try=$((_try+1)); sleep 1; continue
  fi

  _b=$($BB grep -oE "text=\"($BTN_RE)\"[^>]*bounds=\"\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]\"" "$TMPU" 2>/dev/null \
       | head -1 \
       | sed -n 's/.*bounds="\[\([0-9]*\),\([0-9]*\)\]\[\([0-9]*\),\([0-9]*\)\]".*/\1 \2 \3 \4/p')
  if [ -n "$_b" ]; then
    set -- $_b
    _x=$(( ($1 + $3) / 2 ))
    _y=$(( ($2 + $4) / 2 ))
    input tap "$_x" "$_y" 2>/dev/null
    rm -f "$TMPU" 2>/dev/null
    set_state confirmed "已点击立即下载（${_x},${_y}）"
    exit 0
  fi

  _try=$((_try+1))
  sleep 1
done

rm -f "$TMPU" 2>/dev/null
# 常见原因：未登录、锁屏、版权拦截、面板文案变化。页面会据此提示人工介入。
set_state failed "未找到确认按钮（尝试 $_try 次），需人工在迅雷里点一下；可点日志查看"
exit 1
