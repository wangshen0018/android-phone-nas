#!/system/bin/sh
# daemon.sh — 常驻调度：每 30 分钟归位+登记新文件，每天凌晨 02:30 全量判读
#
# 单实例：靠 pid 文件 + kill -0 双重校验，重复启动直接退出
#
# 2026-11-02 改动：
#   · 原 INGEST_ROOT="$BASE/inbox/$(date +%F)" 在「固定来源目录」新架构下失效
#     （inbox 里已没有按备份日期建的目录），改为每次先跑 move-by-date.sh --apply
#     把 inbox/{Camera,CamScanner,...} 里的新文件按拍摄日期归位，再全量 ingest
#   · ingest 范围从「当天日期目录」改为整个 inbox（幂等，已登记的 id 不重复计）

BASE=/data/media/0/nasbak
BIN=/data/adb/nasbak/bin
LOGD=/data/adb/nasbak/logs
PIDF=/data/adb/nasbak/daemon.pid
LOG=$LOGD/daemon.log

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

JUDGE_HH=2     # 判读时点：02:30
JUDGE_MM=30

LAST_JUDGE=""
LAST_INGEST=0

while true; do
  NOW=$(date +%s)

  # 每 30 分钟：先把新上传的文件按拍摄日期归位，再登记（轻量，不调模型）
  if [ $((NOW - LAST_INGEST)) -ge 1800 ]; then
    # 1) 归位：inbox/{Camera,CamScanner,scanner,family-kid,id-card} -> inbox/<拍摄日期>/
    sh "$BIN/move-by-date.sh" --apply >> "$LOG" 2>&1
    # 2) 登记：扫描整个 inbox（幂等）
    sh "$BIN/judge.sh" --ingest >> "$LOG" 2>&1
    LAST_INGEST=$NOW
  fi

  # 到点后当天只跑一次完整判读；若 02:30 那轮正忙，下一轮补跑
  H=$(date +%H | sed 's/^0//'); [ -z "$H" ] && H=0
  M=$(date +%M | sed 's/^0//'); [ -z "$M" ] && M=0
  NOWMIN=$((H * 60 + M))
  TODAY=$(date +%Y%m%d)
  # 只在 02:30~03:30 这一小时窗口内触发（不是"过了 2:30 就随时跑"）
  # 旧写法 NOWMIN >= 2:30 会让当天任意时刻都触发，实测 23:55 又被判了一次
  JUDGE_LO=$((JUDGE_HH * 60 + JUDGE_MM))
  JUDGE_HI=$((JUDGE_LO + 60))
  if [ "$NOWMIN" -ge "$JUDGE_LO" ] && [ "$NOWMIN" -lt "$JUDGE_HI" ] && [ "$LAST_JUDGE" != "$TODAY" ]; then
    echo "$(date '+%F %T') 开始夜间判读（$TODAY）" >> "$LOG"
    sh "$BIN/judge.sh" --judge >> "$LOG" 2>&1
    LAST_JUDGE="$TODAY"
  fi

  sleep 60
done