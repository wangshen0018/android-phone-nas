#!/system/bin/sh
# make-thumb.sh — 给 state/media 里的图片和视频批量生成缩略图
#
# 背景（2026-11-07 实测）：
#   存档页/判定页的网格原来是 <img src="/media/<id>.jpg">，直接拉**原图**。
#   一个 34 张的事件 = 158.6 MB（平均 4.7 MB/张），格子却只有 112px 宽 ——
#   手机上打开要几十秒。生成 320px 缩略图后单张约 9 KB，整页降到几百 KB。
#
# 输出：state/thumb/<id>.jpg（长边 320，q=5）
#   · 图片：直接缩放，一帧
#   · 视频：抽 10% 处一帧（避开开头黑场，最多 5 秒），失败退回第 0 帧
# 幂等：已有就跳过，带 -f 强制重做
#
# 为什么不交给浏览器：busybox httpd 单线程，浏览器自己解大图会把整站拖死
#（2026-11-06 判定页几十个视频原地抽帧，httpd 直接卡死，必须导航走才恢复）。
#
# 手动用法：
#   sh make-thumb.sh          补齐缺失的（daemon 每轮也调这个）
#   sh make-thumb.sh -f       全部重做
#   sh make-thumb.sh --dry    只统计缺多少，不生成

MEDIA=/data/media/0/nasbak/state/media
THUMB=/data/media/0/nasbak/state/thumb
FF=/data/adb/nasbak/bin/ffmpeg
MAXPX=320
Q=5

FORCE=0; DRY=0
for a in "$@"; do
  case "$a" in
    -f|--force) FORCE=1 ;;
    --dry)      DRY=1 ;;
  esac
done

mkdir -p "$THUMB" 2>/dev/null
[ -x "$FF" ] || { echo '{"ok":false,"err":"ffmpeg 未安装"}'; exit 1; }

# 同一时间只允许一个实例（一次性预热和 daemon 轮次可能撞上）
LOCK=/data/local/tmp/nasbak.make-thumb.lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo '{"ok":true,"skipped":"locked"}'
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

MADE=0; SKIP=0; FAIL=0; NEED=0
for f in "$MEDIA"/*; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  id=${b%.*}
  ext=$(printf '%s' "${b##*.}" | tr 'A-Z' 'a-z')
  case "$ext" in
    jpg|jpeg|png|webp|gif|bmp|heic) KIND=img ;;
    mp4|mov|3gp|m4v|mkv|webm)       KIND=vid ;;
    *) continue ;;
  esac

  out="$THUMB/$id.jpg"
  if [ -f "$out" ] && [ "$FORCE" != "1" ]; then SKIP=$((SKIP+1)); continue; fi
  NEED=$((NEED+1))
  [ "$DRY" = "1" ] && continue

  if [ "$KIND" = "img" ]; then
    $FF -v error -i "$f" -frames:v 1 -vf "scale='min($MAXPX,iw)':-2" -q:v $Q -y "$out" 2>/dev/null
  else
    DUR=$($FF -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null)
    SS=$(printf '%s' "$DUR" | awk '{d=$1+0; s=(d>1)?d*0.1:0; if(s>5) s=5; printf "%.2f", s}')
    [ -z "$SS" ] && SS=1
    $FF -v error -ss "$SS" -i "$f" -frames:v 1 -vf "scale='min($MAXPX,iw)':-2" -q:v $Q -y "$out" 2>/dev/null
    [ -s "$out" ] || $FF -v error -i "$f" -frames:v 1 -vf "scale='min($MAXPX,iw)':-2" -q:v $Q -y "$out" 2>/dev/null
  fi

  if [ -s "$out" ]; then
    MADE=$((MADE+1))
  else
    rm -f "$out"; FAIL=$((FAIL+1))
  fi
done

if [ "$DRY" = "1" ]; then
  echo "{\"ok\":true,\"dry\":true,\"need\":$NEED,\"have\":$SKIP}"
else
  echo "{\"ok\":true,\"made\":$MADE,\"skipped\":$SKIP,\"failed\":$FAIL,\"total\":$((MADE+SKIP+FAIL))}"
fi
