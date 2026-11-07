#!/system/bin/sh
# zzz-nasbak.sh — 相册备份流程自启（Magisk service.d，以 root 运行）
# 起两样东西：判定页 httpd(8083) + 调度 daemon

BB=/data/adb/magisk/busybox
WWW=/data/adb/nasbak/www
CONF=/data/adb/nasbak/httpd.conf
BIN=/data/adb/nasbak/bin
LOGD=/data/adb/nasbak/logs

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 5; done
sleep 15

mkdir -p "$LOGD" 2>/dev/null
echo "$(date '+%F %T') service.d 唤醒" >> "$LOGD/boot.log" 2>/dev/null

# ---------- 判定页 ----------
# Android 的 ps -A 默认不输出命令行，必须带 -o pid,args 才能匹配
ps -A -o pid,args 2>/dev/null | grep -q "[h]ttpd.*8083" || {
  "$BB" httpd -p 8083 -h "$WWW" -c "$CONF" 2>>"$LOGD/boot.log"
  echo "$(date '+%F %T') httpd 8083 已起" >> "$LOGD/boot.log" 2>/dev/null
}

# ---------- 调度 daemon ----------
ps -A -o pid,args 2>/dev/null | grep -q "nasbak/bin/daemon.sh" || {
  setsid nohup sh "$BIN/daemon.sh" >/dev/null 2>&1 &
  echo "$(date '+%F %T') daemon 已起" >> "$LOGD/boot.log" 2>/dev/null
}

# ---------- 投屏服务（scrcpy-server 1.19-ws8，监听 8886）----------
# 2026-11-07 用户要求改为「按需启用」：不再开机自启、也不进 crond 看护。
# 由 www/screen.html 的「启动投屏 / 停止服务」按钮通过 www/cgi/scrcpy.cgi 触发，
# 无人观看时手机不占编码资源、不持续发热。
# 手动排障仍可直接执行：sh /data/adb/nasbak/bin/scrcpy-serve.sh start|stop|status
