#!/system/bin/sh
# CGI: 报告这台库房具备哪些能力，首页据此显示/隐藏菜单。
#
# 服务端 App 版不会执行本文件（Web.java 里 caps.cgi 由 Java 直出自检结果）；
# 这里只服务原来的 Magisk / busybox httpd 部署，保持旧版菜单不缺项。

printf 'Content-Type: application/json\r\n'
printf 'Cache-Control: no-store\r\n'
printf '\r\n'

. "$(dirname "$0")/../../bin/lib-path.sh" 2>/dev/null || true

B64=$(printf '%s' "${RPC_SECRET:-CHANGE_ME}" | base64 2>/dev/null | tr -d '\n' | tr '+/' '-_' | tr -d '=')
[ -n "$B64" ] || B64=azQwc3J2

printf '{"aria2":true,"curl":true,"files":false,"screen":true,"alist":true,"rpcSecretB64":"%s"}' "$B64"
exit 0
