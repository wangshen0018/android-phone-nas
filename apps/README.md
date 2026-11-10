# apps/

两个独立 APK，各装各的手机。

| 模块 | 应用名 | 包名 | 装在哪 |
|---|---|---|---|
| `client/` | Pantry | `com.nasbak.shell` | 家人的手机，看照片用 |
| `server/` | Pantry 库房 | `com.pantry.server` | 当库房那台手机，插电放着 |

图标都是储物柜，client 墨绿底，server 深靛蓝底加一颗指示灯。
`make-icon.py` 在仓库根跑一次就能重新生成两套图标。

`hub/` 是更早的一版草案（想用 Java 重写 HTTP 服务），没写完整，
不参与构建，留着当参考。别把它和 `server/` 混起来。

## 构建

本机不装 JDK / SDK / Gradle，推到 GitHub 后由 `.github/workflows/build-apk.yml`
在 runner 上执行：

```
cd apps
gradle :client:assembleDebug :server:assembleDebug
```

产物分别是 `pantry-client-*` 和 `pantry-server-*` 两个 artifact。
签名共用 `keystore/nasbak.p12`，已固定，可以直接覆盖安装。

## server 现在做到哪一步

**骨架。** 能编译、能装、能开界面，但还不能真正把面板跑起来。

已经有的：

- 首次启动引导开「所有文件访问」权限（Android 11+ 要让 shell 按路径读写照片）
- 前台服务和常驻通知
- 解压 `assets/runtime.zip` 到私有目录
- 界面显示状态、局域网地址、启停按钮
- 启动 `busybox httpd -f -p 8083 -h <www> -c <conf>` 的架子

还差两件，都是硬活，见 `server/pack-assets.py` 末尾：

1. **路径抽象**。现有 4500 行脚本里约 48 处内联 `/data/adb/nasbak`，
   要全部收进 `bin/lib-path.sh` 的变量，App 版配置才能生效。
2. **二进制装载**。Android 10 起不能 exec `filesDir` 里的可写文件，
   busybox 和 ffmpeg 要以 `lib*.so` 放进 `jniLibs/<abi>/`，
   由系统装到 `nativeLibraryDir` 再执行。

`pack-assets.py` 负责把 `www/ bin/ etc/ httpd.conf` 打成 `assets/runtime.zip`。
zip 不入库，本机生成后再构建。
