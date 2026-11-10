#!/system/bin/sh
# 公共库：定位 curl、读 aria2 配置、调 JSON-RPC。
#
# 放在 web 根目录（www）之外，httpd 访问不到，不会被当静态文件读出内容。
# 由 add.cgi / list.cgi 通过 $SELF_DIR/../../lib/aria2.sh 引用。
#
# 加载后可直接使用：
#   $MG_CURL     curl 路径
#   $MG_CONF     aria2 配置文件路径（可能为空）
#   $MG_SECRET   rpc-secret（可能为空，表示没设密钥）
#   $MG_PORT     rpc 端口，默认 6800
#   aria2_rpc <method> <params-json>   自动补 token，输出原始 JSON

MG_CURL=$(command -v curl 2>/dev/null)
[ -z "$MG_CURL" ] && MG_CURL=/system/bin/curl

# 服务端 App 版：路径库把内置 curl / rpc 端口 / secret 全写进了 NASBAK_CONF。
# 配置文件本身就是 shell 赋值，直接 source 即可，不必再找 aria2.conf。
# 注意 App 版的内置 curl 是 libcurl.so（静态 ELF），普通 App 不能直接 exec
# /system/bin/curl 之外的路径，所以这里必须用绝对路径。
if [ -n "$NASBAK_CONF" ] && [ -r "$NASBAK_CONF" ]; then
  . "$NASBAK_CONF"
  [ -n "$NASBAK_CURL" ] && [ -x "$NASBAK_CURL" ] && MG_CURL="$NASBAK_CURL"
  MG_SECRET=${NASBAK_RPC_SECRET:-}
  MG_PORT=${NASBAK_RPC_PORT:-6800}
  MG_CONF="$NASBAK_CONF"
  if [ -n "$NASBAK_CA" ] && [ -r "$NASBAK_CA" ]; then
    CURL_CA_BUNDLE=$NASBAK_CA
    export CURL_CA_BUNDLE
  fi
else

# 找 aria2 配置文件：优先 ARIA2_CONF 环境变量，其次常见路径
MG_CONF=""
for c in "$ARIA2_CONF" \
         /data/adb/srv/aria2.conf \
         /data/adb/aria2/aria2.conf \
         /data/adb/modules/aria2/aria2.conf \
         /sdcard/aria2/aria2.conf \
         "$HOME/.aria2/aria2.conf"; do
  if [ -n "$c" ] && [ -f "$c" ]; then
    MG_CONF="$c"
    break
  fi
done

MG_SECRET=""
MG_PORT="6800"
if [ -n "$MG_CONF" ]; then
  MG_SECRET=$(sed -n 's/^[[:space:]]*rpc-secret[[:space:]]*=[[:space:]]*//p' "$MG_CONF" | tr -d '\r\n')
  _mgp=$(sed -n 's/^[[:space:]]*rpc-listen-port[[:space:]]*=[[:space:]]*//p' "$MG_CONF" | tr -d '\r\n')
  [ -n "$_mgp" ] && MG_PORT="$_mgp"
fi

fi

# aria2_rpc <method> <params-json>
# params 是不含 token 的完整 JSON 数组，例如 '[[\"magnet:?xt=urn:btih:xxx\"]]'
# 配了 rpc-secret 时自动把 "token:xxx" 插到数组最前面——不配密钥时绝不能带，
# 否则 aria2 直接鉴权失败。
aria2_rpc() {
  _m="$1"
  _p="$2"
  case "$_p" in
    \[*) : ;;
    *)   _p='[]' ;;
  esac

  if [ -n "$MG_SECRET" ]; then
    _inner=$(printf '%s' "$_p" | sed 's/^\[//; s/\]$//')
    if [ -z "$_inner" ]; then
      _p="[\"token:${MG_SECRET}\"]"
    else
      _p="[\"token:${MG_SECRET}\",${_inner}]"
    fi
  fi

  printf '%s' "$("$MG_CURL" -s --max-time 8 \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"magpie\",\"method\":\"${_m}\",\"params\":${_p}}" \
    "http://127.0.0.1:${MG_PORT}/jsonrpc" 2>/dev/null)"
}

# is_json_object <string>：是不是一个完整的 {...} 响应
is_json_object() {
  case "$1" in
    \{*\}) return 0 ;;
    *)     return 1 ;;
  esac
}
