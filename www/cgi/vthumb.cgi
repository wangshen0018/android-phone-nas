#!/system/bin/sh
# vthumb.cgi — 按需给「归档视频」生成封面帧，然后 302 到静态图
#
# 用法：/cgi/vthumb.cgi?mid=<16位hex>
#   mid 是 archive.cgi 为每个归档文件算的媒体 id（sha256("YM/事件夹/文件名:大小")[:16]），
#   state/media/<mid>.<ext> 是它的硬链接。
#
# 为什么按需生成，不做批量：
#   ffmpeg 抽一帧约 0.2 秒，一个事件夹十几个视频批量做就是三四秒；
#   busybox httpd 是**单线程**的，这几秒里整站都点不动（见 CHANGELOG 2.2）。
#   按需则是一个封面一次 0.2 秒，浏览器并行请求时逐个出图，用户几乎无感。
#
# 为什么必须有服务端封面：
#   让浏览器用 <video preload> 抽首帧会把整个视频文件顺序读一遍（10MB+），
#   单线程 httpd 直接被堵死 —— 这是 2026-11-06 实测踩过的坑。
#
# 输出：state/thumb/<mid>.jpg（长边 320，q=5，约 15KB）
# 幂等：已存在直接 302，不重复解码。

MEDIA=/data/media/0/nasbak/state/media
THUMB=/data/media/0/nasbak/state/thumb
FF=/data/adb/nasbak/bin/ffmpeg

fail() {
  # 同样不能用 Status: 头（httpd 不认）。返回 JSON 而不是图片，
  # <img> 的 onerror 会照常触发，前端能退回占位块。
  printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n{"ok":false,"err":"%s"}\n' "$1"
  exit 0
}

# ---- 取参数 ----
MID=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n 's/^mid=//p' | head -1)
# 只接受 16 位小写 hex：既挡路径穿越，也挡任意文件名注入
case "$MID" in
  ''|*[!0-9a-f]*) fail "bad mid" ;;
esac
[ ${#MID} -eq 16 ] || fail "bad mid"

mkdir -p "$THUMB" 2>/dev/null
OUT="$THUMB/$MID.jpg"

if [ ! -s "$OUT" ]; then
  # 找对应的媒体硬链接（扩展名不定，只认视频）
  SRC=""
  for f in "$MEDIA/$MID".*; do
    [ -f "$f" ] || continue
    case "${f##*.}" in
      mp4|mov|3gp|m4v|mkv|webm|MP4|MOV|3GP) SRC="$f"; break ;;
    esac
  done
  [ -z "$SRC" ] && fail "media not found"
  [ -x "$FF" ] || fail "ffmpeg missing"

  # -ss 放在 -i 前是快速定位（关键帧级），取 10% 处避开开头黑场，最多 5 秒
  DUR=$($FF -v error -show_entries format=duration -of csv=p=0 "$SRC" 2>/dev/null)
  SS=$(printf '%s' "$DUR" | awk '{d=$1+0; s=(d>1)?d*0.1:0; if(s>5) s=5; printf "%.2f", s}')
  [ -z "$SS" ] && SS=1
  $FF -v error -ss "$SS" -i "$SRC" -frames:v 1 -vf "scale='min(320,iw)':-2" -q:v 5 -y "$OUT" 2>/dev/null
  if [ ! -s "$OUT" ]; then
    # 索引在尾部的容器快速定位会失败，从头解一帧兜底
    $FF -v error -i "$SRC" -frames:v 1 -vf "scale='min(320,iw)':-2" -q:v 5 -y "$OUT" 2>/dev/null
  fi
  [ -s "$OUT" ] || { rm -f "$OUT"; fail "decode failed"; }
fi

# 直接吐图片内容，不做 302。
# 原因：这个 busybox httpd 不认 CGI 的 `Status:` 头（实测原样当普通响应头输出，
# 最终仍是 200、body 为空），所以重定向走不通。图只有 15KB 左右，
# 由 CGI 直出没有负担；而且生成过一次后，files 接口的 thumb 就变成 1，
# 前端改走静态 /thumb/ 路径，后续完全不经过 CGI。
SZ=$(stat -c %s "$OUT" 2>/dev/null)
[ -z "$SZ" ] && fail "stat failed"
printf 'Content-Type: image/jpeg\r\n'
printf 'Cache-Control: max-age=86400\r\n'
printf 'Content-Length: %s\r\n\r\n' "$SZ"
cat "$OUT"
