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

# ---------- 派生路径，沿用原有变量名 ----------
DATA=$NASBAK_ROOT/state
ARC=$NASBAK_ROOT/archive
INBOX=$NASBAK_ROOT/inbox
WWW=$NASBAK_HOME/www
BIN=$NASBAK_HOME/bin
LOGD=$NASBAK_HOME/logs
LEDGER=$DATA/ledger.jsonl

# ---------- 外部程序 ----------
BB=${NASBAK_BB:-}
FF=${NASBAK_FFMPEG:-}
if [ -z "$BB" ] || [ ! -x "$BB" ]; then
  BB=$(command -v busybox 2>/dev/null || true)
fi
if [ -z "$FF" ] || [ ! -x "$FF" ]; then
  FF=$(command -v ffmpeg 2>/dev/null || true)
fi
: "${BB:=busybox}"
: "${FF:=ffmpeg}"

export NASBAK_CONF NASBAK_ROOT NASBAK_HOME NASBAK_PORT NASBAK_ALIST_PORT
export DATA ARC INBOX WWW BIN LOGD LEDGER BB FF

# 目录不存在时按需创建，避免各脚本重复 mkdir
[ -d "$DATA" ] || mkdir -p "$DATA" 2>/dev/null
