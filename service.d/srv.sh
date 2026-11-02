#!/system/bin/sh
# K40 server autostart - Magisk service.d (late_start), runs as root
S=/data/adb/srv
# musl static aria2 has no /etc/resolv.conf and ignores RESOLV_CONF,
# restore wireless adb on every boot
setprop persist.adb.tcp.port 5555
setprop service.adb.tcp.port 5555
stop adbd
start adbd

# wait for wlan0 to get an IPv4 (up to 5 minutes)
i=0
while [ -z "$(ip addr show wlan0 2>/dev/null | grep 'inet ')" ] && [ $i -lt 60 ]; do
  sleep 5
  i=$((i+1))
done
sleep 3

# keep the server awake (dead panel, but SoC must not sleep or downloads stall)
settings put system screen_off_timeout 2147483647
settings put global stay_on_while_plugged_in 3
dumpsys deviceidle disable >/dev/null 2>&1

# 内核级 wakelock: 阻止 suspend, 否则 doze 时 cnss_pci(phy0) 挂起
# 失败(errno=-16 EBUSY)会让 WiFi 关联丢失且不自愈 (2026-10-19 实测)
echo CHANGE_ME > /sys/power/wake_lock 2>/dev/null

# aria2 download engine
if [ -x "$S/bin/aria2c" ] && [ -f "$S/aria2.conf" ]; then
  "$S/bin/aria2c" --conf-path="$S/aria2.conf" 2>/dev/null
fi

# alist cloud storage
if [ -x "$S/bin/alist" ]; then
  cd "$S"
  nohup "$S/bin/alist" server >> "$S/data/alist.log" 2>&1 &
fi

# ddns-go dynamic DNS: DISABLED 2026-10-17 (Tailscale covers remote access,
# so public IPv6 exposure + DDNS is unnecessary and would be less safe).
# Binary and config kept in case it is ever wanted again.
#
# if [ -x "$S/bin/ddns-go" ]; then
#   pkill -f 'bin/ddns-go' >/dev/null 2>&1
#   "$S/bin/ddns-go" -c "$S/data/ddns-go-config.yaml" -l 0.0.0.0:9876 -f 300 -d >/dev/null 2>&1
# fi

# battery charge limiter (2s re-assert loop; must be a nohup child, never a
# blocking service.d script or it would stall the scripts after it)
if [ -f "$S/battguard.sh" ]; then
  pkill -f 'srv/battguard.sh' >/dev/null 2>&1
  nohup "$S/battguard.sh" >/dev/null 2>&1 &
fi

# ---- fixadb: adb_enabled=0 ?? adbd ??? 5555 (appended 2026-10-22) ----
echo "$(date '+%m-%d %H:%M:%S') === fixadb hook start (srv.sh) ===" >> /data/adb/srv/data/fixadb.log
(
  i=0
  while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 90 ]; do sleep 2; i=$((i+1)); done
  sleep 30
  for n in 1 2 3 4 5; do
    A=$(settings get global adb_enabled 2>/dev/null)
    [ "$A" != "1" ] && { settings put global adb_enabled 1; echo "$(date '+%m-%d %H:%M:%S') adb_enabled: $A -> 1" >> /data/adb/srv/data/fixadb.log; }
    settings put global adb_allowed_connection_time 0 2>/dev/null
    setprop persist.adb.tcp.port 5555
    setprop service.adb.tcp.port 5555
    stop adbd; sleep 1; start adbd; sleep 4
    if grep -q ":15B3" /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
      echo "$(date '+%m-%d %H:%M:%S') 5555 listening after attempt $n" >> /data/adb/srv/data/fixadb.log
      break
    fi
    echo "$(date '+%m-%d %H:%M:%S') attempt $n: 5555 down" >> /data/adb/srv/data/fixadb.log
    sleep 8
  done
  if grep -q ":15B3" /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    echo "$(date '+%m-%d %H:%M:%S') RESULT 5555 OK" >> /data/adb/srv/data/fixadb.log
  else
    echo "$(date '+%m-%d %H:%M:%S') RESULT 5555 DOWN" >> /data/adb/srv/data/fixadb.log
  fi
) >> /data/adb/srv/data/fixadb.log 2>&1 &
# ---- end fixadb ----


# ---- AdGuard Home: LAN-wide clean DNS (added 2026-10-25) ----
# SSL_CERT_FILE is REQUIRED: Go in AGH static binary finds no CA store on Android,
# without it DoT upstream fails with "certificate signed by unknown authority".
if [ -x /data/adb/agh/AdGuardHome/AdGuardHome ] && [ -f /data/adb/agh/ca-bundle.pem ]; then
  pgrep -f 'AdGuardHome -c' >/dev/null 2>&1 || {
    cd /data/adb/agh/AdGuardHome
    SSL_CERT_FILE=/data/adb/agh/ca-bundle.pem nohup ./AdGuardHome -c AdGuardHome.yaml >/data/adb/agh/agh.log 2>&1 &
  }
fi
# ---- end AdGuard Home ----

# ---- magnet search: busybox httpd + CGI (added 2026-10-28) ----
# 静态搜索页 + apibay 代理 + aria2 推送，单端口 8080，同源无 CORS 问题。
# 内存约 1-2MB，空闲 CPU 为 0。关闭方法：注释掉这一段并重启。
if [ -d /data/adb/srv/magnet/www ] && [ -x /data/adb/magisk/busybox ]; then
  pgrep -f 'httpd -p 8080' >/dev/null 2>&1 || \
    /data/adb/magisk/busybox httpd -p 8080 -h /data/adb/srv/magnet/www -c /data/adb/srv/magnet/httpd.conf
fi
# ---- end magnet search ----
