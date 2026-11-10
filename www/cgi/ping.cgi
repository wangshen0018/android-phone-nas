#!/system/bin/sh
# 局域网发现探针。
# App 扫描本网段 8083 时，靠这个接口确认「对面是 nasbak，不是别的服务」。
# 只回固定字段，不读账本、不碰文件，保证毫秒级返回；被扫地器反复打也不会拖慢系统。

NAME=""
if [ -x /system/bin/getprop ]; then
  NAME=$(/system/bin/getprop ro.product.model 2>/dev/null)
fi
[ -z "$NAME" ] && NAME="NasBak"
# JSON 里不能出现裸引号和反斜杠
NAME=$(printf '%s' "$NAME" | tr -d '"\\' | cut -c1-40)

# 请求里的 Host 头就是对方访问用的地址，直接回显，App 不用再猜
H=${HTTP_HOST:-}
case "$H" in
  *:*) HOSTIP=${H%%:*} ;;
  *)   HOSTIP=$H ;;
esac

printf 'Content-Type: application/json\r\n'
printf 'Cache-Control: no-store\r\n'
printf 'Access-Control-Allow-Origin: *\r\n'
printf '\r\n'
printf '{"nasbak":1,"name":"%s","ip":"%s","port":8083}\n' "$NAME" "$HOSTIP"
