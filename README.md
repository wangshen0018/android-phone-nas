# Android 旧手机改造成家庭 NAS

用一台淘汰的 Android 手机（Magisk root）当 7×24 常驻家庭文件服务器：
自动备份手机照片、按拍摄日期归位、AI 判读画面内容、人审后归档、同步到云盘，
带一个 Web 管理面板。

> 本项目从一台真实在跑的生产设备上整理而来。**代码不含任何凭据与真实地址**，
> 所有 IP / 密钥 / 个人目录名都是占位符。

---

## 为什么用旧手机

| 方案 | 成本 | 功耗 | 门槛 |
|---|---|---|---|
| 群晖/威联通 | 1500+ | 20–40W | 要买 |
| 树莓派 + 硬盘盒 | 600+ | 5–10W | 要折腾 Linux |
| **淘汰 Android 手机** | **0** | **1–3W** | 要 root |

旧手机有三个天然优势：自带电池（等于免费 UPS）、自带屏幕触控（本地排障）、
已有 WiFi 和存储。问题也很明确——**它不是为常驻服务设计的**：

- 系统会杀后台、会深度休眠、会断 WiFi
- 电池长期满电会鼓包
- root 环境是 toybox + busybox 的残缺组合，大量 GNU 工具缺失
- 无线 adb 端口重启后会变

这套代码就是把这三个坑全部填平之后的样子。

---

## 架构

```
┌─────────────┐   WiFi 回家   ┌──────────────────┐   定时    ┌─────────┐
│  拍照手机    │ ─增量备份──→ │    NAS 手机       │ ─同步──→ │  云盘   │
│             │              │   (Magisk root)  │           │         │
└─────────────┘              │                  │           └─────────┘
                             │  inbox/          │
                             │   ↓ 按日期归位    │
                             │   ↓ VLM 判读     │
                             │   ↓ 人工确认      │
                             │  archive/        │
                             │  8083 Web 面板    │
                             └──────────────────┘
```

**处理流水线**

```
拍照手机上传 → inbox/<固定目录>
   ↓ move-by-date.sh    按拍摄日期归位到 inbox/<YYYY-MM-DD>/（顺手统计来源：相机 9 · 扫描 2）
   ↓ judge.sh --ingest  新文件入 pending.queue
   ↓ judge.sh --judge   VLM 判读（夜间窗口）
   ↓ make-thumb.sh      ffmpeg 批量生成 320px 缩略图（图片和视频）
   ↓ 人工判定（web 面板）
   ↓ apply.cgi          归档到 archive/<YYYY-MM>/<事件夹>/
   ↓ gyp-backup.sh      rclone 同步到云盘
   ↓ notify.sh          有新文件才推微信，避免每轮骚扰
```

**Web 面板（8083，单 httpd 同源）**

| 入口 | 功能 |
|---|---|
| 文件判定 | 缩略图列表、就地放大、视频页内播放（封面由服务端预生成）、分类/事件夹选择、顶部操作记录条可撤销 |
| 存档管理 | 类型 / 年份逐级折叠、事件内可按**存入时间**或**拍摄时间**分批切换、图片全屏放大、视频封面与页内播放、单列/双列、批量重命名/移动、回收站 |
| 磁力搜索 | 多站聚合搜索，一键推给 aria2 |
| 下载管理 | AriaNg（RPC 免配置预置） |
| 网络服务管理 | 服务状态、访问入口、定时任务 |
| 统计 | 判读进度、分类分布、存储构成、操作台账 |
| 手机屏幕 | 网页里实时看屏幕并反向操作（详见附录，按需启停） |
| 文件管理 | 直嵌 alist（5244），浏览/上传/下载/在线预览/分享，WebDAV 同端口 `/dav` |

---

## 部署

### 前置

- Android 手机已 root（Magisk）
- 无线 adb 可用：`adb connect <IP>:5555`
- 宿主机有 `adb` 与 `powershell`

### 步骤

```powershell
$env:ADB_DEVICE = "<NAS_LAN_IP>:5555"
.\deploy\deploy.ps1
```

脚本做的事：推到 `/data/local/tmp/stage` → `su -c` 复制到位 → 统一 chmod →
重启 httpd / crond / daemon → 逐页 curl 验收。

**为什么不能直接 `adb push` 到 `/data/adb`**：那是 root 所有、权限 700，
`adb push` 会 `Permission denied`。必须中转。

### 必须自己填的

| 项 | 位置 | 说明 |
|---|---|---|
| aria2 RPC 密钥 | `srv/aria2.conf` → `rpc-secret=CHANGE_ME` | 改成随机串 |
| VLM API Key | `/data/adb/srv/data/*.key` | 权限 600，纯 key 字符串 |
| 云盘 | `gyp/gyp-backup.sh` + `rclone.conf` | 自行 `rclone config` |
| 备份源目录 | `bin/` 与 `service.d/` 顶部路径常量 | 改成你的上传目录 |

`_dup_backup` 必须始终排除（见坑 22）。

---

## 三十五个坑

这部分是真正花时间的地方。

### shell 与工具链

**1. `adb shell "..."` 里的 `$()`、`|`、`{}` 会被宿主机 shell 抢先解析**

PowerShell 同样。**所有脚本一律本地写好 → `adb push` → `su -c 'sh /path/x.sh'`**，
不要用 `adb shell "一行命令"` 处理复杂逻辑。

**2. Android 的 `/system/bin/sh` 是 mksh，不是 bash**

缺 `<(...)` 进程替换、`find -exec {} +`、部分 `[[ ]]` 语义，也没有 `tac`。

```sh
# 倒序读文件：awk 先缓存全部行
awk '{l[NR]=$0} END{for(i=NR;i>=1;i--) print l[i]}' file.jsonl
```

**3. 中文脚本必须写成 UTF-8 无 BOM**

PowerShell 管道默认 GBK，会把中文注释写成乱码，`sh` 直接报错：

```powershell
[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($false)))
```

**4. 但 PowerShell 脚本自己必须带 BOM**

PS 5.1 读无 BOM 的 UTF-8 会把中文注释解析成语法错误。
`.ps1` 用 `UTF8Encoding($true)`，`.sh` 用 `UTF8Encoding($false)`。**两者相反。**

**5. Git 会把 `*.sh` 的 LF 变 CRLF，设备上直接语法错炸**

```gitattributes
*.sh   text eol=lf
*.cgi  text eol=lf
*.conf text eol=lf
```

**6. busybox `sed` 匹配不了 UTF-8 中文的 `.*`**

```sh
# 错：永远匹配不到
sed -n 's/.*"folder":"中文字段".*/\1/p' file

# 对：grep -F 定位行，再对 ASCII 字段做 sed/cut
evline() { grep -F "\"folder\":\"$1\"" "$DATA/events.jsonl" | head -1; }
```

**7. `chmod -R 644` 会把文件改成 0 权限**

busybox chmod 把 `644` 当模式运算，不是八进制字面量。必须写 `chmod -R 0644`。

**8. `ps -A | grep xxx` 在这类机器上找不到进程**

必须遍历 `/proc/*/cmdline`：

```sh
for p in /proc/[0-9]*/cmdline; do
  c=$(tr '\0' ' ' < "$p" 2>/dev/null)
  case "$c" in *目标*) FOUND=$(basename "$(dirname "$p")") ;; esac
done
```

**9. `nohup ... &` 在 `su -c` 下会随 shell 退出被杀**

```sh
setsid nohup sh /path/daemon.sh >> /log 2>&1 < /dev/null &
```

**10. `crond` 不在 PATH**

```sh
# 错：crond: inaccessible or not found，还会连已有任务一起搞死
crond -c /path

# 对：用模块自带的 busybox
/data/adb/modules/<模块>/busybox/crond -c /path
```

**11. mksh 的 `$(( ))` 是 32 位有符号**

```sh
TOTB=$(( $TOT * 1024 ))      # 错：225G*1024 ≈ 2.3e11 溢出成负数
TOTB=$(echo "$DF" | awk '{printf "%.0f", $2*1024}')   # 对：awk 双精度
```

**12. `printf ']}\n'` 之后再 `tail -c 1` 校验末字节，永远失败**

`tail -c 1` 拿到换行符，命令替换又把行尾换行剥掉 → 空串，比较恒为假。

```sh
printf ']}'                                 # 别写结尾换行
[ "$(tail -c 2 "$TMP")" = "]}" ] && mv ...  # 比对最后两字节
```

**13. 从设备往回取文件别用 `exec-out` 重定向，走 `/sdcard` 中转 + md5**

`adb exec-out "su -c 'cat 文件'" > local` 在 Git Bash / MSYS 下会把 `\n` 变成 `\r\n`：
一个 50 行的脚本涨 50 字节，行尾全被污染，回灌回去直接 `bad interpreter`。
更坑的是字节增量不一定等于行数（HTML 那种长文件对不上），肉眼完全看不出来。

```sh
# 对：设备端先拷到 /sdcard（FUSE 视图，pull 不做任何转换）
adb shell su -c 'cp /data/adb/nasbak/www/x.html /sdcard/_sync/; chown -R media_rw:media_rw /sdcard/_sync'
adb pull /sdcard/_sync/. ./tmp/
md5sum ./tmp/x.html   # 必须和设备端 md5sum 一致再入库
```

顺带：`/data/adb/**` 属 root，`adb shell ls` 直接 Permission denied，一律 `su -c` 包起来。

### HTTP 与 CGI

**14. busybox httpd 是单线程的**

CGI 里用 `nc` 探测自己所在端口会**死锁**——请求占着唯一的线程等自己响应。

```sh
nc -z 127.0.0.1 8083              # 错：8083 的 CGI 探测 8083
timeout 3 nc -z 127.0.0.1 5244    # 对：同端口靠进程检测，其他端口加 timeout
```

**15. CGI 里 `exit 0` 在 `for` 循环内会退出整个脚本**

```sh
for x in ...; do
  if [ 条件 ]; then FOUND=1; break; fi    # 不是 exit 0
done
```

**16. CGI 里做重活会拖垮整个 httpd**

遍历 3000 个文件、调 VLM、`du -sb` 大目录——全部移到后台采集脚本，
CGI 只读缓存 JSON。实测 `status.cgi` 从 15 秒降到毫秒级。

**17. 放在 web 根里的 `.sh` 会被当静态文件下载**

含密钥的库必须放 web 根**之外**，CGI 用绝对路径引用。
用 `$SELF_DIR/../../lib/x.sh` 这种相对路径很危险——目录结构一变就跑到 web 根里。

**18. URL 编码的中文必须自己解码**

busybox 没有现成工具，逐字节 `printf`：

```sh
urldec() {
  _s="$1"; _out=""
  while :; do
    case "$_s" in
      *%[0-9a-fA-F][0-9a-fA-F]*)
        _pre="${_s%%\%*}"; _r="${_s#*\%}"
        _hx=$(printf '%s' "$_r" | cut -c1-2)
        _ch=$(printf "\\x$_hx" 2>/dev/null)
        _out="$_out$_pre$_ch"; _s=$(printf '%s' "$_r" | cut -c3-)
        ;;
      *) _out="$_out$_s"; break ;;
    esac
  done
  printf '%s' "$_out"
}
```

**19. busybox httpd 不认 `DirectoryIndex`，根路径固定是 `index.html`**

想让 `/` 是导航页，就得让 `index.html` 本身是导航页，其他页面改名。

### 文件与 ID

**20. `id = sha256(rel + ":" + size)` 会因文件移动而改变**

`inbox/Camera/a.jpg` → `inbox/2026-10-20/a.jpg`，id 就变了。
需要稳定引用时另做与路径无关的 mid：

```sh
mid = sha256("YM/F/NAME:SIZE")[0:16]    # 移动后仍可用
```

**21. 用 `find | wc -l` 算「待判」会把已出队的历史文件算进去**

进度条永远停在同一数字。改为读真正的队列文件行数。

**22. 数据源遗留文件是隐形炸弹**

换成「队列」架构后，只替换了判读链路，忘了改页面构建函数——
它还在遍历上一代留下的 `loc-*.tsv`（3041 个），其中 1472 条指向去重副本，
于是**已归档的文件反复出现在待判列表**。

> 教训：换架构时把所有读该数据的地方一次性找全，`grep -rn` 一遍。

**23. 去重目录必须处处显式排除**

`_dup_backup/` 里的文件**永远存在**（它们就是被留在那儿的重复件）。
任何「文件还在就列出」的逻辑都会把它们永久留在待判列表，还会反复触发 AI 计费。

### 进程与状态

**24. 电池长期满电会把电池撑鼓**

部分 MIUI/澎湃OS 有 `battery_charging_enabled` 节点：

```sh
echo 0 > /sys/class/power_supply/battery/battery_charging_enabled   # 停充
```

实测写 0 后电流从 -1.33A 翻到 +0.20A，且**能稳定保持**。
比 `input_suspend` 好（后者内核约 3.5s 自动清零，必须 2s 重写）。
策略：`>=80%` 停充，`<=65%` 恢复，`>45C` 停充。

**25. WiFi 在深度休眠时会挂起，且不自愈**

```sh
echo <名字> > /sys/power/wake_lock     # 阻止 suspend
dumpsys deviceidle disable             # 关 doze
settings put global stay_on_while_plugged_in 3
```

**26. 重启后无线 adb 端口会变，甚至 adb 开关被系统关掉**

定时自愈：

```sh
settings put global adb_enabled 1
setprop persist.adb.tcp.port 5555
setprop service.adb.tcp.port 5555
stop adbd; sleep 1; start adbd
```

判活不要用 `adb devices`，看 `/proc/net/tcp` 里有没有 `:15B3`（5555 的 hex）。

**27. 别刷机**

- `ro.boot.flash.locked=1` → 要解 BL 锁
- 换 ROM 必须 `format data` → 丢掉 `/data/misc/adb/adb_keys`
- 那个文件是**唯一**的 adb 授权通道。屏幕坏了（常驻机很常见）就彻底失联

**28. 屏保别让屏幕真灭**

```sh
settings put system screen_off_timeout 2147483647
```

旧 LCD 常亮几瓦电，比失联后排查的成本低得多。

### 判断与成本

**29. AI 判读必须只跑「新增」，且要能重判**

- 用 `mtime` 窗口卡住历史积压。手机照片的 mtime == 拍摄时间，所以窗口语义精确。
- 熔断（连续失败）时**不要**写结果文件，否则该文件永久无法重判。
- 失败计数必须是「连续」的，成功一次即归零。

**30. 视频不要送 VLM**

一帧画面判不出内容，纯烧钱。按扩展名直接归类，描述写「视频 N MB」。

**31. 成本要先算**

单图 2–6 秒 API 调用，几百张就是真金白银。先小批量试模型价格，
再决定窗口多大、要不要降级到更小的模型。

### 存档与媒体

**32. `busybox httpd` 不认 CGI 的 `Status:` 头**

想在 CGI 里做重定向（比如生成封面后 302 跳到静态图），输出 `Status: 302 Found` 加 `Location:` ——
**httpd 把它当普通响应头原样吐出去**，状态行仍是 `200 OK`、body 为空，浏览器不会跟跳，图永远不出来。

实际收到的响应长这样：

```
HTTP/1.1 200 OK
Status: 302 Found
Location: /thumb/xxxx.jpg
Content-Length: 0
```

正确做法是 CGI **直接输出内容**：

```sh
printf 'Content-Type: image/jpeg\r\nContent-Length: %s\r\n\r\n' "$(stat -c %s "$F")"
cat "$F"
```

错误分支也别指望 404 —— 直接返回非图片内容，让 `<img>` 的 `onerror` 兜住就行。

**顺带一个反直觉现象**：静态 `.mp4` 的普通 GET 给的是 `video/mp4`，
但浏览器发 `Range` 请求（`206`）时 `Content-Type` 会变成 `text/html`。
实测 Chrome/Edge 照样能播（`readyState=4`、`canplay`、`duration` 正确），所以不用特殊处理；
但排查视频问题时别被这个头带偏。

**33. 网格里千万别直接放原图**

这条是「页面加载特别慢」最常见的真凶，而且看不出是代码问题——因为代码确实没错。

实测数据：一个事件夹 34 张照片共 **158.6 MB**，平均 4.7 MB/张；
而缩略图格子只有 112px 宽。等于拿 4000px 的原图去填 112px 的洞，白白多传 350 倍。

```html
<!-- 错：直接拉原图 -->
<img src="/media/<id>.jpg" loading="lazy">
```

改成服务端生成 320px 缩略图后，单张 **9.2 KB**（1/354），整页从 158 MB 降到 450 KB：

```sh
ffmpeg -v error -i "$SRC" -frames:v 1 -vf "scale='min(320,iw)':-2" -q:v 5 -y "$THUMB/$id.jpg"
```

三条配套原则：

- **`loading="lazy"` 救不了你**。它只管「什么时候开始下载」，不管「下载多大」。
- **全屏预览才用原图**，而且是先把缩略图铺上去、原图在后台加载完再替换，
  否则点开要空屏一两秒。
- **视频不要靠 `<video preload>` 抽首帧**。那是把 10 MB+ 整个读一遍，
  单线程 httpd 直接堵死；用同一套服务端缩略图逻辑抽一帧即可。

**34. 界面「切模式」提前 return，忘了刷新按钮状态**

判定页的归档抽屉有两个模式：默认「归入已有」和「新建事件」。
`renderTiles()` 处理新建模式时是这样写的：

```js
if(mode==='new'){ tilesEl.style.display='none'; newPanel.style.display=''; return; }
```

问题在最后那个 `return`——它把后面的 `updStat()` 一起跳过了。

而 `updStat()` 不只是改一行字，它还管**按钮可用性**：
「归入已有」下没选事件时会把「确认归档」设成 `disabled`。
于是从默认模式切到「新建事件」、主题都填好了，按钮还是灰的，
`onclick` 根本不触发，用户看到的就是「点了完全没反应」。

更坑的是 `.am-ok:disabled{opacity:.5}` 在蓝色底上几乎看不出来，
按钮外观和能点时几乎一样。

先看截图底部那句「请点选一个事件」才反应过来：**这是上一个模式的文案，
说明 `updStat()` 压根没跑**。

规则：

- 模式切换里每一个提前 `return` 的分支，都要检查**跨模式共享的 UI 状态**
  有没有跟着刷：按钮 `disabled`、底栏提示、面包屑、标题。
- 视觉上分不清「禁用 / 可用」的按钮，是这类 bug 的温床；
  宁可让禁用态更明显（降饱和度 + 禁止光标），也别让它长得像能点。

**35. 一次请求一条判定，会被 CGI 的进程开销拖死**

判定页点「确认归档」后进度条走得极慢。用 `decisions.jsonl` 的 `ts` 一算：
**40 条花了 21 秒，0.52 秒/条**。

先测基线：一个「只输出一行」的最小 CGI，**50 ms**。
再测 decide.cgi 单条：**480 ms**。差出来的 430 ms 去哪了？

拆开看，每个动作都不慢：`grep` 一个 370 KB 文件 20 ms、
`sed|sort|wc` 30 ms、空脚本启动 10 ms。
问题是这样的动作有 **近 30 个**——`printf | sed | tr | cut | grep` 每写一处就是一两次 fork，
旧手机上一个 fork + exec 要 10~20 ms，累起来就是那 430 ms。

**注意别先怀疑网络**。一开始看到"规律地 0.5 秒一条"很像 RTT，实测本地同一条链路
最小 CGI 只要 50 ms，才把嫌疑锁回脚本本身。

**也别指望并发**。`busybox httpd` 是单线程，前端开 4 个并发请求只会在服务端排队，
还多付连接开销。唯一的解法是**减少请求数**：

```js
// 每 20 条一个请求，一次 CGI 启动、一次全文件扫描
fetch('cgi/decide.cgi', {method:'POST', body: JSON.stringify({
  ids: batch.map(x=>x.id).join(','),
  cats: batch.map(x=>x.cat||'').join(','),   // 顺带带上分类，省掉一次全文件扫描
  action:'arc', event:evId
})})
```

结果：40 条的设备侧时间戳跨度从 **21 秒**降到 **0 秒**（同一声秒内写完）。

三条配套经验：

- **能一次算完的别循环算**。原来每条 `grep` 一次 analysis.jsonl，
  改成一次 awk 扫完按 id 建映射。
- **能在请求里带的别让服务端查**。前端本来就有每条的 AI 分类，
  传进来就不用后端再扫 370 KB。
- **批量接口必须留单条回退**。整批失败时逐条重试，否则会把"没写进去"报成成功。
- 顺带一个坑：`QUERY_STRING` 在 busybox httpd 的 **POST** 请求下拿不到，
  批量参数得放 body 里；`grep -E '{16}'` 这类区间量词各版本支持不一致，
  id 校验用 shell 的 `case` 更稳。

---

## 附：网页里看手机实时画面（含反向操作）

管理面板上加了一个「手机屏幕」页，直接在页面里显示手机实时画面，
并且鼠标能点、能拖、能打字——相当于把 scrcpy 搬进浏览器。

**关键点：不需要在电脑上跑任何东西，也不需要 HTTPS 和证书。**

链路是这样：scrcpy 内核（`scrcpy-server.jar`）用 `app_process` 起来后，
**它自己就是个 WebSocket 服务器**（监听 8886），node 那层中转完全多余。
所以客户端静态资源直接放 8083 静态目录，浏览器连 `ws://<手机IP>:8886/` 就行，
页面和视频流全部来自手机本身。

```
浏览器 ──┬─ http 8083 ──> busybox httpd（页面 + www/remote/ 客户端）
         └─ ws  8886  ──> scrcpy-server（app_process，H.264 硬编）
```

### 这一段踩过的坑

**坑一：想用 WebCodecs 就必须先上 HTTPS——而且光给子页面加 HTTPS 没用。**

WebCodecs 的 `VideoDecoder` 是 secure context only。更麻烦的是
**iframe 的安全上下文继承自父链**：父页面是 `http://`，里面嵌 `https://` 也不给用。
而跨站 iframe（`http://A` 嵌 `https://B`）还有第三道墙——cookie 要
`SameSite=None; Secure`，WS 握手经常直接 1006。实测过：地址栏直连能出画面，
同样的地址塞进 http 页面的 iframe 就永远停在 `connecting...`，
手机端连编码进程都没起。

绕过去的路子不是加密，是**换播放器**：这个客户端的 MSE（H264 Converter）解码器
不要求安全上下文。于是全部改用 `player=mse`，纯 http、同源 iframe，一次通。

**坑二：`busybox httpd` 做不了 WebSocket 升级。**

所以别想着在 8083 上自己实现 WS 转发。把 WS 留给手机上的 scrcpy-server，
8083 只负责发静态文件，职责反而最清楚。

**坑三：scrcpy 1.19 在 Android 14 上居然能跑。**

2021 年的老内核，本以为要改，实测 `app_process` 直接起来、硬编正常。
但启动参数必须匹配它的协议版本（`1.19-ws8`），版本号写错会静默退出。

### 部署

```sh
adb push srv/scrcpy-server-1.19-ws8.jar /data/local/tmp/
adb shell su -c 'cp /data/local/tmp/scrcpy-server-1.19-ws8.jar /data/adb/nasbak/srv/scrcpy-server.jar'
adb push bin/scrcpy-serve.sh /data/local/tmp/
adb shell su -c 'cp /data/local/tmp/scrcpy-serve.sh /data/adb/nasbak/bin/ && chmod 755 /data/adb/nasbak/bin/scrcpy-serve.sh'
adb shell su -c 'sh /data/adb/nasbak/bin/scrcpy-serve.sh start'
```

`scrcpy-serve.sh` 有 `start` / `stop` / `status` / `ensure`；
`ensure` 会识别「进程在但 8886 没监听」并重启，适合挂 cron 看护。

**默认按需启用，不常驻**：开机自启和 crond 看护都已去掉，
改由 `www/screen.html` 的「启动投屏 / 停止服务」按钮经 `www/cgi/scrcpy.cgi` 触发。
没人看的时候手机不编码、不发热；`start` 约 2.5 秒起来，8886 开始监听。

**开销**：进程在但没人连时 `%CPU 0.0`、内存约 143 MB；编码是硬件 H.264 不占 CPU，
但屏幕常亮 + 长期编码会发热，所以默认就是「看完就停」。

---

## 目录结构

```
/data/media/0/nasbak/
├── inbox/                      待判定区
│   ├── <YYYY-MM-DD>/           按拍摄日期归位
│   ├── Camera/  ...            拍照手机固定上传目标
│   └── _dup_backup/            去重副本（不进云盘、不判读）
├── archive/<YYYY-MM>/<事件夹>/  已归档
├── _media_gc_trash/<YYYYMMDD>/  回收站（按目录名日期保留 30 天，到期由 trash-gc.sh 清）
└── state/
    ├── pending.queue          待判队列  id<TAB>rel
    ├── analysis/<id>.json     AI 判读结果
    ├── analysis.jsonl         审计轨迹
    ├── decisions.jsonl        人工判定
    ├── receipts.jsonl         执行回执
    ├── events.jsonl           事件夹登记
    ├── ledger.jsonl           操作台账 recv/mvdate/arc/dup
    ├── thumb/<id>.jpg         缩略图（图片和视频，长边 320，约 9 KB —— 页面网格只加载这个）
    └── status-cache.json      状态缓存（CGI 只读这个）
```

**台账的意义**：每个文件的来龙去脉记一行。
排查「这文件为什么在待判里」时 `grep` 一下就有答案，不用推理。

**回收站而不是真删**：`mv → _media_gc_trash/<YYYYMMDD>/`，保留 30 天可恢复。
判断陈旧只看**目录名里的日期**，不看文件 mtime（`mv` 保留原 mtime，老照片会立刻被误删）；
目录名解析不出日期的一律保留，宁可占空间也不误删。清理脚本默认干跑，`--apply` 才真删。

---

## 文件清单

| 路径 | 作用 |
|---|---|
| `bin/judge.sh` | 登记新文件 → 消费队列 → VLM 判读 → 重建页面数据 |
| `bin/move-by-date.sh` | 从固定目录按拍摄日期归位到 `inbox/<date>/` |
| `bin/lib-ledger.sh` | 台账库（`ledger_add` / `ledger_find_id` / `ledger_rotate`） |
| `bin/daemon.sh` | 30 分钟循环调度 + 夜间判读窗口 |
| `bin/status-collect.sh` | 后台采集系统状态到缓存 JSON |
| `bin/vlm_classify.sh` | VLM 调用（多模型降级链） |
| `service.d/zzz-nasbak.sh` | 开机自启 httpd + daemon |
| `service.d/srv.sh` | aria2 / alist / AdGuard 自启 + adb 自愈 |
| `www/index.html` | 左侧导航壳 |
| `www/judge.html` | 文件判定页 |
| `www/archive.html` | 存档管理页（类型-年份折叠、存入/拍摄两种分批方式可切换、全屏预览/播放） |
| `www/cgi/archive.cgi` | 存档接口：`list` 事件汇总、`files` 文件清单（带拍摄/存入时间）、改名/移动/删除 |
| `www/cgi/thumb.cgi` | 按 `mid` 出 320px 缩略图（图片缩放 / 视频抽帧），页面网格都走它 |
| `www/cgi/*.cgi` | 判定 / 存档 / 状态接口 |
| `www/cgi/apply.cgi` | 执行判定：`?a=preview` 只统计不动文件，`ids=` 限定范围（裸调会执行整个队列） |
| `www/cgi/undo.cgi` | 操作记录与撤销（`a=last` 取最近 N 条，倒序，60 秒内同类动作合并） |
| `www/cgi/scrcpy.cgi` | 投屏服务按需启停（`a=status/start/stop`） |
| `bin/make-thumb.sh` | 批量生成 320px 缩略图（图片缩放 / 视频抽帧），幂等，daemon 每轮调用 |
| `bin/notify.sh` | 备份完成后的微信推送（PushPlus），读 `notify.conf`，无 token 静默退出 |
| `bin/trash-gc.sh` | 回收站 30 天清理（crond 每天 4:50，默认干跑） |
| `bin/media-gc.sh` | 媒体副本回收（默认干跑，`--apply` 才删） |
| `bin/lib-sidecar.sh` | 副本目录与硬链接辅助 |
| `bin/ingest-backlog.sh` | 一次性补录历史积压（不做常驻） |
| `srv/update-trackers.sh` | 每周刷新 BT tracker 并热改运行中的 aria2 |
| `srv/bt-stall.sh` | 扫 RPC 找卡住的 BT 任务，输出 `bt-stall.json` |
| `bin/thunder-confirm.sh` | 手机迅雷投递后的确认与结果回写 |
| `bin/thunder-sync.sh` | 把迅雷下载完成的文件搬进系统下载目录 `Download/Thunder` |
| `bin/scrcpy-serve.sh` | 投屏服务启停与看护（`start/stop/status/ensure`） |
| `srv/scrcpy-server-1.19-ws8.jar` | scrcpy 内核，自带 WebSocket 服务（8886） |
| `www/screen.html` | 「手机屏幕」页，同源 iframe 直嵌 `/remote/` |
| `www/remote/` | ws-scrcpy 客户端静态资源（约 682 KB） |
| `www/pinyin.js` | 拼音首字母搜索 |
| `deploy/deploy.ps1` | 一键部署 |

---

## 已知限制

- Web 面板**没有鉴权**。只适合纯内网，或前面挂 Tailscale 之类做访问控制。
- **投屏端口 8886 也没有鉴权**，而且权限比面板大得多：连上就能全机操作这台 root 手机。
  同样只能靠网络层控制（内网 / 虚拟组网），绝不要暴露到公网。
- **文件管理用的 alist（5244）是另一套独立登录**，且它的 Local 驱动配置为
  `recycle_bin_path = "delete permanently"` —— 从 alist 删文件**不进**面板的 30 天回收站。
  想可恢复地删，回判定页/存档页操作。
- 只处理图片和视频，其他文件不参与判读。
- 单机单点，手机挂了就是全挂，无冗余。
- 云端同步是 `rclone sync` 单向推送，不做双向。

---

## 许可

MIT。代码供参考，**请自行评估在自己设备上的风险**——
尤其 root 操作、`/sys` 写入、adb 相关部分，写错可能变砖。

关掉手机之前，先确认你知道怎么在没有屏幕的情况下连上去。
