# 部署到 K40
#
# 用法：
#   $env:ADB_DEVICE = "<K40_LAN_IP>:5555"
#   .\deploy\deploy.ps1              # 全量部署
#   .\deploy\deploy.ps1 -Only www    # 只部署某个目录
#
# 为什么不能直接 adb push 到 /data/adb：
#   /data/adb 是 root 所有、权限 700，adb push 会 Permission denied。
#   必须先推到 /data/local/tmp，再用 su -c 复制到位。

[CmdletBinding()]
param(
    [string]$Device  = $env:ADB_DEVICE,
    [string]$Only    = "",
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
$Repo = Split-Path -Parent $PSScriptRoot

if (-not $Device) { $Device = "<K40_LAN_IP>:5555" }

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# ---------- 连通性 ----------
Say "==> 检查设备 $Device" Cyan
$devs = & adb devices | Select-String $Device
if (-not $devs) { Die "设备未连接。先 adb connect $Device" }
$ok = & adb -s $Device shell "su -c 'echo ROOT_OK'" 2>&1
if ($ok -notmatch 'ROOT_OK') { Die "su 不可用，需要 Magisk root" }
Say "    root 可用"

# ---------- 映射表 ----------
$Map = [ordered]@{
  'bin'        = '/data/adb/nasbak/bin'
  'www'        = '/data/adb/nasbak/www'
  'httpd.conf' = '/data/adb/nasbak/httpd.conf'
  'srv'        = '/data/adb/srv'
  'service.d'  = '/data/adb/service.d'
  'cron'       = '/data/adb/modules/GGAT_10007/crond'
  'gyp'        = '/data/local/tmp/gyp'
}

# srv 下文件的真实落点（源文件名 -> 目标绝对路径）
$SrvMap = [ordered]@{
  'aria2.conf'       = '/data/adb/srv/aria2.conf'
  'aria2.sh'         = '/data/adb/srv/magnet/lib/aria2.sh'
  'proxy-lib.sh'     = '/data/adb/srv/magnet/proxy-lib.sh'
  'magnet-httpd.conf'= '/data/adb/srv/magnet/httpd.conf'
  'update-trackers.sh' = '/data/adb/srv/update-trackers.sh'
  'bt-stall.sh'        = '/data/adb/srv/bt-stall.sh'
  'scrcpy-server-1.19-ws8.jar' = '/data/adb/nasbak/srv/scrcpy-server.jar'
}

# www 下需要保持可执行的 CGI
$CgiDirs = @('www/cgi', 'www/magnet/cgi-bin')

# ---------- 清理远端暂存 ----------
Say "==> 准备远端暂存区" Cyan
& adb -s $Device shell "rm -rf /data/local/tmp/stage" | Out-Null
& adb -s $Device shell "mkdir -p /data/local/tmp/stage" | Out-Null

# ---------- 推送 ----------
$targets = if ($Only) { @($Only) } else { $Map.Keys }
Say "==> 推送 ($($targets -join ', '))" Cyan

$pushed = 0
foreach ($t in $targets) {
    if ($t -eq 'srv') {
        foreach ($f in $SrvMap.Keys) {
            $srcFile = Join-Path $Repo "srv/$f"
            if (-not (Test-Path $srcFile)) { Say "    skip srv/$f" Yellow; continue }
            & adb -s $Device push $srcFile "/data/local/tmp/stage/srv_$f" 2>&1 | Out-Null
            $pushed++
        }
        continue
    }
    if ($t -eq 'httpd.conf') {
        $srcFile = Join-Path $Repo "httpd.conf"
        & adb -s $Device push $srcFile "/data/local/tmp/stage/httpd.conf" 2>&1 | Out-Null
        $pushed++; continue
    }
    if ($t -eq 'cron') {
        & adb -s $Device push (Join-Path $Repo "cron/root") "/data/local/tmp/stage/cron_root" 2>&1 | Out-Null
        $pushed++; continue
    }

    $srcDir = Join-Path $Repo $t
    if (-not (Test-Path $srcDir)) { Say "    skip $t（目录不存在）" Yellow; continue }
    $files = Get-ChildItem $srcDir -Recurse -File
    $n = 0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($srcDir.Length + 1) -replace '\\','/'
        $stageName = ($t -replace '/','_') + "__" + ($rel -replace '/','__')
        & adb -s $Device push $f.FullName "/data/local/tmp/stage/$stageName" 2>&1 | Out-Null
        $n++
    }
    Say ("    {0,-12} {1,3} 个文件" -f $t, $n)
    $pushed += $n
}
Say "    共推送 $pushed 个文件"

# ---------- 远端安装 ----------
Say "==> 远端安装" Cyan
$install = @'
#!/system/bin/sh
set -e
ST=/data/local/tmp/stage

place() {   # place <stagefile> <destdir> <destname> <fallback>
  local src="$1" dir="$2" name="$3"
  mkdir -p "$dir" 2>/dev/null
  if cp -f "$src" "$dir/$name" 2>/dev/null; then return 0; fi
  [ -n "$4" ] && cp -f "$src" "$4" 2>/dev/null && return 0
  return 1
}

# --- bin ---
for f in $ST/bin__*.sh; do
  [ -f "$f" ] || continue
  n=$(basename "$f" | sed 's/^bin__//')
  cp -f "$f" "/data/adb/nasbak/bin/$n"
done
chmod 755 /data/adb/nasbak/bin/*.sh 2>/dev/null

# --- www 顶层 html ---
for f in $ST/www__*.html; do
  [ -f "$f" ] || continue
  n=$(basename "$f" | sed 's/^www__//')
  case "$n" in magnet__*) continue;; esac
  cp -f "$f" "/data/adb/nasbak/www/$n"
done

# --- www/cgi ---
mkdir -p /data/adb/nasbak/www/cgi /data/adb/nasbak/www/magnet/cgi-bin
for f in $ST/www__cgi__*.cgi; do
  [ -f "$f" ] || continue
  n=$(basename "$f" | sed 's/^www__cgi__//')
  cp -f "$f" "/data/adb/nasbak/www/cgi/$n"
done
chmod 755 /data/adb/nasbak/www/cgi/*.cgi 2>/dev/null

# --- www/magnet ---
for f in $ST/www__magnet__index.html; do
  [ -f "$f" ] && cp -f "$f" /data/adb/nasbak/www/magnet/index.html
done
for f in $ST/www__magnet__cgi-bin__*.cgi; do
  [ -f "$f" ] || continue
  n=$(basename "$f" | sed 's/^www__magnet__cgi-bin__//')
  cp -f "$f" "/data/adb/nasbak/www/magnet/cgi-bin/$n"
done
chmod 755 /data/adb/nasbak/www/magnet/cgi-bin/*.cgi 2>/dev/null
chmod 644 /data/adb/nasbak/www/*.html /data/adb/nasbak/www/magnet/index.html 2>/dev/null

# --- www/remote（投屏客户端静态资源，供 screen.html 内嵌）---
mkdir -p /data/adb/nasbak/www/remote
for f in $ST/www__remote__*; do
  [ -f "$f" ] || continue
  n=$(basename "$f" | sed 's/^www__remote__//')
  cp -f "$f" "/data/adb/nasbak/www/remote/$n"
done
chmod 644 /data/adb/nasbak/www/remote/* 2>/dev/null

# --- httpd.conf ---
[ -f $ST/httpd.conf ] && cp -f $ST/httpd.conf /data/adb/nasbak/httpd.conf

# --- srv ---
mkdir -p /data/adb/srv/magnet/lib
[ -f $ST/srv_aria2.conf ]        && cp -f $ST/srv_aria2.conf /data/adb/srv/aria2.conf
[ -f $ST/srv_aria2.sh ]          && cp -f $ST/srv_aria2.sh /data/adb/srv/magnet/lib/aria2.sh
[ -f $ST/srv_proxy-lib.sh ]      && cp -f $ST/srv_proxy-lib.sh /data/adb/srv/magnet/proxy-lib.sh
[ -f $ST/srv_magnet-httpd.conf ] && cp -f $ST/srv_magnet-httpd.conf /data/adb/srv/magnet/httpd.conf
[ -f $ST/srv_update-trackers.sh ] && cp -f $ST/srv_update-trackers.sh /data/adb/srv/update-trackers.sh
[ -f $ST/srv_bt-stall.sh ]        && cp -f $ST/srv_bt-stall.sh /data/adb/srv/bt-stall.sh
mkdir -p /data/adb/nasbak/srv
[ -f $ST/srv_scrcpy-server-1.19-ws8.jar ] && cp -f $ST/srv_scrcpy-server-1.19-ws8.jar /data/adb/nasbak/srv/scrcpy-server.jar
chmod 644 /data/adb/nasbak/srv/scrcpy-server.jar 2>/dev/null
chmod 755 /data/adb/srv/update-trackers.sh /data/adb/srv/bt-stall.sh 2>/dev/null

# --- service.d ---
for f in $ST/service.d__*.sh; do
  [ -f "$f" ] || continue
  n=$(basename "$f" | sed 's/^service.d__//')
  cp -f "$f" "/data/adb/service.d/$n"
done
chmod 755 /data/adb/service.d/*.sh 2>/dev/null

# --- cron ---
[ -f $ST/cron_root ] && cp -f $ST/cron_root /data/adb/modules/GGAT_10007/crond/root

# --- gyp ---
for f in $ST/gyp__*.sh; do
  [ -f "$f" ] || continue
  n=$(basename "$f" | sed 's/^gyp__//')
  cp -f "$f" "/data/local/tmp/gyp/$n"
done
chmod 755 /data/local/tmp/gyp/*.sh 2>/dev/null

echo INSTALL_DONE
'@
$install | Out-File -FilePath "$env:TEMP\k40_install.sh" -Encoding UTF8 -NoNewline
& adb -s $Device push "$env:TEMP\k40_install.sh" "/data/local/tmp/k40_install.sh" 2>&1 | Out-Null
& adb -s $Device shell "su -c 'sh /data/local/tmp/k40_install.sh'"

# ---------- 重启服务 ----------
if (-not $NoRestart) {
    Say "==> 重启服务" Cyan
    $restart = @'
#!/system/bin/sh
BB=/data/adb/magisk/busybox
CONF=/data/adb/nasbak/httpd.conf
WWW=/data/adb/nasbak/www

# httpd 8083：杀掉旧实例再起，否则改 html 不会生效（httpd 无缓存但保持连接）
pidof httpd >/dev/null 2>&1 && for p in $(pidof httpd); do
  tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q '8083' && kill "$p"
done
sleep 1
$BB httpd -p 8083 -h "$WWW" -c "$CONF"

# crond：必须先杀再用 GGAT_10007 自带的 busybox 启动
# 直接敲 crond 会 not found，而且旧进程残留会让定时任务全部失效
for p in /proc/[0-9]*/cmdline; do
  c=$(tr '\0' ' ' < "$p" 2>/dev/null)
  case "$c" in *crond*) kill $(basename "$(dirname "$p")") 2>/dev/null ;; esac
done
sleep 1
/data/adb/modules/GGAT_10007/busybox/crond -c /data/adb/modules/GGAT_10007/crond

# daemon：必须 setsid 脱离当前会话，普通 nohup & 会随 su -c 的 shell 一起死
for p in /proc/[0-9]*/cmdline; do
  c=$(tr '\0' ' ' < "$p" 2>/dev/null)
  case "$c" in *nasbak/bin/daemon.sh*) kill $(basename "$(dirname "$p")") 2>/dev/null ;; esac
done
sleep 1
rm -f /data/adb/nasbak/daemon.pid
setsid nohup sh /data/adb/nasbak/bin/daemon.sh >> /data/adb/nasbak/logs/daemon.log 2>&1 < /dev/null &
sleep 3
for d in /proc/[0-9]*; do
  c=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)
  case "$c" in *nasbak/bin/daemon.sh*) basename "$d" > /data/adb/nasbak/daemon.pid ;; esac
done

sh /data/adb/nasbak/bin/status-collect.sh
echo RESTART_DONE
'@
    $restart | Out-File -FilePath "$env:TEMP\k40_restart.sh" -Encoding UTF8 -NoNewline
    & adb -s $Device push "$env:TEMP\k40_restart.sh" "/data/local/tmp/k40_restart.sh" 2>&1 | Out-Null
    & adb -s $Device shell "su -c 'sh /data/local/tmp/k40_restart.sh'"
}

Say "==> 验证" Cyan
& adb -s $Device shell "for u in '' judge.html archive.html network.html stats.html magnet/ ariang/ ariang-setup.html; do printf '  /%-18s ' `$u; curl -s -m 6 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8083/`$u; done"

Say "完成。" Green
