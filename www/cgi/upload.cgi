#!/system/bin/sh
# upload.cgi — 用户端 App 把本机照片/视频推进库房
#
# 参数走 HTTP 头，不用 query：busybox httpd 在 POST 下取不到 QUERY_STRING。
#   X-Pantry-Name : 文件名，UTF-8 的 base64（HTTP 头不能带中文）
#   X-Pantry-Dev  : 设备型号，ASCII，只写日志
#   X-Pantry-Shot : 拍摄时间（秒），可选，用来把 mtime 还原成拍摄时间
# body 是文件原始字节，不是 multipart。实测 12 MB 单次 POST 可完整落盘。
#
# 落点是 inbox/Pantry/，move-by-date.sh 已把这个目录加进来源列表，
# 后面的归位、判读、归档流程不需要改。

BASE=/data/media/0/nasbak
DEST=$BASE/inbox/Pantry
LOG=$BASE/state/upload.log
MAX=536870912

printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'

fail() { printf '{"ok":false,"err":"%s"}\n' "$1"; exit 0; }

LEN=${CONTENT_LENGTH:-0}
case "$LEN" in ''|*[!0-9]*) fail "bad length" ;; esac
[ "$LEN" -gt 0 ] || fail "empty body"
[ "$LEN" -le "$MAX" ] || fail "too large"

NB=${HTTP_X_PANTRY_NAME:-}
[ -n "$NB" ] || fail "missing name header"
NAME=$(printf '%s' "$NB" | base64 -d 2>/dev/null)
[ -n "$NAME" ] || fail "bad base64"
NAME=$(basename "$NAME")
# 中文名等一并折成下划线，绝不允许路径分隔符和 shell 元字符混进来
SAFE=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '_')
[ -n "$SAFE" ] || fail "empty name"
LOW=$(printf '%s' "$SAFE" | tr 'A-Z' 'a-z')
case "$LOW" in
  *.jpg|*.jpeg|*.png|*.heic|*.gif|*.webp|*.bmp|*.dng|*.mp4|*.mov|*.3gp|*.m4v|*.mkv) ;;
  *) fail "unsupported type" ;;
esac

mkdir -p "$DEST" 2>/dev/null || fail "mkdir failed"

# 同名视为已传过，直接回 dup，不覆盖也不重复吃流量
[ -f "$DEST/$SAFE" ] && {
  printf '{"ok":true,"dup":true,"name":"%s"}\n' "$SAFE"
  exit 0
}

TMP="$DEST/.${SAFE}.part"
head -c "$LEN" > "$TMP" 2>/dev/null || { rm -f "$TMP"; fail "write failed"; }
GOT=$(stat -c %s "$TMP" 2>/dev/null)
[ "$GOT" = "$LEN" ] || { rm -f "$TMP"; fail "short write $GOT/$LEN"; }
mv -f "$TMP" "$DEST/$SAFE" 2>/dev/null || { rm -f "$TMP"; fail "rename failed"; }

# 文件 mtime 是 move-by-date.sh 判拍摄日期的兜底，尽量还原
SHOT=${HTTP_X_PANTRY_SHOT:-}
case "$SHOT" in ''|*[!0-9]*) SHOT="" ;; esac
if [ -n "$SHOT" ]; then
  TS=$(date -u -d "@$SHOT" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$TS" ] && touch -t "$TS" "$DEST/$SAFE" 2>/dev/null
fi

DEV=${HTTP_X_PANTRY_DEV:-unknown}
case "$DEV" in *[!A-Za-z0-9._-]*) DEV="unknown" ;; esac
mkdir -p "$BASE/state" 2>/dev/null
printf '%s %s %s %s\n' "$(date '+%F %T')" "$DEV" "$LEN" "$SAFE" >> "$LOG" 2>/dev/null

printf '{"ok":true,"name":"%s","size":%s}\n' "$SAFE" "$LEN"
