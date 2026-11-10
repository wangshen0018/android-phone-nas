"""构建期拉取服务端要用到的第三方程序，校验后放进 jniLibs / assets。

为什么不入库：项目约定仓库只放文本，二进制一律不进 git；本机也没有安卓 NDK。
所以由 CI 在每次构建前下载固定 tag 的 release，逐个核 SHA256 再落盘。

关键约束（Android 10+）：
  · 不能 exec 应用私有可写目录里的 ELF；
  · 但 APK 里 lib/<abi>/lib*.so 会由系统解压到 nativeLibraryDir（只读、可执行）。
  · 所以静态 ELF 必须改名为 lib*.so，且 android:extractNativeLibs="true"。

用法：python3 apps/server/fetch-tools.py
幂等：目标文件已存在且 hash 正确就跳过；校验失败直接报错，不静默降级。
"""

import hashlib
import io
import lzma
import os
import sys
import tarfile
import urllib.request
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SERVER = os.path.join(ROOT, "apps", "server", "src", "main")
JNI = os.path.join(SERVER, "jniLibs", "arm64-v8a")
ASSETS = os.path.join(SERVER, "assets")
# AriaNg 只通过 runtime.zip 进 APK，放 assets/ 会被 AGP 再打一份
THIRD = os.path.join(ROOT, "apps", "server", "thirdparty")

# 固定 tag，不用 latest：升级要手工改这里并重新核 hash。
TOOLS = [
    {
        "name": "aria2c",
        "url": "https://github.com/abcfy2/aria2-static-build/releases/download/"
               "1.37.0/aria2-aarch64-linux-musl_static.zip",
        "sha256": "0c681a89a40e0f82d1f5137608e86257eb0af201459c002941ea098f2b8c26b6",
        "kind": "zip",
        "member": "aria2c",
        "dest": os.path.join(JNI, "libaria2c.so"),
    },
    {
        "name": "curl",
        "url": "https://github.com/stunnel/static-curl/releases/download/"
               "8.23.0-1/curl-linux-aarch64-musl-8.23.0-1.tar.xz",
        "sha256": "e20f26e5b87c1883608f286f86bdabf39d3b8556e8a8e75dfe205e14bd206199",
        "kind": "tarxz",
        "member": "curl",
        "dest": os.path.join(JNI, "libcurl.so"),
    },
    {
        "name": "AriaNg",
        "url": "https://github.com/mayswind/AriaNg/releases/download/"
               "1.3.15/AriaNg-1.3.15.zip",
        "sha256": "d2317e441966ad31f1e342cb6a6cc1c51808fb0a10cf6e39cb30b0517b3e7823",
        "kind": "ariang",
        "dest": os.path.join(THIRD, "ariang", "index.html"),
    },
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


CACHE = os.environ.get("PANTRY_BIN_CACHE", "").strip()


def download(url, name):
    """优先读本地缓存（离线构建/本机验证），其次系统 curl，最后 urllib。

    本机走代理时 Python urllib 连不通，所以用 curl 子进程；CI runner 上两者都可用。
    缓存按 <name>.bin 命名，内容仍要过下面的 SHA256 校验，不会降低安全性。"""
    if CACHE:
        p = os.path.join(CACHE, name + ".bin")
        if os.path.isfile(p):
            return open(p, "rb").read()
    last = None
    try:
        import subprocess
        r = subprocess.run(
            ["curl", "-fsSL", "--max-time", "180", "--retry", "2", url],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode == 0 and r.stdout:
            return r.stdout
        last = r.stderr.decode("utf-8", "replace")[-200:]
    except Exception as e:
        last = e
    req = urllib.request.Request(url, headers={"User-Agent": "pantry-build"})
    for attempt in range(2):
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                return r.read()
        except Exception as e:              # 网络抖动重试，不吞掉最终失败
            last = e
    raise RuntimeError("下载失败 {}: {}".format(url, last))


def extract(name, kind, data, member):
    """返回 {目标相对路径: 字节}，二进制统一改名成 lib*.so 由调用方落盘。"""
    if kind == "zip":
        z = zipfile.ZipFile(io.BytesIO(data))
        return z.read(member)
    if kind == "tarxz":
        t = tarfile.open(fileobj=io.BytesIO(lzma.decompress(data)))
        for m in t.getmembers():
            if m.isfile() and os.path.basename(m.name) == member:
                return t.extractfile(m).read()
        raise RuntimeError("{} 里没找到 {}".format(name, member))
    raise RuntimeError("未知解包方式 " + kind)


def main():
    os.makedirs(JNI, exist_ok=True)
    os.makedirs(ASSETS, exist_ok=True)
    manifest = []
    for t in TOOLS:
        dest = t["dest"]
        raw = download(t["url"], t["name"])
        got = sha256(raw)
        if got != t["sha256"]:
            raise SystemExit("!! {} SHA256 不符：期望 {}，实得 {}".format(
                t["name"], t["sha256"], got))

        if t["kind"] == "ariang":
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            z = zipfile.ZipFile(io.BytesIO(raw))
            for m in z.infolist():
                if m.is_dir():
                    continue
                p = os.path.join(os.path.dirname(dest), m.filename.replace("\\", "/"))
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "wb") as f:
                    f.write(z.read(m.filename))
            payload = raw
            size = sum(i.file_size for i in z.infolist() if not i.is_dir())
            print("  {:<8} {:.2f} MB  -> thirdparty/ariang/ ({} 文件)".format(
                t["name"], len(raw) / 1048576, len(z.namelist())))
        else:
            payload = extract(t["name"], t["kind"], raw, t["member"])
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.exists(dest) and sha256(open(dest, "rb").read()) == sha256(payload):
                print("  {:<8} 已是最新，跳过".format(t["name"]))
            else:
                with open(dest, "wb") as f:
                    f.write(payload)
                os.chmod(dest, 0o755)
                print("  {:<8} {:.2f} MB  -> {}".format(
                    t["name"], len(payload) / 1048576,
                    os.path.relpath(dest, ROOT).replace("\\", "/")))
            size = len(payload)
            # 静态 ELF 必须没有 PT_INTERP，否则 Android 上找不到动态加载器
            if payload[:4] != b"\x7fELF" or payload[4] != 2:
                raise SystemExit("!! {} 不是 64 位 ELF".format(t["name"]))
            ptype_interp = 3
            phoff = int.from_bytes(payload[32:40], "little")
            phentsize = int.from_bytes(payload[54:56], "little")
            phnum = int.from_bytes(payload[56:58], "little")
            for i in range(phnum):
                o = phoff + i * phentsize
                if int.from_bytes(payload[o:o + 4], "little") == ptype_interp:
                    raise SystemExit("!! {} 带 PT_INTERP，不是静态二进制".format(t["name"]))
        manifest.append("{}  {}  {}".format(
            t["name"] + ("-zip" if t["kind"] == "ariang" else ""),
            sha256(payload), size))

    with open(os.path.join(ASSETS, "tools.sha256"), "w", encoding="utf-8") as f:
        f.write("# 由 fetch-tools.py 生成，App 启动时核对内置程序完整性\n")
        f.write("\n".join(manifest) + "\n")
    print("已写 assets/tools.sha256")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("fetch-tools 失败：{}".format(e), file=sys.stderr)
        sys.exit(1)
