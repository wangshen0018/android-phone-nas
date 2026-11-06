#!/system/bin/sh
# scrcpy-serve.sh — K40 本机投屏服务（scrcpy-server 1.19-ws8）启停与看护
#
# 作用：给 www/screen.html 提供 ws://<K40>:8886 的视频 + 控制通道。
#   start   启动（已在跑则直接返回）
#   stop    停止
#   status  打印进程/端口状态
#   ensure  供 crond 看护：没跑、或进程在但端口没监听，就拉起
#
# 为什么不再依赖 PC：scrcpy 1.19-ws8 内核自带 Java-WebSocket 服务（监听 8886），
# 浏览器可直连，node 桥那一层可以完全去掉（2026-11-06 实机验证）。
#
# jar 位置：/data/adb/nasbak/srv/scrcpy-server.jar（不放 /data/local/tmp，避免被清理）
# 日志：    /data/adb/nasbak/logs/scrcpy-serve.log

BB=/data/adb/magisk/busybox
JAR=/data/adb/nasbak/srv/scrcpy-server.jar
VER=1.19-ws8
PORT=8886
LOGD=/data/adb/nasbak/logs
LOG=$LOGD/scrcpy-serve.log

mkdir -p "$LOGD" 2>/dev/null

log() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }

find_pid() {
    ps -A -o pid,args 2>/dev/null | grep "[c]om.genymobile.scrcpy.Server $VER" | awk '{print $1}' | head -n1
}

port_up() {
    "$BB" netstat -ltn 2>/dev/null | grep -q ":$PORT "
}

do_start() {
    pid=$(find_pid)
    if [ -n "$pid" ]; then
        if port_up; then
            echo "already running pid=$pid port=$PORT"
            return 0
        fi
        log "进程在(pid=$pid)但端口未监听，重启"
        kill "$pid" 2>/dev/null
        sleep 1
    fi
    if [ ! -f "$JAR" ]; then
        log "jar 缺失: $JAR"
        echo "jar 缺失: $JAR" >&2
        return 1
    fi
    CLASSPATH="$JAR" setsid nohup app_process / com.genymobile.scrcpy.Server "$VER" web ERROR "$PORT" true >>"$LOG" 2>&1 &
    sleep 2
    pid=$(find_pid)
    if [ -n "$pid" ] && port_up; then
        log "已启动 pid=$pid port=$PORT"
        echo "started pid=$pid port=$PORT"
        return 0
    fi
    log "启动失败（pid=$pid）"
    echo "启动失败，见 $LOG" >&2
    return 1
}

do_stop() {
    pid=$(find_pid)
    if [ -z "$pid" ]; then
        echo "not running"
        return 0
    fi
    kill "$pid" 2>/dev/null
    sleep 1
    [ -n "$(find_pid)" ] && kill -9 "$pid" 2>/dev/null
    log "已停止 pid=$pid"
    echo "stopped pid=$pid"
}

do_status() {
    pid=$(find_pid)
    if [ -n "$pid" ]; then
        if port_up; then
            echo "running pid=$pid port=$PORT listening"
        else
            echo "running pid=$pid port=$PORT DOWN"
        fi
    else
        echo "not running"
    fi
    if [ -f "$JAR" ]; then echo "jar ok: $JAR"; else echo "jar MISSING: $JAR"; fi
}

do_ensure() {
    if [ -n "$(find_pid)" ] && port_up; then return 0; fi
    log "ensure: 未运行或端口失效，拉起"
    do_start >/dev/null 2>&1
}

case "$1" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    ensure) do_ensure ;;
    *) echo "用法: $0 start|stop|status|ensure"; exit 2 ;;
esac
