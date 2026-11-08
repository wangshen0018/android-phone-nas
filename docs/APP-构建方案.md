# 不装安卓开发工具，能不能做出 APK

> 实测日期：2026-11-09　设备：Redmi K40 / Android 14
> 前提：本机（Windows）**不安装** Android Studio / Android SDK / JDK / gradle

---

## 结论

**能。** 而且已经做出一个能装的：`com.nasbak.shell`，12.8 KB，
装到 K40 上打开就是 8083 面板（截图见 `docs/APP-构建方案.md` 末尾记录）。

四条路都成立，区别在"能不能长期维护"：

| 路径 | 本机要装什么 | 能产 APK | 可维护 | 建议 |
|---|---|---|---|---|
| **A. 云端 CI 构建**（GitHub Actions） | 什么都不装 | ✅ | ✅ | **推荐**，已跑通 |
| B. 纯 Python 重打包现成 APK | 只需 Python | ✅ | ❌ 只能改壳，改不了逻辑 | 应急用 |
| C. 手机 Termux 上构建 | 手机上装 Termux+JDK | ✅ | 一般 | 完全离线时用 |
| D. 不产 APK（PWA / 主屏快捷方式） | 什么都不装 | ❌ | ✅ | 只是想有图标 |

被排除的是"本机装 SDK"这条路——那正是要避免的。

---

## 一、本机实测基线

```
java         → command not found
javac/keytool→ 无
ANDROID_HOME → 未设置
gradle       → 无
aapt2/apksigner/d8 → 全盘搜索 0 结果
python       → 3.13.14
node         → 22.22.2
```

一台只有 Python 和 Node 的 Windows 机器。

---

## 二、方案 A：云端 CI（已跑通，推荐）

### 原理

APK 的构建需要 JDK + Android SDK + Gradle，这三样都在 GitHub 的托管 runner 上。
本机只负责 **写代码 + git push**，产物用 API 取回。

### 工程结构

```
app/
├── settings.gradle.kts          仓库源 + 根项目名
├── build.gradle.kts             AGP 8.5.2
├── keystore/nasbak.p12          固定签名（首次由 CI 生成后回填）
└── app/
    ├── build.gradle.kts         minSdk 24 / targetSdk 34，零第三方依赖
    └── src/main/
        ├── AndroidManifest.xml
        └── java/com/nasbak/shell/MainActivity.java
.github/workflows/build-apk.yml  手动触发或 app/ 变更时自动构建
```

**刻意不引入 AndroidX**：这个壳只需要系统的 `Activity` + `WebView`，
依赖为 0，构建最快，也不会因版本冲突失败。

### 完整流程（实测耗时）

| 步骤 | 命令 / 动作 | 耗时 |
|---|---|---|
| 改代码 | 本地编辑 | — |
| 推送 | `deploy/push-api.ps1`（Git Data API） | 5 s |
| 构建 | Actions 自动触发 | **60–90 s**（Gradle 缓存命中后） |
| 取产物 | `GET /actions/artifacts/{id}/zip` | 3 s |
| 安装 | `adb install -r app-debug.apk` | 8 s |

改一行代码到手机上能点开，整体约 **2–3 分钟**，全程本机零构建工具。

### 关键：怎么触发和取回

```bash
# 触发（推送即触发；也可手动）
POST /repos/{owner}/{repo}/actions/workflows/build-apk.yml/dispatches  {"ref":"main"}

# 查状态
GET /repos/{owner}/{repo}/actions/runs

# 取产物（需 PAT，302 到 pipelines.actions.githubusercontent.com）
GET /repos/{owner}/{repo}/actions/artifacts/{artifact_id}/zip
```

PAT 需要 `repo` + `workflow` 两个 scope。**没有 `workflow` scope 推不了
`.github/workflows/*.yml`**，会被 GitHub 直接拒绝。

---

## 三、方案 B：纯 Python 重打包现成 APK

原理：APK 就是个 zip，签名是附加物。不改逻辑、只换配置时，**根本不需要编译器**。

1. **改地址/包名**：`AndroidManifest.xml` 是二进制 AXML，其中的字符串在
   字符串池里。**做等长替换**（`http://AAAA...` → `http://BBBB...`）就不影响
   任何偏移量，不用 aapt2。
2. **改 web 资源**：`assets/` 是不压缩存储的，直接替换文件即可。
3. **重签名**：
   - v1（JAR 签名）= `META-INF/MANIFEST.MF` + `CERT.SF` + `CERT.RSA`，
     纯 Python 可写（`hashlib` + RSA 签名 + 手拼 PKCS#7）。
   - Android 11+ 对 `targetSdk >= 30` 强制要求 v2/v3 签名；把模板的
     targetSdk 保持在 29 或以下，仅 v1 也能装。
   - v2/v3 是"APK Signing Block"，格式固定（三段 SHA-256 分块摘要 +
     signing block 插在中央目录前），Python 也能实现，约 200 行。

**局限**：只能在既有 dex 上做文章。想加功能（比如内置 HTTP 服务）
必须换 dex，那就绕回方案 A/C。

---

## 四、方案 C：手机 Termux 构建

K40 本身是 arm64 + root，可以：

```bash
pkg install openjdk-17 aapt2 d8 apksigner   # termux 仓库有 arm64 版
```

然后在本机用 `adb push` 源码过去、`adb shell` 里跑 gradle。
**代价**：占手机 1.5–2 GB，编译速度约为 PC 的 1/5，
且 K40 当前没装 Termux（实测 `ls /data/data/com.termux` 不存在）。

---

## 五、方案 D：不产 APK

面板本身是个网页。

- **Android Chrome**：菜单 →「添加到主屏幕」，得到一个图标，点开是全屏网页
  （需 `display: standalone` 的 manifest 才是真全屏，否则带地址栏）。
- **PWA manifest + Service Worker**：可以做到接近原生，但离线缓存对
  频繁变动的面板意义不大。

零成本，但不是 APK，装不到别的手机的应用列表里。

---

## 六、五个必须知道的坑（都是实测踩的）

### 1. `android-actions/setup-android` 会直接失败

```
Warning: Failed to find package 'tools'
Error: The process '.../sdkmanager' failed with exit code 1
```
新版 cmdline-tools 已经删掉 `tools` 这个包，而这个 action 默认要去装它。
**GitHub 的 ubuntu runner 本来就预装了 SDK**，这一步纯属多余，删掉即可。

### 2. 每次构建签名都不同 → 装不上第二版

```
Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package
com.nasbak.shell signatures do not match newer version]
```
runner 每次都是干净环境，AGP 会**现场随机生成** debug keystore，
于是同一个 App 每次签名都变，只能卸载重装。

解决：把 keystore 固定下来。做法是 CI 首次用 `keytool` 生成，
导出成 artifact，回填进仓库，`build.gradle.kts` 里显式指定：

```kotlin
val fixedKs = rootProject.file("keystore/nasbak.p12")
signingConfigs { if (fixedKs.exists()) create("fixed") {
    storeFile = fixedKs; storePassword = "nasbak123"
    keyAlias = "nasbak"; keyPassword = "nasbak123"; storeType = "PKCS12"
} }
debug { if (fixedKs.exists()) signingConfig = signingConfigs.getByName("fixed") }
```

实测：回填后 `adb install -r` 覆盖安装 **Success**。

### 3. 手机访问不了自己的 Tailscale IP

```
手机内 curl 127.0.0.1:8083        → 200
手机内 curl <K40_TAILSCALE_IP>:8083   → 000（超时）
```
Android 的 VPN 服务不回环到自身地址。所以壳的默认地址必须用
`127.0.0.1`；装到**别的**手机上时才填 K40 的局域网 IP 或 Tailscale IP。

### 4. 首帧没画完就截图 = 假故障

前几次 `screencap` 拿到全黑图，日志里 `onPageFinished` 却是正常的。
WebView 首帧比页面"加载完成"晚几百毫秒到一两秒，**等 10 秒以上再截**。
这次差点误判成渲染 bug。

### 5. 面板在窄屏上会被裁

WebView 里实测：左侧导航固定 208 px，内容区在 393 dp 宽度下只剩一半，
判读卡片右侧的文字和按钮被切掉。原因是页面没有媒体查询，
按桌面布局写死的。

**这不是壳的问题，是页面本身没做移动端适配。** 要真正好用，
得给 `www/*.html` 加 `@media (max-width: 720px)`：导航改成顶部横条或抽屉，
卡片改单列。

---

## 七、当前这个壳能做到什么

| 能力 | 状态 |
|---|---|
| 打开 8083 面板（`127.0.0.1`） | ✅ |
| 全屏无标题栏、顶部 3 dp 进度条 | ✅ |
| 返回键回退页面 | ✅ |
| 连不上时显示错误页 + 「设置地址」 | ✅ |
| 地址持久化（SharedPreferences） | ✅ |
| alist 上传（`onShowFileChooser`） | ✅ 代码就位 |
| 文件下载走系统下载管理器（带 Cookie） | ✅ 代码就位 |
| 前端报错写 logcat（`onConsoleMessage`） | ✅ |
| 图标 | ❌ 用系统默认 |
| 离线缓存 / 深色适配 / 通知 | ❌ 未做 |

**不含**：alist、aria2、tailscale、scrcpy——这些要独立进程，壳里带不动。

---

## 八、如果继续往下做

按性价比排序：

1. **页面加移动端媒体查询**（收益最大，一次改动同时改善浏览器和 App 体验）
2. **应用图标**（一张 512×512 PNG，放进 `res/mipmap-*`）
3. **版本号自动化**（`versionCode` 用 run number，避免覆盖安装时版本回退）
4. **release 构建 + 混淆**（现在 debug 包带 `android:debuggable`，性能与安全都差）
5. **前台服务常驻**（如果想脱离面板单独跑判定，才需要）

前两项半天内能完成，第 1 项建议先做。
