#!/system/bin/sh
# upload.cgi — 用户端 App 把本机照片/视频推进库房
#
# 参数走 HTTP 头，不用 query：busybox httpd 在 POST 下取不到 QUERY_STRING。
#   X-Pantry-Name   : 文件名，UTF-8 的 base64（HTTP 头不能带中文）
#   X-Pantry-Bucket : 相册/文件夹名，UTF-8 的 base64，可选
#   X-Pantry-Id     : 客户端给的稳定键，ASCII，可选（1.8 起有）
#   X-Pantry-Dev    : 设备型号，ASCII，只写日志
#   X-Pantry-Taken  : 拍摄时间（秒），可选；旧名 X-Pantry-Shot 仍兼容
#   X-Pantry-Shot   : 旧版传的「修改时间」，没有 Taken 时才用
# body 是文件原始字节，不是 multipart。实测 12 MB 单次 POST 可完整落盘。
#
# 落点是 inbox/Pantry/<相册>/，move-by-date.sh 递归扫一层子目录。
# 相册名折成安全 ASCII 目录名 + cksum 后缀，原始名写在子目录的 .album.txt，
# 点开头的文件不会被归位脚本扫走，脱离软件看目录也知道是哪个相册。
#
# 去重（1.8 改）：以 state/upload.idx 里的稳定键为准，不再只看文件还在不在。
# 归位脚本会把文件从 inbox/Pantry/ 搬进 inbox/<日期>/，只看文件会误判为没传过，
# 清一次 App 数据就把整批照片重传一遍。跨相册同名文件也靠这个键区分开。

BASE=/data/media/0/nasbak
DEST=$BASE/inbox/Pantry
LOG=$BASE/state/upload.log
IDX=$BASE/state/upload.idx
MAX=536870912

printf 'Content-Type: application/json; charset=utf-8\r\n\r\n'

fail() { printf '{"ok":false,"err":"%s"}\n' "$1"; exit 0; }
dup()  { printf '{"ok":true,"dup":true,"name":"%s"}\n' "$1"; exit 0; }

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
[ ${#SAFE} -le 120 ] || SAFE=$(printf '%s' "$SAFE" | cut -c1-120)
LOW=$(printf '%s' "$SAFE" | tr 'A-Z' 'a-z')
case "$LOW" in
  *.jpg|*.jpeg|*.png|*.heic|*.gif|*.webp|*.bmp|*.dng|*.mp4|*.mov|*.3gp|*.m4v|*.mkv) ;;
  *) fail "unsupported type" ;;
esac

# ---- 相册：保留中文的安全目录名 + 短校验和 ----
# \200-\377 让 UTF-8 高位字节留下，中文相册名在文件管理器里仍然认得出；
# 空格、斜杠、shell 元字符一律折下划线。某些精简版 tr 不认八进制范围时，
# 最坏结果是中文变下划线，功能不受影响（.album.txt 里仍是原始名）。
# cut 按字节裁 60，超长相册名尾部可能出现半个字符，cksum 后缀保证不会撞名。
BB64=${HTTP_X_PANTRY_BUCKET:-}
BK=$(printf '%s' "$BB64" | base64 -d 2>/dev/null)
[ -n "$BK" ] || BK="未分类"
BKB=$(printf '%s' "$BK" | tr -c 'A-Za-z0-9._\200-\377-' '_' | cut -c1-60)
case "$BKB" in ''|.*) BKB="album" ;; esac
BKH=$(printf '%s' "$BK" | cksum 2>/dev/null | cut -d' ' -f1)
# 极少数系统没把 cksum 放进 PATH，退回 Magisk busybox；再不行就固定 0，
# 目录名前缀仍不同，不会把文件写错地方
[ -n "$BKH" ] || BKH=$(printf '%s' "$BK" | /data/adb/magisk/busybox cksum 2>/dev/null | cut -d' ' -f1)
[ -n "$BKH" ] || BKH="0"
DIR="${BKB}_${BKH}"

# ---- 稳定键：客户端给的最准，旧客户端退回「文件名+大小」 ----
RID=${HTTP_X_PANTRY_ID:-}
case "$RID" in *[!A-Za-z0-9._:-]*) RID="" ;; esac
[ -n "$RID" ] || RID="legacy:$SAFE:$LEN"
[ ${#RID} -le 160 ] || RID=$(printf '%s' "$RID" | cut -c1-160)

mkdir -p "$BASE/state" "$DEST/$DIR" 2>/dev/null || fail "mkdir failed"
# 原始相册名留一份给人看；点开头，归位脚本的 * 通配符扫不到
[ -f "$DEST/$DIR/.album.txt" ] || printf '%s\n' "$BK" > "$DEST/$DIR/.album.txt" 2>/dev/null

# 稳定键已收过，或文件还在没收走，都算重复
grep -Fq "$RID|" "$IDX" 2>/dev/null && dup "$SAFE"
[ -f "$DEST/$DIR/$SAFE" ] && dup "$SAFE"

TMP="$DEST/$DIR/.${SAFE}.part"
head -c "$LEN" > "$TMP" 2>/dev/null || { rm -f "$TMP"; fail "write failed"; }
GOT=$(stat -c %s "$TMP" 2>/dev/null)
[ "$GOT" = "$LEN" ] || { rm -f "$TMP"; fail "short write $GOT/$LEN"; }
mv -f "$TMP" "$DEST/$DIR/$SAFE" 2>/dev/null || { rm -f "$TMP"; fail "rename failed"; }

# 文件 mtime 是 move-by-date.sh 判拍摄日期的兜底，优先用真正的拍摄时间
SHOT=${HTTP_X_PANTRY_TAKEN:-}
[ -n "$SHOT" ] || SHOT=${HTTP_X_PANTRY_SHOT:-}
case "$SHOT" in ''|*[!0-9]*) SHOT="" ;; esac
if [ -n "$SHOT" ]; then
  TS=$(date -u -d "@$SHOT" +%Y%m%d%H%M.%S 2>/dev/null)
  [ -n "$TS" ] && touch -t "$TS" "$DEST/$DIR/$SAFE" 2>/dev/null
fi

DEV=${HTTP_X_PANTRY_DEV:-unknown}
case "$DEV" in *[!A-Za-z0-9._-]*) DEV="unknown" ;; esac
# 日志仍是 4 列，第 4 列改成「相册目录/文件名」，老解析方式不会断
printf '%s %s %s %s\n' "$(date '+%F %T')" "$DEV" "$LEN" "$DIR/$SAFE" >> "$LOG" 2>/dev/null
printf '%s|%s|%s|%s\n' "$RID" "$DIR/$SAFE" "$LEN" "$(date '+%F %T')" >> "$IDX" 2>/dev/null

printf '{"ok":true,"name":"%s","album":"%s"}\n' "$SAFE" "$DIR"
