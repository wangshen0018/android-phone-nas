#!/system/bin/sh
# lib-lock.sh — 单实例互斥锁（供 bin/*.sh source）
#
# 为什么需要（2026-11-03 实际踩到）：
#   judge.sh 与 media-gc.sh 都用固定名中间文件
#     · judge.sh    → $LOGD/_data.json.tmp、$LOGD/_scan.txt
#     · media-gc.sh → $ST/_media_gc.list、$ST/_arc_mids.txt
#   两个实例同时跑时，后启动的那个会 rm 掉前一个正在读的临时文件，
#   结果是两类假象：
#     1) judge.sh 报「build: 失败(JSON不完整)」，旧 data.json 保留（数据没坏，但日志误导）
#     2) media-gc.sh 干跑报 kept=0 kept_archive=0 would_drop=0，与真实值（3098/66/0）差得离谱
#   这不是数据损坏，是固定临时文件名 + 无互斥锁的必然结果。
#   更要紧的是：两次 judge.sh --judge 并发会让同一批照片调两遍 VLM，等于双倍花钱。
#
# 机制：mkdir 是原子操作，用它当锁。
#   · 锁目录 $LOCKDIR/<名字>.lock/ 内写 pid
#   · 拿不到锁 → 直接返回失败，由调用方决定退出（不阻塞、不等待）
#   · 锁目录在、但里面的 pid 已不存在 → 判定为陈旧锁（上次被 kill -9），
#     清掉后重试；pid 可能被系统复用，所以再加一条"锁目录年龄超过 6 小时即视为陈旧"
#
# 锁目录为什么放 /data/local/tmp 而不是 state/：
#   /data/media/0 是 FUSE 挂载层，mkdir 原子性没有保证（实测踩过 ls 重定向 rc=1）；
#   /data/local/tmp 是真实文件系统，mkdir 原子可靠，且不在 media-gc 的扫描范围内。
#
# 用法：
#   . /data/adb/nasbak/bin/lib-lock.sh
#   if ! lock_acquire judge; then
#       echo "已有实例在运行，本次退出" >&2
#       exit 0
#   fi
#   trap 'lock_release judge' 0 INT TERM
#   ...主体...
#   lock_release judge          # 可省略，trap 会兜底

LOCKDIR=/data/local/tmp/nasbak-locks
LOCK_MAXAGE=21600            # 锁目录年龄上限（秒），超过即视为陈旧锁
BB=/data/adb/magisk/busybox   # 统一走 busybox：crond 的 PATH 与交互 shell 不同，
                              # /system/bin 的 toybox 未必支持 stat -c 之类的写法

# lock_acquire <名字> [最大尝试次数，默认1]
# 成功返回 0，失败返回 1
lock_acquire() {
  _ln="$1"
  _maxtry="${2:-1}"
  _t=0
  mkdir -p "$LOCKDIR" 2>/dev/null
  while [ "$_t" -lt "$_maxtry" ]; do
    if mkdir "$LOCKDIR/$_ln.lock" 2>/dev/null; then
      echo $$ > "$LOCKDIR/$_ln.lock/pid" 2>/dev/null
      return 0
    fi

    # 锁已存在：判断是不是陈旧锁
    _p=$(cat "$LOCKDIR/$_ln.lock/pid" 2>/dev/null)
    _mt=$($BB stat -c %Y "$LOCKDIR/$_ln.lock" 2>/dev/null)
    _age=$(( $(date +%s) - ${_mt:-0} ))

    if [ -z "$_p" ]; then
      # 还没有 pid 文件：可能是对方刚 mkdir 完还没写 pid（毫秒级窗口）。
      # 目录很新就当对方活着，不去抢；目录很旧才当陈旧锁清掉。
      if [ "$_age" -lt 60 ]; then
        _t=$((_t+1)); sleep 1; continue
      fi
      rm -rf "$LOCKDIR/$_ln.lock" 2>/dev/null
      _t=$((_t+1)); continue
    fi

    if ! kill -0 "$_p" 2>/dev/null; then
      # 持锁进程已死（上次被 kill -9）→ 陈旧锁，清掉后重试
      rm -rf "$LOCKDIR/$_ln.lock" 2>/dev/null
      _t=$((_t+1)); continue
    fi

    # pid 还活着，但可能是系统复用的别人的 pid；再按锁目录年龄兜一次
    if [ "$_age" -gt "$LOCK_MAXAGE" ]; then
      rm -rf "$LOCKDIR/$_ln.lock" 2>/dev/null
      _t=$((_t+1)); continue
    fi

    _t=$((_t+1))
    sleep 1
  done
  return 1
}

# lock_release <名字>：只释放属于自己的锁
lock_release() {
  _ln="$1"
  _d="$LOCKDIR/$_ln.lock"
  _p=$(cat "$_d/pid" 2>/dev/null)
  if [ -z "$_p" ] || [ "$_p" = "$$" ]; then
    rm -rf "$_d" 2>/dev/null
  fi
}

# lock_busy <名字>：锁存在且持锁进程还活着 → 返回 0（正忙）
# 用于「两个脚本操作同一份数据、但不必互斥执行」的场景：
# 例如 media-gc 要搬走 media/ 里的副本，而 judge.sh --ingest 正在往 media/ 里建副本，
# 两者同时做会让新建的副本被当成孤儿搬走。此时 media-gc 主动让路即可。
lock_busy() {
  _ln="$1"
  _p=$(cat "$LOCKDIR/$_ln.lock/pid" 2>/dev/null)
  [ -n "$_p" ] || return 1
  kill -0 "$_p" 2>/dev/null
}
