# NAS / 闲置电脑版服务端：实施方案

> 编写日期：2026-11-09
> 读者：<your-name>本人。回家照着做，不需要再问。
> 定位：**改造，不是重写。** 业务逻辑一行不动，只解除 Android 绑定。

---

## 0. 结论与工期

| 版本 | 包含 | 工期 |
|---|---|---|
| **最小可用** | 浏览存档、看大图、播视频、收文件、按事件归档 | **2 天** |
| **完整版** | 上面 + 人工判定、缩略图预热、后台守护、回收站、定时清理 | **4–6 天** |
| 加安装包 | 一条命令装完（或 Docker 镜像） | +1–2 天 |

先做最小可用，跑通再补。不要一次改完 32 个脚本。

---

## 1. 目标与非目标

**要的**

- 把现有 `www/` + `bin/` 搬到任意 Linux（Debian/Ubuntu/群晖/树莓派/旧笔记本）上跑起来
- 库房根目录可配置，能指向挂载的大硬盘
- 开机自启、崩溃自动重启
- 数据格式与 K40 完全一致（账本、归档目录结构、sidecar 都不变），**两边的库可以互拷**

**不要的**

- 不做多用户、不做 Web 端登录（沿用两元角色 + PIN）
- 不做迁移工具（先把新库跑起来，老库直接 `rsync` 过去）
- 不在这一轮做 NAS 专属功能（照片墙、地图、转码）

---

## 2. 现状体检（这是"不费力"的依据）

| 指标 | 实测值 |
|---|---|
| 服务端总量 | 4,519 行 / 32 个脚本 |
| 核心业务文件的安卓专有调用 | **0**（archive.cgi、decide.cgi、apply.cgi、thumb.cgi、lib-ledger.sh、make-thumb.sh、move-by-date.sh、media-gc.sh） |
| 安卓专有命令合计 | 18 处，只在 5 个文件：`magnet/cgi-bin/thunder.cgi` 11、`service.d/srv.sh` 3、`bin/thunder-confirm.sh` 2、`service.d/zzz-nasbak.sh` 1、`bin/status-collect.sh` 1 |
| 路径硬编码 | `/data/adb` 134 处（**86 处是变量定义行**）、`/data/media/0` 62 处 |
| 兼容风险 | `date -d` 20 处（GNU date 更宽松，风险低）；无 `sed -i`、无 `grep -P`、无 `readlink -f` |

**核心结论**：真正干活的脚本只依赖 POSIX shell + busybox + awk + ffmpeg。这些 Linux 全有，而且更全。

---

## 3. 目标架构对照

| 环节 | K40（现状） | NAS（目标） | 改动量 |
|---|---|---|---|
| 进程守护 | Magisk `service.d/*.sh` | systemd unit | 重写，约 60 行 |
| 定时任务 | Magisk `crond` + `cron/root` | 系统 `crontab` | 抄过去，改路径 |
| HTTP | busybox httpd :8083 | 同一个 busybox httpd | 启动参数微调 |
| 全盘浏览 | alist :5244 | 官方 Linux 版 alist | 换二进制 |
| 路径根 | `/data/media/0/nasbak` | `/srv/nasbak`（挂载点） | **主要工作量** |
| 保活 | `setprop` / `dumpsys` / `wakelock` | 全部删掉 | 只删不加 |
| 投屏 | scrcpy + adb | **砍掉** | 删 |
| 迅雷/磁力 | 调 Android 应用 | **砍掉**（要下载就用 aria2） | 删 |
| 组网 | Tailscale（app） | Tailscale（官方包，一条命令） | 变简单 |

---

## 4. 实施顺序

### P0 · 路径抽象（在 K40 上做，可回滚）

**为什么先做这个**：它同时解掉架构文档里的待定问题 1（外置卡根路径），做完之后 Android 版能直接把库房放 SD 卡，NAS 版能装任意目录。

**做法**：新增 `etc/nasbak.conf` 和 `bin/lib-path.sh`，让所有脚本从一处取路径。

> **当前状态（2026-11-09）**：`etc/nasbak.conf` 与 `bin/lib-path.sh` 已经建好，
> 并部署到 K40 实测通过——`CONF` 正确读到，`BB` / `FF` 取到配置里的绝对路径，
> `DATA` / `WWW` / `ledger.jsonl` 全部对得上。它们**还没有被任何业务脚本引用**，
> 所以对现有运行零影响。你要做的第一件事是 4.3 的「接进去」。

#### 4.1 `etc/nasbak.conf`（唯一的配置源）

```sh
# nasbak 全局配置。改这里，不要改脚本。
# Android 默认：库房在 /data/media/0/nasbak，程序在 /data/adb/nasbak
# Linux 默认：库房在 /srv/nasbak，程序在 /opt/nasbak

NASBAK_ROOT=/data/media/0/nasbak      # 库房根（inbox / archive / state）
NASBAK_HOME=/data/adb/nasbak          # 程序根（www / bin / logs）
NASBAK_PORT=8083
NASBAK_ALIST_PORT=5244
NASBAK_FFMPEG=/data/adb/nasbak/bin/ffmpeg
NASBAK_BB=/data/adb/magisk/busybox
```

#### 4.2 `bin/lib-path.sh`（关键：保留原有短变量名）

```sh
#!/system/bin/sh
# lib-path.sh — 全部路径的唯一来源
# 用法：在每个脚本开头加一行
#   . "$(dirname "$0")/lib-path.sh"
# 环境变量 NASBAK_CONF 可覆盖配置文件位置。

for _c in "${NASBAK_CONF:-}" "$(dirname "$0")/../etc/nasbak.conf" /etc/nasbak.conf; do
  [ -n "$_c" ] && [ -r "$_c" ] && . "$_c" && break
done

: "${NASBAK_ROOT:=/data/media/0/nasbak}"
: "${NASBAK_HOME:=/data/adb/nasbak}"
: "${NASBAK_PORT:=8083}"

# ↓↓↓ 沿用各脚本原有的短变量名，这样脚本正文一行都不用改
DATA=$NASBAK_ROOT/state
ARC=$NASBAK_ROOT/archive
INBOX=$NASBAK_ROOT/inbox
WWW=$NASBAK_HOME/www
BIN=$NASBAK_HOME/bin
LOGD=$NASBAK_HOME/logs
LEDGER=$DATA/ledger.jsonl
BB=${NASBAK_BB:-busybox}
FF=${NASBAK_FFMPEG:-ffmpeg}

# busybox 不存在时退回系统命令（Linux 上通常不需要）
[ -x "$BB" ] || BB=$(command -v busybox 2>/dev/null || echo busybox)
[ -x "$FF" ] || FF=$(command -v ffmpeg 2>/dev/null || echo ffmpeg)

export NASBAK_ROOT NASBAK_HOME DATA ARC INBOX WWW BIN LOGD LEDGER BB FF
```

> **这一步的价值**：86 处 `VAR=/data/adb/...` 定义行变成"删掉 + 加一行 source"，其余几千行代码完全不动。这是整个方案能压到 2 天的原因。

#### 4.3 改造节奏（不要一次全改）

**第一批（核心 8 个）**

```
bin/lib-ledger.sh
bin/make-thumb.sh
bin/move-by-date.sh
bin/media-gc.sh
www/cgi/archive.cgi
www/cgi/decide.cgi
www/cgi/apply.cgi
www/cgi/thumb.cgi
```

每个文件的改法：

1. 备份：`cp f f.bak-path-$(date +%Y%m%d)`
2. 删掉文件里的 `DATA=...` `ARC=...` `WWW=...` `BB=...` 等定义行
3. 在 shebang 下一行加：`. "$(dirname "$0")/lib-path.sh"`
4. 检查是否有同名不同义的变量（如 `S=/data/adb/srv` 属于服务区，不归 lib-path 管，保留）

**改完立刻验收**（见 4.4），通过再动第二批。

**第二批（外围）**：`ingest-backlog.sh`、`daemon.sh`、`status-collect.sh`、`trash-gc.sh`、`notify.sh`、`vlm_*`

**第三批（不迁移）**：`thunder-*`、`scrcpy-serve.sh` —— NAS 版直接删，Android 版保持原样不动。

#### 4.4 P0 验收清单

在 K40 上跑，逐项打勾：

- [ ] `wget -qO- http://127.0.0.1:8083/cgi/archive.cgi?op=events` 返回事件列表，条目数与改前一致
- [ ] 存档页能打开，缩略图正常显示
- [ ] 点开一个大图，能看、能左右翻页
- [ ] 视频能播
- [ ] 随便挑一个待判文件提交判定，`ledger.jsonl` 末尾多出一行 `arc-move`，文件确实进了 `archive/`
- [ ] `tail -3 state/receipts.jsonl` 有新行
- [ ] 手动删除一张缩略图缓存，访问时能重新生成

**全部通过 = P0 完成，可以开始碰 NAS。**

---

### P1 · Linux 骨架（半天）

#### 5.1 目录

```sh
sudo mkdir -p /opt/nasbak /srv/nasbak/{inbox,archive,state}
sudo rsync -a ./www ./bin ./etc ./httpd.conf /opt/nasbak/
sudo chmod +x /opt/nasbak/bin/*.sh /opt/nasbak/www/cgi/*.cgi
```

#### 5.2 依赖

```sh
# Debian / Ubuntu
sudo apt update
sudo apt install -y busybox ffmpeg rsync cron

# Alpine
apk add --no-cache busybox ffmpeg rsync tzdata coreutils findutils
```

> `busybox` 是硬依赖（httpd + 部分 applet）；`ffmpeg` 用于视频抽帧；`coreutils` 给 GNU 版 `date`/`stat`。

#### 5.3 改 `/etc/nasbak.conf`

```sh
NASBAK_ROOT=/srv/nasbak
NASBAK_HOME=/opt/nasbak
NASBAK_PORT=8083
NASBAK_FFMPEG=/usr/bin/ffmpeg
NASBAK_BB=/usr/bin/busybox
```

#### 5.4 手工起一次，确认能开

```sh
cd /opt/nasbak
sudo busybox httpd -f -p 8083 -h /opt/nasbak/www -c /opt/nasbak/httpd.conf
```

另开一个终端：

```sh
curl -s "http://127.0.0.1:8083/cgi/wizard.cgi?op=state"
curl -s "http://127.0.0.1:8083/cgi/wizard.cgi?op=volumes"
```

- [ ] 两个接口都返回 JSON
- [ ] `volumes` 里能看到挂载的大硬盘，容量正确
- [ ] 首次访问会自动生成 `state/config.json`（老库有 `archive/` 就自动补，不拦人）

---

### P2 · 业务脚本落地（1 天）

`rsync` 把 `bin/` 全量拷过去后，逐个手工跑一遍，看报错：

```sh
# 1. 收取（先造 3 个测试文件，别拿真库试）
mkdir -p /tmp/t && cp 任意3张照片 /tmp/t/
NASBAK_CONF=/etc/nasbak.conf sh /opt/nasbak/bin/ingest-backlog.sh /tmp/t

# 2. 按日期分桶
NASBAK_CONF=/etc/nasbak.conf sh /opt/nasbak/bin/move-by-date.sh

# 3. 缩略图（先 --dry 看计划）
NASBAK_CONF=/etc/nasbak.conf sh /opt/nasbak/bin/make-thumb.sh --dry
NASBAK_CONF=/etc/nasbak.conf sh /opt/nasbak/bin/make-thumb.sh
```

- [ ] 三步都不报错，且 `inbox/2026-xx-xx/` 有文件、`state/thumb/` 有缩略图
- [ ] 账本 `state/ledger.jsonl` 有对应记录

**已知需要留意的三处**

| 位置 | 现象 | 处理 |
|---|---|---|
| `date -d "@$ts"` | GNU date 语法一样，但 `-d` 支持更宽松 | 抽样 3 个不同日期验证输出 |
| `stat -c %s` | Linux 与 toybox 输出一致 | 一般无需改 |
| `df -k` 输出列 | 设备名可能含空格导致列错位 | 已用 `df -kP` 或 `awk 'END{...}'`，跑一次核对容量数 |

---

### P3 · HTTP 与前端（半天）

前端不用改，但要处理两件事：

1. **缓存**：busybox httpd 不对 `.html` 发 `Cache-Control`，浏览器会拿旧页。已在 `index.html` 用 `?v=时间戳` 绕开，NAS 版沿用即可。
2. **alist 端口**：`index.html` 里「文件管理」指向 `//hostname:5244/`，装好 alist 就自动对上。

alist：

```sh
mkdir -p /srv/alist && cd /srv/alist
# 从 github.com/alist-org/alist/releases 下对应架构的包
./alist admin set 你的密码
./alist server
```

- [ ] `:5244` 能打开，能看到 `/srv/nasbak` 目录
- [ ] 面板「文件管理」能跳过去

**裁菜单**：编辑 `www/index.html` 的 `PAGES`，把 `magnet`、`down`、`screen` 三项删掉（它们指向 Android 专属服务）。

---

### P4 · 自启与定时（半天）

#### 6.1 `nasbak-httpd.service`

```ini
[Unit]
Description=nasbak panel (busybox httpd :8083)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=NASBAK_CONF=/etc/nasbak.conf
ExecStart=/usr/bin/busybox httpd -f -p 8083 -h /opt/nasbak/www -c /opt/nasbak/httpd.conf
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
```

#### 6.2 `nasbak-daemon.service`

```ini
[Unit]
Description=nasbak daemon (thumb warmup / gc / patrol)
After=nasbak-httpd.service

[Service]
Type=simple
Environment=NASBAK_CONF=/etc/nasbak.conf
ExecStart=/bin/sh /opt/nasbak/bin/daemon.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
```

#### 6.3 安装

```sh
sudo cp nasbak-httpd.service nasbak-daemon.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nasbak-httpd nasbak-daemon
systemctl status nasbak-httpd --no-pager
```

- [ ] 两个服务都是 `active (running)`
- [ ] `sudo systemctl restart nasbak-httpd` 后页面仍能打开
- [ ] 没插硬盘时服务不崩，插上后能自动识别（`volumes` 里出现）

#### 6.4 crontab

```sh
sudo crontab -e
```

```
*/2  * * * *   NASBAK_CONF=/etc/nasbak.conf sh /opt/nasbak/bin/status-collect.sh
30   4 * * 1   NASBAK_CONF=/etc/nasbak.conf sh /opt/nasbak/bin/media-gc.sh --apply
50   4 * * *   NASBAK_CONF=/etc/nasbak.conf sh /opt/nasbak/bin/trash-gc.sh --apply
```

> 原 `cron/root` 里的 `fixadb-run.sh`、`gyp-backup.sh`、`thunder-*`、`bt-stall.sh` 都不要抄，它们是 Android / 下载场景的。

- [ ] `sudo crontab -l` 能看到三条
- [ ] 手动跑一次 `status-collect.sh`，面板状态卡有数字

---

### P5 · 联调验收（1–2 天）

按用户视角走一遍，这是唯一算数的验收：

- [ ] **手机装 APK，选「看另一台手机上的照片」，填 NAS 的 `IP:8083`**，能进面板
- [ ] 存档页按年折叠，事件能展开，缩略图不糊
- [ ] 大图能放大、能左右翻，视频能播
- [ ] 「按存入 / 按拍摄」两种分组切换正常
- [ ] 判定页能提交，40 条批量在 1 秒内完成
- [ ] 归档后文件真的进了 `archive/YYYY-MM/事件名/`，`_event.json` 在
- [ ] 浏览器「文件管理」能进 alist，能下载原图
- [ ] 断电重启后，两个服务自动起来，页面能开
- [ ] 拔掉硬盘，面板不崩；插回后 `volumes` 恢复

---

## 7. 功能裁剪清单

| 项目 | 处理 | 说明 |
|---|---|---|
| `magnet/`（磁力搜索） | 删目录 + 删菜单 | 依赖 Android 迅雷 |
| `ariang-setup.html`、`srv/aria2*` | 删或保留自用 | NAS 上要用 aria2 就重配一份 conf |
| `screen.html`、`scrcpy.cgi`、`srv/scrcpy-server.jar` | 删 | 投屏是"看手机屏幕"，NAS 无意义 |
| `bin/thunder-*.sh` | 删 | 同上 |
| `bin/status-collect.sh` 里的 `dumpsys` 分支 | 注释掉 | Linux 没有 `dumpsys`，电量温度取不到就留空 |
| `service.d/*.sh` | 不迁移 | 由 systemd 取代 |
| `httpd.conf` | 保留 | busybox httpd 通用 |

---

## 8. 如果只有两天（最小路径）

砍到这个范围，2 天能跑：

1. P0 只改 5 个文件：`lib-ledger.sh`、`move-by-date.sh`、`archive.cgi`、`thumb.cgi`、`make-thumb.sh`
2. P1 + P3 全做
3. P2 只跑 receipt / 分桶 / 缩略图（判定和归档留到第二轮）
4. P4 只做 httpd 一个服务，daemon 用 `nohup` 顶着
5. `decide.cgi` / `apply.cgi` 留空实现，判定页先只读

这样能实现"手机能看到电脑上的照片"，价值已经成立。

---

## 9. 风险与回退

| 风险 | 概率 | 应对 |
|---|---|---|
| 某个 CGI 依赖 toybox 特有行为 | 中 | `bash -x` 跑一遍，报错那行换等价写法 |
| `awk` 版本差异导致账本解析错 | 中 | 迁移前备份 `ledger.jsonl`，用同一份账本在两边跑 `archive.cgi` 对比输出 |
| busybox httpd 并发不足 | 低 | NAS 上单线程够用；不够就换 nginx + fcgiwrap |
| 权限：CGI 以 root 跑有风险 | 中 | 后续可降到专用用户 + 库房组权限，先跑通再收紧 |
| 改坏 K40 现有环境 | 中 | P0 每批改动前 `cp .bak-path-日期`，出问题整体回滚这批文件 |

**回退口诀**：任何一步不对，先 `cp` 回 `.bak-path-*`，重启 httpd，确认恢复原状，再继续。不要在坏状态下往下走。

---

## 10. 组网那一环：建议先不做

给亲戚朋友用时，Tailscale 是整条链路最脆的一环——要 Google / Microsoft / GitHub 账号登录，应用商店也不一定搜得到。做完很可能发现没人装成功。

**第一版建议**：组网做成"可选、默认跳过"，局域网能跑就算交付。

等真有人抱怨"在外面看不到"，再从两个方向补：

| 方案 | 优点 | 代价 |
|---|---|---|
| 只做局域网 | 零配置 | 出门看不到 |
| 国内可用的组网（蒲公英 / 贝锐） | 注册门槛低 | 装它的客户端，可能有额度限制 |
| 自有公网 IP + frp | 完全自主 | 需要公网 IP，配置重 |

APK 里向导第②步已经按"可跳过"设计，这一版不用改。

---

## 11. 附：批量路径替换的用法

只在确认配置文件与 `lib-path.sh` 都没问题之后再用，**先 dry-run**。

```sh
# 看哪些行会被动到（不修改文件）
grep -rln '^DATA=\|^ARC=\|^WWW=\|^BB=\|^LOGD=' bin www/cgi

# 备份
mkdir -p _bak-path && for f in $(grep -rln '^DATA=' bin www/cgi); do
  cp "$f" "_bak-path/$(basename "$f").bak"
done

# 人工逐个改：删定义行 + 加 source，比 sed 安全
```

**不建议**用 `sed -i` 批量替换 `/data/adb`：其中 `S=/data/adb/srv`（服务区）、`/data/adb/magisk/busybox`（magisk 路径）语义不同，机械替换会误伤。

---

## 12. 做完之后

- 把这份文档的状态改成"已实施"，记录实际耗时与遇到的差异
- 若 Linux 版稳定，再回头决定 `app/hub`（手机内置服务）还要不要做
- 两边的库结构一致，随时可以 `rsync -a --delete` 互相搬，不必写迁移工具

---

**卡住的时候**：把报错原文、执行的命令、`/etc/nasbak.conf` 内容贴回来，按错误定位，不要在没看懂的情况下改脚本。
