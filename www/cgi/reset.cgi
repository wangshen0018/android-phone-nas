#!/system/bin/sh
# reset.cgi — 正式环境版：只清判定与回执，让当天可以重判
#
# 与测试沙箱版的关键区别：
#   绝不删除 inbox / archive / events —— 那些是真实资产。
#   重判只影响「待办列表」的判断状态，磁盘上的文件不动。
DATA=/data/media/0/nasbak/state
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

if [ "$REQUEST_METHOD" != "POST" ]; then echo '{"ok":false,"err":"POST only"}'; exit 0; fi

D1=$(wc -l < "$DATA/decisions.jsonl" 2>/dev/null | tr -d ' ')
R1=$(wc -l < "$DATA/receipts.jsonl" 2>/dev/null | tr -d ' ')

: > "$DATA/decisions.jsonl"
: > "$DATA/receipts.jsonl"

printf '{"ok":true,"cleared_decisions":%s,"cleared_receipts":%s,"note":"仅清判定，文件与事件未动"}\n' \
  "${D1:-0}" "${R1:-0}"
