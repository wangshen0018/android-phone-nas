#!/system/bin/sh
# make-vthumb.sh — 给 state/media 里的视频生成预览缩略图
#
# 为什么在服务端做（2026-11-06 结论）：
#   之前让浏览器加载 <video> 抽首帧，K40 的 busybox httpd 是单线程的，
#   一个视频就是 10MB+ 的顺序读，几十个视频排下来直接把 httpd 堵死，
#   连 judge.html 自己都打不开 —— 实测页面彻底卡死，必须导航走才恢复。
#   ffmpeg 抽一帧只要 0.2 秒、输出 15KB，一劳永逸。
#
# 输出：state/thumb/<id>.jpg (最大边 320，q=5)
# 幂等：已存在就跳过，除非带 -f

MEDIA=/data/media/0/nasbak/state/media
THUMB=/data/media/0/nasbak/state/thumb
FF=/data/adb/nasbak/bin/ffmpeg
FORCE=0
[ "$1" = "-f" ] && FORCE=1

mkdir -p "$THUMB" 2>/dev/null
[ -x "$FF" ] || { echo '{"ok":false,"err":"ffmpeg 未安装"}'; exit 1; }

MADE=0; SKIP=0; FAIL=0
for f in "$MEDIA"/*.mp4 "$MEDIA"/*.mov "$MEDIA"/*.3gp "$MEDIA"/*.m4v; do
  [ -f "$f" ] || continue
  b=$(basename "$f"); id=${b%.*}
  out="$THUMB/$id.jpg"
  if [ -f "$out" ] && [ "$FORCE" != "1" ]; then SKIP=$((SKIP+1)); continue; fi
  # -ss 放在 -i 前面是快速定位（关键帧级别），比解码到该时刻快得多。
  # 取 10% 处避开开头的黑场；短视频（<1s）直接用 0。
  DUR=$($FF -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null)
  SS=$(echo "$DUR" | $BB awk '{d=$1+0; s=(d>1)? d*0.1 : 0; if(s>5) s=5; printf "%.2f", s}' 2>/dev/null)
  [ -z "$SS" ] && SS=1
  if $FF -v error -ss "$SS" -i "$f" -frames:v 1 -vf "scale='min(320,iw)':-2" -q:v 5 -y "$out" 2>/dev/null && [ -s "$out" ]; then
    MADE=$((MADE+1))
  else
    # 退一步：从头抽（有些文件的索引在尾部，快速定位失败）
    if $FF -v error -i "$f" -frames:v 1 -vf "scale='min(320,iw)':-2" -q:v 5 -y "$out" 2>/dev/null && [ -s "$out" ]; then
      MADE=$((MADE+1))
    else
      FAIL=$((FAIL+1)); rm -f "$out"
    fi
  fi
done

echo "{\"ok\":true,\"made\":$MADE,\"skipped\":$SKIP,\"failed\":$FAIL,\"total\":$((MADE+SKIP+FAIL))}"
# 富文本行给 daemon 日志用（JSON 那行留给需要解析的调用方）
if [ "$MADE" -gt 0 ] || [ "$FAIL" -gt 0 ]; then
  echo "新生成 $MADE 张 · 已有 $SKIP 张 · 失败 $FAIL 张"
fi
exit 0
