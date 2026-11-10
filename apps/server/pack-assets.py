"""把服务端运行时打成 assets/runtime.zip。

App 第一次启动会把这个 zip 解压到自己的私有目录，然后起 httpd。

用法（在仓库根执行）：
    python apps/server/pack-assets.py                # 只打脚本/页面/配置
    python apps/server/pack-assets.py --adb IP:5555  # 顺带从设备拉 busybox / ffmpeg

**这一版只是骨架，打出来的包还不能直接跑。** 差两件事，见文件末尾的 TODO。
脚本会如实列出来，别把"能构建"当成"能服务"。

zip 不入库（体积大、可能含二进制），由本机生成后再构建 APK。
"""

import argparse
import os
import subprocess
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "apps", "server", "src", "main", "assets")
OUT = os.path.join(OUT_DIR, "runtime.zip")

# 进包的内容。service.d 是 Magisk 专用，App 版用自己的前台服务，不带。
DIRS = ["www", "bin", "etc"]
FILES = ["httpd.conf"]

SKIP_SUFFIX = (".bak", "~", ".pyc")
SKIP_NAME = (".DS_Store", "Thumbs.db")

# App 私有目录里的路径。写进 etc/nasbak.conf，lib-path.sh 会读它。
APP_FILES = "/data/data/com.pantry.server/files/runtime"
APP_STORE = "/storage/emulated/0/Pantry"

CONF = """# 由 pack-assets.py 生成：服务端 App 版路径配置。
# 设备原版在 /data/adb/nasbak，这里全部指向 App 私有目录和共享存储。
NASBAK_HOME={home}
NASBAK_ROOT={store}
NASBAK_WWW={home}/www
NASBAK_BIN={home}/bin
NASBAK_DATA={store}/state
NASBAK_LOGD={store}/state/log
# busybox / ffmpeg 由 App 放到 nativeLibraryDir，不在 zip 里
"""


def should_skip(path):
    name = os.path.basename(path)
    if name in SKIP_NAME:
        return True
    return any(name.endswith(s) or ".bak-" in name for s in SKIP_SUFFIX)


def add_tree(z, src, prefix):
    for base, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for fn in files:
            full = os.path.join(base, fn)
            if should_skip(full):
                continue
            rel = os.path.relpath(full, src).replace("\\", "/")
            z.write(full, prefix + "/" + rel)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--adb", help="设备地址，如 100.64.180.121:5555；给了就拉二进制")
    args = ap.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    n = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for d in DIRS:
            src = os.path.join(ROOT, d)
            if os.path.isdir(src):
                add_tree(z, src, d)
                n += sum(len(f) for _, _, f in os.walk(src))
        for f in FILES:
            src = os.path.join(ROOT, f)
            if os.path.isfile(src):
                z.write(src, f)
                n += 1
        # 覆盖仓库里的设备版配置，换成 App 版
        z.writestr("etc/nasbak.conf", CONF.format(home=APP_FILES, store=APP_STORE))

        if args.adb:
            for remote, local in [
                ("/data/adb/magisk/busybox", "bin/busybox"),
                ("/data/adb/nasbak/bin/ffmpeg", "bin/ffmpeg"),
            ]:
                tmp = os.path.join(OUT_DIR, os.path.basename(local))
                try:
                    subprocess.run(["adb", "-s", args.adb, "pull", remote, tmp],
                                   check=True, capture_output=True)
                    z.write(tmp, local)
                    os.remove(tmp)
                    print("  拉到 " + local)
                except Exception as e:
                    print("  拉不到 " + remote + "：" + str(e)[:80])

    size = os.path.getsize(OUT)
    print("生成 {}（{:.1f} KB，约 {} 个文件）".format(OUT, size / 1024, n))
    print()
    print("=== 这个包还不能直接跑，差两件事 ===")
    print("1. 脚本里有约 48 处 /data/adb/nasbak 内联路径，")
    print("   要靠 bin/lib-path.sh 全部收进变量才跑得动。这是路径抽象那一轮的工作。")
    print("2. Android 10 起不能直接 exec filesDir 里的二进制。")
    print("   busybox / ffmpeg 要以 libbusybox.so、libffmpeg.so 放进")
    print("   src/main/jniLibs/<abi>/，让系统装到 nativeLibraryDir 再执行。")
    print("   本脚本 --adb 拉下来的 bin/busybox 只是占位，正式版不能这么用。")


if __name__ == "__main__":
    main()
