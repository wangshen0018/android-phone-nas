#!/system/bin/sh
# thumb.cgi — 按需生成「缩略图」，图片和视频共用一套
#
# 用法：/cgi/thumb.cgi?mid=<16位hex>
#   mid 是 archive.cgi / judge.sh 为该文件算的媒体 id，
#   实体文件在 state/media/<mid>.<ext>（硬链接，不额外占空间）。
#
# 为什么必须有这一层（2026-11-07 实测）：
#   网格格子只有 112px 宽，但原来 <img> 直接指 /media/<mid>.jpg —— 那是**原图**。
#   一个 34 张的事件 = 158.6 MB，平均 4.7 MB/张，在手机上打开要好几十秒。
#   用 320px 缩略图后单张约 9 KB（缩小 350 倍），整页从 158 MB 降到 300 KB。
#
# 为什么在服务端做：busybox httpd 单线程，让浏览器自己去解大图会把整站拖死
# （2026-11-06 踩过：判定页几十个视频抽首帧，httpd 直接卡死）。
#
# 输出：state/thumb/<mid>.jpg（长边 320，q=5）
# 幂等：已存在直接吐图，不重复解码

MEDIA=/data/media/0/nasbak/state/media
THUMB=/data/media/0/nasbak/state/thumb
FF=/data/adb/nasbak/bin/ffmpeg
MAXPX=320
Q=5

fail() {
  # 不能用 Status: 头（httpd 不认，见 CHANGELOG 2.15），返回非图片内容让 <img> onerror 兜住
  printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n{"ok":false,"err":"%s"}\n' "$1"
  exit 0
}

MID=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^mid=//p' | head -1)
# 只认 16 位小写 hex：挡路径穿越，也挡任意文件名注入
case "$MID" in ''|*[!0-9a-f]*) fail "bad mid" ;; esac
[ ${#MID} -eq 16 ] || fail "bad mid"

mkdir -p "$THUMB" 2>/dev/null
OUT="$THUMB/$MID.jpg"

if [ ! -s "$OUT" ]; then
  [ -x "$FF" ] || fail "ffmpeg missing"
  SRC=""; KIND=""
  for f in "$MEDIA/$MID".*; do
    [ -f "$f" ] || continue
    case "${f##*.}" in
      jpg|jpeg|png|webp|gif|bmp|heic|JPG|JPEG|PNG|WEBP) SRC="$f"; KIND="img"; break ;;
    esac
  done
  if [ -z "$SRC" ]; then
    for f in "$MEDIA/$MID".*; do
      [ -f "$f" ] || continue
      case "${f##*.}" in
        mp4|mov|3gp|m4v|mkv|webm|MP4|MOV|3GP) SRC="$f"; KIND="vid"; break ;;
      esac
    done
  fi
  [ -z "$SRC" ] && fail "media not found"

  if [ "$KIND" = "img" ]; then
    # 静态图一次解码即可。加 -frames:v 1 防止 gif 抽出多帧。
    $FF -v error -i "$SRC" -frames:v 1 -vf "scale='min($MAXPX,iw)':-2" -q:v $Q -y "$OUT" 2>/dev/null
  else
    # 视频：-ss 放在 -i 前是快速定位（关键帧级），取 10% 处避开开头黑场，最多 5 秒
    DUR=$($FF -v error -show_entries format=duration -of csv=p=0 "$SRC" 2>/dev/null)
    SS=$(printf '%s' "$DUR" | awk '{d=$1+0; s=(d>1)?d*0.1:0; if(s>5) s=5; printf "%.2f", s}')
    [ -z "$SS" ] && SS=1
    $FF -v error -ss "$SS" -i "$SRC" -frames:v 1 -vf "scale='min($MAXPX,iw)':-2" -q:v $Q -y "$OUT" 2>/dev/null
    if [ ! -s "$OUT" ]; then
      # 索引在尾部的容器快速定位会失败，从头解一帧兜底
      $FF -v error -i "$SRC" -frames:v 1 -vf "scale='min($MAXPX,iw)':-2" -q:v $Q -y "$OUT" 2>/dev/null
    fi
  fi
  [ -s "$OUT" ] || { rm -f "$OUT"; fail "decode failed"; }
fi

SZ=$(stat -c %s "$OUT" 2>/dev/null)
[ -z "$SZ" ] && fail "stat failed"
# 直接吐内容，不做 302（httpd 不认 Status 头）
printf 'Content-Type: image/jpeg\r\n'
printf 'Cache-Control: max-age=604800\r\n'
printf 'Content-Length: %s\r\n\r\n' "$SZ"
cat "$OUT"
