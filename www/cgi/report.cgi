#!/system/bin/sh
# 诊断结果上报：接收 diag.html POST 的 JSON，追加写入 jsonl
OUT=/data/local/tmp/diag-report.jsonl
printf 'Content-Type: application/json\r\n'
printf 'Access-Control-Allow-Origin: *\r\n'
printf '\r\n'

TS=$(date +%s)
UA=$(printf '%s' "$HTTP_USER_AGENT" | tr -d '"' | cut -c1-160)

BODY=$(cat)

{
  printf '{"ts":%s,"ua":"%s","data":' "$TS" "$UA"
  printf '%s' "$BODY"
  printf '}\n'
} >> "$OUT" 2>/dev/null

printf '{"ok":true}'
