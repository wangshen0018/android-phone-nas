#!/bin/sh
# lib-path.sh — 全部路径的唯一来源
#
# 用法：在每个脚本的 shebang 下一行加
#   . "$(dirname "$0")/lib-path.sh"
#
# 设计要点：本文件直接沿用各脚本原有的短变量名（DATA / ARC / WWW / BB ...），
# 所以脚本正文一行都不用改，只要删掉自己的定义行。
#
# 注意：S=/data/adb/srv 属于服务区（aria2、alist、scrcpy），不归这里管，各脚本保留自己的定义。

# ---------- 读配置 ----------
# 查找顺序：$NASBAK_CONF → 程序目录同级 etc/nasbak.conf → /etc/nasbak.conf
# 注意：$0 在 `sh -c ". lib-path.sh"` 这种用法里是 "sh"，算不出目录，
# 所以除了脚本同级推断，再给两个常见安装位置的兜底。
_nb_self=$(dirname "$0")
for _nb_c in "${NASBAK_CONF:-}" \
             "$_nb_self/../etc/nasbak.conf" \
             "$_nb_self/../../etc/nasbak.conf" \
             "$_nb_self/etc/nasbak.conf" \
             /data/adb/nasbak/etc/nasbak.conf \
             /opt/nasbak/etc/nasbak.conf \
             /etc/nasbak.conf; do
  if [ -n "$_nb_c" ] && [ -r "$_nb_c" ]; then
    . "$_nb_c"
    NASBAK_CONF=$_nb_c
    break
  fi
done

# ---------- 默认值（配置里没写就用这些）----------
: "${NASBAK_ROOT:=/data/media/0/nasbak}"
: "${NASBAK_HOME:=/data/adb/nasbak}"
: "${NASBAK_PORT:=8083}"
: "${NASBAK_ALIST_PORT:=5244}"
# 临时文件和锁目录。/data/local/tmp 普通 App 不可写，服务端 App 版会指到私有目录。
: "${NASBAK_TMP:=/data/local/tmp}"
: "${NASBAK_RPC_PORT:=6800}"
: "${NASBAK_RPC_SECRET:=CHANGE_ME}"
: "${NASBAK_DOWNLOAD:=$NASBAK_ROOT/Downloads}"
: "${NASBAK_CA:=}"

# ---------- 派生路径，沿用原有变量名 ----------
DATA=$NASBAK_ROOT/state
ARC=$NASBAK_ROOT/archive
INBOX=$NASBAK_ROOT/inbox
WWW=$NASBAK_HOME/www
BIN=$NASBAK_HOME/bin
# 日志目录单独可配：服务端 App 版把它指到私有目录，运行时解压不会把它删掉
: "${NASBAK_LOGD:=$NASBAK_HOME/logs}"
LOGD=$NASBAK_LOGD
LEDGER=$DATA/ledger.jsonl
DOWNLOAD=$NASBAK_DOWNLOAD
RPC_PORT=$NASBAK_RPC_PORT
RPC_SECRET=$NASBAK_RPC_SECRET

# ---------- 外部程序 ----------
# BB 用来跑 date/stat/awk/grep/du/sha256sum 这些在 toybox 里也有实现的命令。
# 查找顺序：配置指定 → PATH 里的 busybox → PATH 里的 toybox → /system/bin/toybox。
# 服务端 App 版没有 Magisk，落到 toybox；设备原版仍然用 busybox，行为不变。
BB=${NASBAK_BB:-}
FF=${NASBAK_FFMPEG:-}
if [ -z "$BB" ] || [ ! -x "$BB" ]; then
  BB=$(command -v busybox 2>/dev/null || command -v toybox 2>/dev/null || true)
fi
[ -n "$BB" ] || BB=/system/bin/toybox
# ffmpeg 是可选的：没有就留空，脚本一律用 [ -x "$FF" ] 判断，
# 不能让 FF 变成一个不存在的命令名，否则 $FF 会被当成命令执行。
if [ -z "$FF" ] || [ ! -x "$FF" ]; then
  FF=$(command -v ffmpeg 2>/dev/null || true)
fi
: "${FF:=}"

# curl / aria2 在服务端 App 里是随 APK 分发的静态 ELF（jniLibs 里的 lib*.so）。
# 配置里给了绝对路径就用，没给（Magisk 设备版）就回落到 PATH 上的同名命令。
CURL=${NASBAK_CURL:-}
if [ -z "$CURL" ] || [ ! -x "$CURL" ]; then
  CURL=$(command -v curl 2>/dev/null || true)
fi
[ -n "$CURL" ] || CURL=/system/bin/curl
# CA bundle：Android 的证书是散装目录，App 启动时会拼一份；curl 走 CURL_CA_BUNDLE，
# aria2 走 --ca-certificate。设备版没有这个变量时留空，用系统默认。
if [ -n "$NASBAK_CA" ] && [ -r "$NASBAK_CA" ]; then
  CURL_CA_BUNDLE=$NASBAK_CA
  export CURL_CA_BUNDLE
fi
ARIA2=${NASBAK_ARIA2:-}
if [ -z "$ARIA2" ] || [ ! -x "$ARIA2" ]; then
  ARIA2=$(command -v aria2c 2>/dev/null || true)
fi
: "${ARIA2:=}"

TMPD=$NASBAK_TMP
export NASBAK_CONF NASBAK_ROOT NASBAK_HOME NASBAK_PORT NASBAK_ALIST_PORT NASBAK_LOGD NASBAK_TMP TMPD
export NASBAK_CURL NASBAK_ARIA2 NASBAK_CA NASBAK_RPC_PORT NASBAK_RPC_SECRET NASBAK_DOWNLOAD
export DATA ARC INBOX WWW BIN LOGD LEDGER BB FF CURL ARIA2 DOWNLOAD RPC_PORT RPC_SECRET

# 目录不存在时按需创建，避免各脚本重复 mkdir
[ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null
[ -d "$TMPD" ] || mkdir -p "$TMPD" 2>/dev/null
