#!/system/bin/sh
# notify.sh — 备份完成后的微信推送（PushPlus）
#
# 用法：
#   notify.sh --backup N SIZE SECONDS   daemon.sh 每轮归位后调用
#   notify.sh "标题" "正文"              手工推送 / 测试
#
# 配置：/data/adb/nasbak/notify.conf（chmod 600，含 token，不要提交 Git）
#   PUSHPLUS_TOKEN=xxxxxxxx
#   没有 token 时静默退出，不影响备份主流程。
#
# 为什么单独一个文件：daemon.sh 是每 30 分钟一轮的主循环，通知逻辑塞进去
# 会让主流程难读；token 属于敏感信息，单独配置文件方便换渠道。

CONF=/data/adb/nasbak/notify.conf
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

BB=/data/adb/magisk/busybox
STATE=/data/media/0/nasbak/state
BASE=/data/media/0/nasbak
LOGD=/data/adb/nasbak/logs

[ -z "$PUSHPLUS_TOKEN" ] && exit 0

TITLE="$1"; BODY="$2"

if [ "$TITLE" = "--backup" ]; then
  N="${2:-0}"
  SZ="${3:-0}"
  SEC="${4:-0}"
  SRC="${5:-}"        # 来源明细，move-by-date.sh 传来，如「相机 9 · 扫描 2」

  # 体积转成人话
  HU=$($BB awk -v b="$SZ" 'BEGIN{
    if (b >= 1073741824) printf "%.1f GB", b/1073741824;
    else if (b >= 1048576) printf "%.0f MB", b/1048576;
    else if (b >= 1024) printf "%.0f KB", b/1024;
    else printf "%d B", b }' 2>/dev/null)
  [ -z "$HU" ] && HU="0 B"

  # 按来源分类：由 move-by-date.sh 在搬运的当下统计后传进来。
  # 不能在这里回头扫 inbox 各来源目录 —— 通知是在归位之后发的，
  # 那时文件已经搬进日期目录，扫出来永远是 0（2026-11-06 踩到）。

  # 待判定数量
  PEND=0
  [ -f "$STATE/pending.queue" ] && PEND=$(wc -l < "$STATE/pending.queue" 2>/dev/null | tr -d ' ')

  # 磁盘剩余
  DISK=$($BB df -h "$BASE" 2>/dev/null | tail -1 | $BB awk '{print $4}')
  [ -z "$DISK" ] && DISK="未知"

  # 耗时
  if [ "${SEC:-0}" -gt 0 ]; then
    DUR="$($BB awk -v s="$SEC" 'BEGIN{
      if (s >= 3600) printf "%d小时%d分", s/3600, (s%3600)/60;
      else if (s >= 60) printf "%d分%d秒", s/60, s%60;
      else printf "%d秒", s }')"
  else
    DUR=""
  fi

  TITLE="📷 备份完成 · 新增 ${N} 个文件"
  BODY="新增 ${N} 个文件，共 ${HU}"
  [ -n "$SRC" ] && BODY="${BODY}
来源：${SRC}"
  BODY="${BODY}
待判定：${PEND} 个
剩余空间：${DISK}"
  [ -n "$DUR" ] && BODY="${BODY}
耗时：${DUR}"
fi

[ -z "$TITLE" ] && exit 0

# PushPlus 走 POST 表单，避免长文本撞 URL 长度限制。
# 用 --post-data，内容做 URL 编码（只编码必要的空格和换行，中文直接传，
# busybox wget 会原样发，PushPlus 侧按 UTF-8 解析）。
RES=$($BB wget -q -O - --timeout=20 \
  --header="Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
  --post-data="token=${PUSHPLUS_TOKEN}&title=$(printf '%s' "$TITLE" | sed 's/ /%20/g')&content=$(printf '%s' "$BODY" | sed 's/ /%20/g' | sed ':a;N;$!ba;s/\n/%0A/g')&template=txt" \
  "https://www.pushplus.plus/send" 2>/dev/null)

mkdir -p "$LOGD" 2>/dev/null
printf '%s push: %s | %s\n' "$(date '+%F %T')" "$TITLE" "${RES:-无响应}" >> "$LOGD/notify.log" 2>/dev/null
exit 0
