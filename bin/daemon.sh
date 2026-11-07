#!/system/bin/sh
# daemon.sh — 常驻调度：每 30 分钟归位 + 登记新文件，归位成功后只判这一批
#
# 单实例：靠 pid 文件 + kill -0 双重校验，重复启动直接退出
#
# 2026-11-02 改动：
#   · 原 INGEST_ROOT="$BASE/inbox/$(date +%F)" 在「固定来源目录」新架构下失效
#     （inbox 里已没有按备份日期建的目录），改为每次先跑 move-by-date.sh --apply
#     把 inbox/{Camera,CamScanner,...} 里的新文件按拍摄日期归位，再全量 ingest
#   · ingest 范围从「当天日期目录」改为整个 inbox（幂等，已登记的 id 不重复计）
#
# 2026-11-03 改动（判读时机）：
#   · 原方案「白天只登记、夜里 02:30 集中全量判读」有两个毛病：
#       1) 白天新照片在判定页一直是「待判」，最长要等十几个小时才出结果；
#       2) 凌晨那轮要过整个队列，一旦积压多就长时间占着 VLM，且失败件只能等第二天。
#   · 现在改为「归位即判」：本轮确实归位了新文件（moved>0）或队列确实变长了，
#     才立刻跑一次判读；pending.queue 里只有未判过的 id，所以判的就是这一小批。
#   · 夜间全量判读整块删除，判读不再是独立定时任务，而是归位的后续动作。
#   · 失败件仍留队（judge.sh 的原有行为），下一批归位时会顺带重判。

BASE=/data/media/0/nasbak
BIN=/data/adb/nasbak/bin
LOGD=/data/adb/nasbak/logs
PIDF=/data/adb/nasbak/daemon.pid
LOG=$LOGD/daemon.log
QUEUE=$BASE/state/pending.queue

mkdir -p "$LOGD" 2>/dev/null
touch "$LOG" 2>/dev/null

if [ -f "$PIDF" ]; then
  OLD=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    echo "$(date '+%F %T') 已有实例 pid=$OLD，退出" >> "$LOG"
    exit 0
  fi
fi
echo $$ > "$PIDF"
echo "$(date '+%F %T') 启动 pid=$$" >> "$LOG"

LAST_INGEST=0

qlen() {
  if [ -f "$QUEUE" ]; then
    wc -l < "$QUEUE" 2>/dev/null | tr -d ' '
  else
    echo 0
  fi
}

while true; do
  NOW=$(date +%s)

  if [ $((NOW - LAST_INGEST)) -ge 1800 ]; then
    # 1) 归位：inbox/{Camera,CamScanner,scanner,family-kid,id-card} -> inbox/<拍摄日期>/
    #    脚本最后一行是统计行 "moved=N dup=N fail=N skip=N"，据此判断本轮有没有新文件
    OUT=$(sh "$BIN/move-by-date.sh" --apply 2>&1)
    printf '%s\n' "$OUT" >> "$LOG"
    MOVED=$(printf '%s\n' "$OUT" | tail -1 | sed -n 's/.*moved=\([0-9]\{1,\}\).*/\1/p')
    [ -z "$MOVED" ] && MOVED=0
    # 来源明细：move-by-date.sh 最后一行形如
    #   moved=9 dup=0 fail=0 skip=0 src=相机 7 · 扫描 2
    SRCTXT=$(printf '%s\n' "$OUT" | tail -1 | sed -n 's/.*src=//p')

    # 2) 登记（幂等，不调模型）
    Q0=$(qlen)
    sh "$BIN/judge.sh" --ingest >> "$LOG" 2>&1
    Q1=$(qlen)

    # 3) 只有真的来了新文件才判读：判读只读队列，队列里就是这批新的
    if [ "$MOVED" -gt 0 ] || [ "$Q1" -gt "$Q0" ]; then
      echo "$(date '+%F %T') 归位 $MOVED 个，队列 $Q0->$Q1，开始判读" >> "$LOG"

      # 记下这批新件的总体积与耗时，推送给用户看（2026-11-06 新增）
      # 体积：直接从本轮归位日志里拿不到大小，改用 du 对比前后太慢，
      # 改为统计新登记文件的 size —— judge.sh --ingest 会把新 id 写进 analysis.jsonl，
      # 这里按本轮新增条数取最后 N 行的 size 求和。
      NEWN=$((Q1 - Q0))
      [ "$MOVED" -gt "$NEWN" ] && NEWN=$MOVED
      T0=$NOW

      sh "$BIN/judge.sh" --judge >> "$LOG" 2>&1

      T1=$(date +%s)
      SEC=$((T1 - T0))

      # 补缩略图：make-thumb.sh 幂等（已有就跳过），每轮跑一次只处理新文件。
      # 图片和视频都要做 —— 页面网格原来直接拉原图（平均 4.7 MB/张），
      # 一个 34 张的事件就是 158 MB；有了 320px 缩略图后整页降到几百 KB。
      # 2026-11-07 把 make-vthumb.sh 合并进来，不再只处理视频。
      if [ -x "$BIN/make-thumb.sh" ]; then
        VT=$(sh "$BIN/make-thumb.sh" 2>&1 | tail -1)
        echo "$(date '+%F %T') 缩略图: $VT" >> "$LOG"
      fi

      # 推送：只有真的新增了文件才推，避免每 30 分钟骚扰
      if [ "$NEWN" -gt 0 ] && [ -x "$BIN/notify.sh" ]; then
        # 体积：本轮新登记的 id 从 pending.queue 拿不到（已被判读消费），
        # 改用 analysis.jsonl 末尾 NEWN 条的 size 之和 —— 判读刚写入，位置在前。
        SZ=$(tail -n "$NEWN" "$BASE/state/analysis.jsonl" 2>/dev/null \
             | sed -n 's/.*"size":\([0-9]*\).*/\1/p' \
             | awk '{s+=$1} END{print s+0}')
        [ -z "$SZ" ] && SZ=0
        sh "$BIN/notify.sh" --backup "$NEWN" "$SZ" "$SEC" "$SRCTXT" >> "$LOG" 2>&1
      fi
    else
      echo "$(date '+%F %T') 无新文件（moved=0，队列 $Q1），跳过判读" >> "$LOG"
    fi

    LAST_INGEST=$NOW
  fi

  sleep 60
done
