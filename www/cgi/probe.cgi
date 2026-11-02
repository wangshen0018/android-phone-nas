#!/system/bin/sh
# probe.cgi — 探测视频编码，供页面决定"能否就地播放"
# 用法: /cgi/probe.cgi?id=<16位hex>&ext=mp4
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
MEDIA=/data/adb/nasbak/www/media

Q=${QUERY_STRING:-}
ID=$(printf '%s' "$Q" | sed -n 's/.*id=\([0-9a-f]\{16\}\).*/\1/p')
EXT=$(printf '%s' "$Q" | sed -n 's/.*ext=\([a-zA-Z0-9]*\).*/\1/p' | tr 'A-Z' 'a-z')
case "$EXT" in mp4|mov|3gp|m4v) ;; *) EXT=mp4 ;; esac

F="$MEDIA/$ID.$EXT"
if [ -z "$ID" ] || [ ! -f "$F" ]; then
  echo '{"ok":false,"err":"not found"}'; exit 0
fi

SZ=$(stat -c %s "$F" 2>/dev/null)
# moov 既可能在文件头也可能在文件尾，头 64KB + 尾 3MB 一起扫
# （尾 3MB 是因为部分机型的 moov 离文件末尾有 1MB 以上的距离）
TAGS=$( { head -c 65536 "$F"; tail -c 3145728 "$F"; } 2>/dev/null | grep -aoE 'hvc1|hev1|avc1|av01|vp09' | head -5 )

CODEC="unknown"
case "$TAGS" in
  *hvc1*|*hev1*) CODEC="hevc" ;;
  *avc1*)        CODEC="avc"  ;;
  *av01*)        CODEC="av1"  ;;
  *vp09*)        CODEC="vp9"  ;;
esac

printf '{"ok":true,"codec":"%s","size":%s}\n' "$CODEC" "${SZ:-0}"
