#!/system/bin/sh
. "$(dirname "$0")/../../bin/lib-path.sh"
# scrcpy.cgi — 投屏服务按需启停
#
# 动作：
#   ?a=status   查询状态（默认）
#   ?a=start    启动 scrcpy-server（监听 8886）
#   ?a=stop     停止
#
# 为什么改成按需（2026-11-07 用户要求）：
#   屏幕常亮 + 硬件 H.264 编码长期跑会持续发热，没人看的时候没必要占资源。
#   所以不再由 service.d 开机拉起、也不进 crond 看护，改为页面按钮触发。
#
# 前提：8083 的 busybox httpd 以 root 运行，CGI 可直接执行 scrcpy-serve.sh。
#       （如果哪天改成非 root 运行，这里需要补 `su -c`。）
#
# 返回：{"ok":true,"a":"start","state":"running","msg":"started pid=12346 port=8886"}

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

BIN=$NASBAK_HOME/bin/scrcpy-serve.sh

# 解析 a=（只认白名单，防止把任意参数透传成命令）
A=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^a=//p' | head -1)
case "$A" in
    start|stop) ;;
    *)          A=status ;;
esac

if [ ! -f "$BIN" ]; then
    printf '{"ok":false,"a":"%s","state":"stopped","msg":"脚本缺失: %s"}\n' "$A" "$BIN"
    exit 0
fi

OUT=$(sh "$BIN" "$A" 2>&1)
RC=$?

# 只取第一行做消息，转义反斜杠与双引号
MSG=$(printf '%s' "$OUT" | head -n1 | sed 's/\\/\\\\/g; s/"/\\"/g')

# 状态判定。注意 "not running" 里含 "running" 子串，必须先排除。
STATE=stopped
case "$A" in
    stop)
        STATE=stopped
        ;;
    *)
        case "$OUT" in
            "not running"*)        STATE=stopped ;;
            *running*|*started*)   STATE=running ;;
            *)                     STATE=stopped ;;
        esac
        ;;
esac

if [ $RC -eq 0 ]; then OK=true; else OK=false; fi

printf '{"ok":%s,"a":"%s","state":"%s","msg":"%s"}\n' "$OK" "$A" "$STATE" "$MSG"
