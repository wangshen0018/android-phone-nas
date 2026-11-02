#!/system/bin/sh
# status.cgi — 只读状态缓存，不做任何重活
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
CACHE=/data/media/0/nasbak/state/status-cache.json

if [ ! -f "$CACHE" ]; then
  echo '{"ok":false,"err":"暂无状态缓存，请等待采集脚本运行","services":[],"files":{},"judge":{},"cats":{},"models":{},"disk":{},"ledger":{},"events":0}'
  exit 0
fi

AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))

# 缓存格式: {"ts":...,"services":[...],"files":{...},...}
# 直接返回缓存内容，把 ts 替换成 ageSec
BODY=$(tr -d '\r\n' < "$CACHE" 2>/dev/null)
# 去掉开头的 {"ts":数字,  得到剩余部分
REST=$(printf '%s' "$BODY" | sed 's/^{"ts":[0-9]*,//')
printf '{"ok":true,"ageSec":%s,' "$AGE"
printf '%s\n' "$REST"