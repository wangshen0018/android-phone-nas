#!/system/bin/sh
. "$(dirname "$0")/../../bin/lib-path.sh"
# wizard.cgi — 首次使用向导后端
#
# GET   op=state     当前是否已初始化（老设备自动补配置，升级无感）
# GET   op=volumes   可写卷列表（内部存储 / 外置卡 / U 盘）+ 容量 + 是否已有库房
# GET   op=net       局域网 IP、组网 IP、组网软件是否已装
# POST  op=save      建目录骨架 + 写配置
# POST  op=verify    校验管理员 PIN
#
# 配置位置固定为机器级 $NASBAK_ROOT/state/config.json，
# 库房根路径写在配置里（root）。外置卡迁移需同时改 bin/ 脚本的 DATA，属 P3 后续。

STATE=$NASBAK_ROOT/state
CFG=$STATE/config.json
DEFROOT=$NASBAK_ROOT

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
mkdir -p "$STATE" 2>/dev/null

Q=${QUERY_STRING:-}
OP=$(printf '%s' "$Q" | sed -n 's/.*op=\([a-z-]*\).*/\1/p')
BODY=""

# busybox httpd 在 POST 下不填 QUERY_STRING，参数只能从 body 读
if [ "$REQUEST_METHOD" = "POST" ]; then
  LEN=${CONTENT_LENGTH:-0}
  case "$LEN" in ''|*[!0-9]*) LEN=0 ;; esac
  [ "$LEN" -gt 8192 ] && { echo '{"ok":false,"err":"body too large"}'; exit 0; }
  BODY=$(head -c "$LEN" 2>/dev/null)
  OP=$(printf '%s' "$BODY" | tr -d '\r\n' | sed -n 's/.*op=\([a-z-]*\).*/\1/p')
fi

pval() {
  printf '%s' "$BODY" | tr -d '\r' | tr '&' '\n' | sed -n 's/^'"$1"'=//p' | head -1
}

cfg_root() {
  sed -n 's/.*"root":"\([^"]*\)".*/\1/p' "$CFG" 2>/dev/null | head -1
}

# 写配置。PIN 用固定盐做 md5，够用于「防止手滑」，不承担远程攻击防护。
write_cfg() {
  _root=$1
  _pin=$2
  _tsip=$3
  _pmd5=""
  _pset=false
  _role=owner
  if [ -n "$_pin" ]; then
    _pmd5=$(printf 'nasbak:%s' "$_pin" | md5sum 2>/dev/null | cut -d' ' -f1)
    [ -n "$_pmd5" ] && _pset=true && _role=viewer
  fi
  _vol=$_root
  case "$_vol" in */nasbak) _vol=${_vol%/nasbak} ;; esac
  _ts=$(date +%s)
  printf '{"ver":1,"inited":true,"root":"%s","vol":"%s","pinmd5":"%s","pinSet":%s,"defaultRole":"%s","tsip":"%s","createdAt":%s}\n' \
    "$_root" "$_vol" "$_pmd5" "$_pset" "$_role" "$_tsip" "$_ts" > "$CFG"
}

addvol() {
  _v=$1; _n=$2
  [ -d "$_v" ] || return 0
  [ -w "$_v" ] || return 0
  _s=$(df -k "$_v" 2>/dev/null | awk 'END{print $2" "$4}')
  _tot=$(printf '%s' "$_s" | awk '{print $1}')
  _av=$(printf '%s' "$_s" | awk '{print $2}')
  case "$_tot" in ''|*[!0-9]*) _tot=0 ;; esac
  case "$_av"  in ''|*[!0-9]*) _av=0  ;; esac
  _has=0
  [ -d "$_v/nasbak/archive" ] && _has=1
  _cur=0
  [ "$_v/nasbak" = "$CURROOT" ] && _cur=1
  [ $VF -eq 1 ] || printf ','
  printf '{"path":"%s","name":"%s","totalKB":%s,"availKB":%s,"hasLib":%s,"cur":%s}' \
    "$_v" "$_n" "$_tot" "$_av" "$_has" "$_cur"
  VF=0
}

case "$OP" in

volumes)
  CURROOT=$(cfg_root)
  [ -z "$CURROOT" ] && CURROOT=$DEFROOT
  VF=1
  printf '{"ok":true,"vols":['
  addvol /data/media/0 "内部存储"
  for v in /storage/*; do
    case "$v" in /storage/emulated|/storage/self) continue ;; esac
    [ -d "$v" ] || continue
    addvol "$v" "外置存储"
  done
  printf '],"defRoot":"%s"}\n' "$DEFROOT"
  ;;

net)
  LAN=$(ip -4 addr show wlan0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
  if [ -z "$LAN" ]; then
    LAN=$(ip -4 addr 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | grep -v '^127\.' | head -1)
  fi
  TSIP=""
  TSI=0
  # 组网地址按网卡上的 100.64/10 段判断（Tailscale 固定用这个段）。
  # 不依赖 tailscale 命令：CGI 的 PATH 极简，command -v 基本找不到。
  TSIP=$(ip -4 addr 2>/dev/null | sed -n 's/.*inet \(100\.[0-9]*\.[0-9]*\.[0-9]*\)\/.*/\1/p' | head -1)
  if [ -n "$TSIP" ]; then
    TSI=1
  else
    if command -v tailscale >/dev/null 2>&1; then TSI=1; fi
    [ -d /data/data/com.tailscale.ipn ] && TSI=1
  fi
  printf '{"ok":true,"lan":"%s","ts":"%s","tsInstalled":%s,"port":8083}\n' \
    "$LAN" "$TSIP" "$TSI"
  ;;

state)
  if [ -f "$CFG" ]; then
    printf '{"ok":true,"inited":true,"legacy":false,"cfg":'
    tr -d '\r\n' < "$CFG" 2>/dev/null
    printf '}\n'
  elif [ -d "$DEFROOT/archive" ] || [ -d "$DEFROOT/inbox" ]; then
    # 老设备升级：已有库房但没有配置，直接补一份，避免升级后被向导拦在门外
    write_cfg "$DEFROOT" "" ""
    printf '{"ok":true,"inited":true,"legacy":true,"cfg":'
    tr -d '\r\n' < "$CFG" 2>/dev/null
    printf '}\n'
  else
    echo '{"ok":true,"inited":false,"cfg":{"root":"'$DEFROOT'"}}'
  fi
  ;;

save)
  ROOT=$(pval root)
  PIN=$(pval pin)
  TSIP=$(pval ts)
  case "$TSIP" in *[!0-9.]*) TSIP="" ;; esac
  case "$ROOT" in
    $NASBAK_ROOT|/storage/*|/data/media/0/*) ;;
    *) echo '{"ok":false,"err":"库房路径不合法"}'; exit 0 ;;
  esac
  case "$ROOT" in *..*) echo '{"ok":false,"err":"库房路径不合法"}'; exit 0 ;; esac
  case "$PIN" in
    '') ;;
    *[!0-9]*) echo '{"ok":false,"err":"PIN 只能是数字"}'; exit 0 ;;
  esac
  PL=${#PIN}
  if [ -n "$PIN" ] && { [ "$PL" -lt 4 ] || [ "$PL" -gt 6 ]; }; then
    echo '{"ok":false,"err":"PIN 需 4-6 位数字"}'; exit 0
  fi
  mkdir -p "$ROOT/inbox" "$ROOT/archive" "$ROOT/state" 2>/dev/null
  [ -d "$ROOT/state" ] || { echo '{"ok":false,"err":"目录建不了，检查卡片是否只读"}'; exit 0; }
  write_cfg "$ROOT" "$PIN" "$TSIP"
  [ -f "$CFG" ] || { echo '{"ok":false,"err":"配置写入失败"}'; exit 0; }
  if [ -n "$PIN" ]; then PS=true; else PS=false; fi
  printf '{"ok":true,"root":"%s","pinSet":%s}\n' "$ROOT" "$PS"
  ;;

verify)
  PIN=$(pval pin)
  STORED=$(sed -n 's/.*"pinmd5":"\([^"]*\)".*/\1/p' "$CFG" 2>/dev/null | head -1)
  if [ -z "$STORED" ]; then
    echo '{"ok":true,"nopin":true}'; exit 0
  fi
  GOT=$(printf 'nasbak:%s' "$PIN" | md5sum 2>/dev/null | cut -d' ' -f1)
  if [ "$GOT" = "$STORED" ]; then
    echo '{"ok":true}'
  else
    echo '{"ok":false,"err":"PIN 不对"}'
  fi
  ;;

*)
  echo '{"ok":false,"err":"unknown op"}'
  ;;
esac
