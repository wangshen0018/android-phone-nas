#!/system/bin/sh
. "$(dirname "$0")/lib-path.sh"
# vlm_classify.sh v9 - ModelBest 主力(MiniCPM-V-4.7-35B-A3B) + 智谱兜底
#
# 供应商优先级:
#   1. ModelBest MiniCPM-V-4.7-35B-A3B  (最优质量, 实测无限流, ~1s)
#   2. ModelBest MiniCPM-V-4.7-1B       (轻量兜底)
#   3. 智谱 glm-4.6v-flash              (最后兜底, 约33%成功率)
KEY_MB=/data/adb/srv/data/modelbest.key
KEY_ZP=/data/adb/srv/data/zhipu.key
API_MB=https://api.modelbest.cn/v1/chat/completions
API_ZP=https://open.bigmodel.cn/api/paas/v4/chat/completions
MAXSZ=12582912

F="$1"
[ -f "$F" ] || { echo "other|文件不存在"; exit 1; }
SZ=$(stat -c %s "$F")
[ "$SZ" -gt "$MAXSZ" ] && { echo "other|过大跳过"; exit 1; }
KMB=$(cat "$KEY_MB" 2>/dev/null)
KZP=$(cat "$KEY_ZP" 2>/dev/null)
[ -z "$KMB" ] && [ -z "$KZP" ] && { echo "other|无可用Key"; exit 1; }

B64F=$NASBAK_TMP/_v9.b64
REQF=$NASBAK_TMP/_v9.json
base64 -w0 "$F" > "$B64F" 2>/dev/null || { echo "other|b64失败"; exit 1; }

# ---------- ModelBest 调用 ----------
mb_call() {
  M="$1"; P="$2"; MT="$3"
  {
    printf '{"model":"%s","max_tokens":%s,"temperature":0,"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,' "$M" "$MT"
    cat "$B64F"
    printf '"}},{"type":"text","text":"%s"}]}]}' "$P"
  } > "$REQF"
  curl -s -m 45 -X POST "$API_MB" -H "Authorization: Bearer $KMB" \
    -H "Content-Type: application/json" --data-binary @"$REQF" 2>/dev/null
}

# ---------- 智谱调用 ----------
zp_call() {
  P="$1"; MT="$2"
  {
    printf '{"model":"glm-4.6v-flash","thinking":{"type":"disabled"},"max_tokens":%s,"temperature":0,"messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"' "$MT"
    cat "$B64F"
    printf '"}},{"type":"text","text":"%s"}]}]}' "$P"
  } > "$REQF"
  curl -s -m 45 -X POST "$API_ZP" -H "Authorization: Bearer $KZP" \
    -H "Content-Type: application/json" --data-binary @"$REQF" 2>/dev/null
}

get_c() { echo "$1" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -1; }

# ============ 类别判定 ============
PROMPT_CAT="判断这张照片属于哪一类。只输出一个大写字母，不要任何其他内容: A=工地施工 B=家庭生活 C=手机截图 D=其他"
CAT_L=""

# 1) ModelBest 4.7-35B
if [ -n "$KMB" ]; then
  R=$(mb_call "MiniCPM-V-4.7-35B-A3B" "$PROMPT_CAT" 5)
  C=$(get_c "$R"); [ -n "$C" ] && CAT_L=$(echo "$C" | tr -d ' \r\n\t' | cut -c1 | tr 'a-z' 'A-Z')
fi
# 2) ModelBest 4.7-1B
if [ -z "$CAT_L" ] && [ -n "$KMB" ]; then
  R=$(mb_call "MiniCPM-V-4.7-1B" "$PROMPT_CAT" 5)
  C=$(get_c "$R"); [ -n "$C" ] && CAT_L=$(echo "$C" | tr -d ' \r\n\t' | cut -c1 | tr 'a-z' 'A-Z')
fi
# 3) 智谱(重试2次)
if [ -z "$CAT_L" ] && [ -n "$KZP" ]; then
  for i in 1 2; do
    R=$(zp_call "$PROMPT_CAT" 5)
    C=$(get_c "$R"); if [ -n "$C" ]; then CAT_L=$(echo "$C" | tr -d ' \r\n\t' | cut -c1 | tr 'a-z' 'A-Z'); break; fi
    sleep 2
  done
fi

# ============ 描述 ============
PROMPT_DESC="用15字以内中文描述这张照片的画面内容。只输出描述本身。"
DESC=""
if [ -n "$KMB" ]; then
  R=$(mb_call "MiniCPM-V-4.7-35B-A3B" "$PROMPT_DESC" 40)
  DESC=$(get_c "$R")
fi
if [ -z "$DESC" ] && [ -n "$KMB" ]; then
  R=$(mb_call "MiniCPM-V-4.7-1B" "$PROMPT_DESC" 40)
  DESC=$(get_c "$R")
fi
if [ -z "$DESC" ] && [ -n "$KZP" ]; then
  R=$(zp_call "$PROMPT_DESC" 40)
  DESC=$(get_c "$R")
fi

rm -f "$B64F" "$REQF"
[ -z "$CAT_L" ] && { echo "other|类别识别失败"; exit 1; }

CAT="other"
case "$CAT_L" in
  A) CAT="work" ;;
  B) CAT="home" ;;
  C) CAT="screenshot" ;;
  D) CAT="other" ;;
esac

DESC=$(echo "$DESC" | sed 's/.*<\/think>//; s/<[^>]*>//g' | tr '\n\r' '  ' | tr -s ' ' | cut -c1-40)
[ -z "$DESC" ] && DESC="(无描述)"

echo "$CAT|$DESC"
exit 0
