"""把服务端运行时（脚本 / 页面 / 配置 / 第三方前端）打成 assets/runtime.zip。

App 首次启动解压到私有目录，之后由 Java 写的 HTTP 服务 + /system/bin/sh 跑起来。

体积换来的能力（0.3 起）：
  · aria2c / curl 是随 APK 分发的静态 ELF，放在 jniLibs 里由系统解压到可执行目录；
    fetch-tools.py 负责下载和校验，本脚本不碰它们。
  · AriaNg 前端由 fetch-tools.py 放到 thirdparty/ariang/，这里收进 www/ariang/。
  · srv/aria2.sh 是磁力 CGI 的公共库，放在 web 根之外，避免被当静态文件下载。

HTTP 服务、缩略图仍由 Java 实现，不需要 busybox httpd 或 ffmpeg；
命令走系统 toybox，定时归位由 Service 的 Handler 调度。

用法：
    python apps/server/pack-assets.py

CI 里由 .github/workflows/build-apk.yml 自动执行这一步，产物不入库。
"""

import os
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "apps", "server", "src", "main", "assets")
OUT = os.path.join(OUT_DIR, "runtime.zip")

# 进包的内容。service.d 和 cron 是 Magisk 专用，App 版用自己的前台服务和 Handler。
DIRS = ["www", "bin", "etc"]
FILES = ["httpd.conf"]
# 单独收：库放 web 根之外；AriaNg 是构建期下载的第三方前端
EXTRA_FILES = [("srv/aria2.sh", "srv/aria2.sh")]
ARIANG_SRC = os.path.join(ROOT, "apps", "server", "thirdparty", "ariang")

SKIP_SUFFIX = (".bak", "~", ".pyc")
SKIP_NAME = (".DS_Store", "Thumbs.db")

# App 里的实际路径由 Env.writeConf() 每次启动重写，这里只是首次解压时的兜底：
# 就算配置没写成功，脚本也不会去读 /data/adb 那个不存在的地方。
APP_HOME = "/data/data/com.pantry.server/files/runtime"
APP_STORE = "/storage/emulated/0/Pantry"
APP_LOG = "/data/data/com.pantry.server/files/runtime/logs"
APP_TMP = "/data/data/com.pantry.server/files/tmp"

CONF = """# 由 pack-assets.py 生成的兜底配置。
# 服务端 App 启动时用 Env.writeConf() 按真实路径重写，手改会被覆盖。
NASBAK_HOME={home}
NASBAK_ROOT={store}
NASBAK_PORT=8083
NASBAK_LOGD={logd}
NASBAK_TMP={tmp}
NASBAK_BB=/system/bin/toybox
"""


def should_skip(path):
    name = os.path.basename(path)
    if name in SKIP_NAME:
        return True
    return any(name.endswith(s) or ".bak-" in name for s in SKIP_SUFFIX)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    n = 0
    leftovers = []
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for d in DIRS:
            src = os.path.join(ROOT, d)
            if not os.path.isdir(src):
                continue
            for base, dirs, files in os.walk(src):
                dirs[:] = [x for x in dirs if not x.startswith(".")]
                for fn in files:
                    full = os.path.join(base, fn)
                    if should_skip(full):
                        continue
                    rel = os.path.relpath(full, src).replace("\\", "/")
                    arc = d + "/" + rel
                    # App 版配置下面单独写，别把仓库里的设备版配置一起打进去（会重名）
                    if arc == "etc/nasbak.conf":
                        continue
                    z.write(full, arc)
                    n += 1
                    # lib-path.sh 里的默认值是有意保留的设备版兜底，不算残留；
                    # 磁力/迅雷靠 aria2 和外部二进制，App 版不支持，单独列出来
                    if (arc.endswith((".sh", ".cgi"))
                            and arc != "bin/lib-path.sh"
                            and not arc.startswith("www/magnet/")):
                        with open(full, "r", encoding="utf-8", errors="replace") as f:
                            txt = f.read()
                        if "/data/adb/nasbak" in txt or "/data/media/0/nasbak" in txt:
                            leftovers.append(arc)
        for f in FILES:
            src = os.path.join(ROOT, f)
            if os.path.isfile(src):
                z.write(src, f)
                n += 1
        for src_rel, arc in EXTRA_FILES:
            src = os.path.join(ROOT, src_rel)
            if os.path.isfile(src):
                z.write(src, arc)
                n += 1
            else:
                print("!! 缺少 " + src_rel)

        # AriaNg：下载管理页跳 /ariang/index.html，缺了就 404
        if os.path.isdir(ARIANG_SRC):
            for base, dirs, files in os.walk(ARIANG_SRC):
                dirs[:] = [x for x in dirs if not x.startswith(".")]
                for fn in files:
                    if should_skip(fn):
                        continue
                    full = os.path.join(base, fn)
                    rel = os.path.relpath(full, ARIANG_SRC).replace("\\", "/")
                    z.write(full, "www/ariang/" + rel)
                    n += 1
        else:
            print("!! 没找到 AriaNg（先跑 fetch-tools.py），下载管理页会 404")

        z.writestr("etc/nasbak.conf",
                   CONF.format(home=APP_HOME, store=APP_STORE,
                               logd=APP_LOG, tmp=APP_TMP))

    size = os.path.getsize(OUT)
    print("生成 {}（{:.1f} KB，{} 个文件）".format(OUT, size / 1024, n))
    if leftovers:
        print("")
        print("!! 以下脚本还在用写死的旧路径，App 版会读不到数据：")
        for x in leftovers:
            print("   " + x)
    else:
        print("路径检查：没有写死的 /data/adb/nasbak 或 /data/media/0/nasbak")
    print("")
    print("不支持：迅雷 P2SP、代理节点、投屏、alist/WebDAV。")
    print("  · 投屏需要 shell 级截屏权限，普通 App 拿不到；")
    print("  · 迅雷和代理要外部 App / sing-box 进程，随包分发的只是 aria2 与 curl；")
    print("  · 文件管理改由 App 内置的只读浏览器提供（/files.html + /dl/），")
    print("    不用 119 MB 的 alist。首页会按 /cgi/caps.cgi 隐藏没有的入口。")


if __name__ == "__main__":
    main()
