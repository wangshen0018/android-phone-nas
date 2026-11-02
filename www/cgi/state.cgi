#!/system/bin/sh
# state.cgi — 输出当前判定状态（已判 id → action 映射 + 事件列表）
DATA=/data/media/0/nasbak/state
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

touch "$DATA/decisions.jsonl" 2>/dev/null

echo '{"actions":{'
# 同一 id 取最后一条：倒序处理后首次出现的为准（Android 无 tac，用 awk 倒读）
awk '{l[NR]=$0} END{for(i=NR;i>=1;i--) print l[i]}' "$DATA/decisions.jsonl" 2>/dev/null \
| sed -n 's/.*"id":"\([0-9a-f]\{16\}\)","action":"\([a-z]*\)".*/\1 \2/p' \
| awk '{ if(!(seen[$1]++)) print $1"\t"$2 }' \
| awk 'BEGIN{f=1} {if(!f) printf ","; printf "\"%s\":\"%s\"", $1, $2; f=0}'
echo '},"events":['
awk 'BEGIN{f=1} {if(!f) printf ","; printf "%s", $0; f=0}' "$DATA/events.jsonl" 2>/dev/null
echo ']}'
