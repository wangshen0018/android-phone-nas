package com.nasbak.shell;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.DownloadManager;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.text.InputType;
import android.util.Log;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.ConsoleMessage;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;

/**
 * Pantry 壳：把库房设备上的 8083 面板装进一个原生 WebView。
 *
 * 设计取舍：
 * - 不引入 AndroidX，只用系统 Activity/WebView，构建依赖降到 0；
 * - 地址存 SharedPreferences，首次用局域网自动查找（Discovery），找不到才让人手填；
 * - 面板本身是同源 iframe 结构，直接加载 index.html 即可。
 */
public class MainActivity extends Activity {

    private static final String TAG = "Pantry";
    private static final String PREF = "nasbak";
    private static final String KEY_URL = "url";
    // 本机当库房时走回环。注意不能用本机的 Tailscale IP（100.64.x.x），
    // 实测 Android 的 VPN 不回环到自身，请求直接超时。
    private static final String DEFAULT_URL = "http://127.0.0.1:8083/index.html";
    private static final int REQ_FILE = 1001;
    private static final int REQ_PERM = 1002;

    private WebView web;
    private ProgressBar bar;
    /** 同步进度条，手动同步时才显示，贴在底部不挡面板 */
    private TextView syncTip;
    private String curUrl;
    private ValueCallback<Uri[]> filePathCb;
    /** 同步进行中，防重入 */
    private boolean syncing;
    /** 权限回来后要接着弹文件夹选择框 */
    private boolean pendingBuckets, pendingBucketsSync;

    /** 正在扫描，防重入 */
    private boolean scanning;
    /** 上次自动重定位的时间，15 秒内不重复扫，避免连环失败时狂扫网段 */
    private long lastRelocateAt;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        FrameLayout root = new FrameLayout(this);
        web = new WebView(this);
        bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setMax(100);
        bar.setVisibility(View.GONE);

        root.addView(web, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        root.addView(bar, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(3)));

        syncTip = new TextView(this);
        syncTip.setBackgroundColor(0xE6202937);
        syncTip.setTextColor(0xFFFFFFFF);
        syncTip.setTextSize(13);
        syncTip.setPadding(dp(16), dp(9), dp(16), dp(9));
        syncTip.setVisibility(View.GONE);
        FrameLayout.LayoutParams tipLp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tipLp.gravity = Gravity.BOTTOM;
        root.addView(syncTip, tipLp);

        setContentView(root);

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        // 面板里有视频预览，必须允许无手势自动播放
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setLoadWithOverviewMode(true);
        s.setUseWideViewPort(true);
        s.setCacheMode(WebSettings.LOAD_DEFAULT);

        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, true);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
                return handleUrl(req.getUrl().toString());
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                Log.i(TAG, "onPageFinished " + url);
            }

            @Override
            public void onReceivedHttpError(WebView v, WebResourceRequest req, WebResourceResponse res) {
                Log.w(TAG, "http " + res.getStatusCode() + " " + req.getUrl());
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest req, WebResourceError err) {
                Log.e(TAG, "onReceivedError " + err.getErrorCode() + " " + err.getDescription()
                        + " " + (req != null ? req.getUrl() : "?"));
                // 只处理主文档失败；子资源 404（缩略图之类）不弹错误页
                if (req != null && req.isForMainFrame()) {
                    // 库房重启后路由器可能换了 IP，静默重扫一次再决定要不要报错
                    autoRelocate();
                }
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView v, int p) {
                bar.setVisibility(p >= 100 ? View.GONE : View.VISIBLE);
                bar.setProgress(p);
            }

            // 前端报错必须能在 logcat 看到，否则黑屏无从下手
            @Override
            public boolean onConsoleMessage(ConsoleMessage cm) {
                Log.i(TAG, "console[" + cm.messageLevel() + "] " + cm.message()
                        + " @" + cm.sourceId() + ":" + cm.lineNumber());
                return true;
            }

            // alist 的上传按钮靠这个回调拉起系统文件选择器
            @Override
            public boolean onShowFileChooser(WebView v, ValueCallback<Uri[]> cb,
                                             FileChooserParams params) {
                if (filePathCb != null) {
                    filePathCb.onReceiveValue(null);
                }
                filePathCb = cb;
                try {
                    startActivityForResult(params.createIntent(), REQ_FILE);
                } catch (Exception e) {
                    filePathCb = null;
                    return false;
                }
                return true;
            }
        });

        // 下载：交给系统下载管理器，带上 Cookie 保持 alist 登录态
        web.setDownloadListener(new DownloadListener() {
            @Override
            public void onDownloadStart(String url, String ua, String cd, String mime, long len) {
                try {
                    DownloadManager.Request r = new DownloadManager.Request(Uri.parse(url));
                    String cookie = CookieManager.getInstance().getCookie(url);
                    if (cookie != null) r.addRequestHeader("Cookie", cookie);
                    r.setNotificationVisibility(
                            DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
                    r.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS,
                            android.webkit.URLUtil.guessFileName(url, cd, mime));
                    DownloadManager dm = (DownloadManager) getSystemService(Context.DOWNLOAD_SERVICE);
                    dm.enqueue(r);
                    Toast.makeText(MainActivity.this, "已加入下载任务", Toast.LENGTH_SHORT).show();
                } catch (Exception e) {
                    Toast.makeText(MainActivity.this, "下载失败：" + e.getMessage(),
                            Toast.LENGTH_LONG).show();
                }
            }
        });

        SharedPreferences sp = getSharedPreferences(PREF, MODE_PRIVATE);
        if (sp.contains(KEY_URL)) {
            curUrl = sp.getString(KEY_URL, DEFAULT_URL);
            web.loadUrl(curUrl);
        } else {
            // 首次打开先问清这台手机的角色，否则装到家人手机上只会看到报错页
            curUrl = DEFAULT_URL;
            showWelcome();
        }

        // 开了备份的手机，每次打开静默增量传一轮。本机就是库房时没必要传。
        if (sp.getBoolean(Backup.KEY_ON, false)
                && Backup.hasPermission(this)
                && !"127.0.0.1".equals(hostOf(curUrl))) {
            web.postDelayed(new Runnable() {
                @Override
                public void run() { startBackup(true); }
            }, 2500);
        }
    }

    // ───────────────────────── 首次引导 ─────────────────────────

    private void showWelcome() {
        String card = "position:relative;display:block;text-decoration:none;color:inherit;"
                + "background:#fff;border:1px solid #dcdfe3;border-radius:10px;"
                + "padding:15px 34px 15px 15px;margin-bottom:11px";
        String arrow = "<span style='position:absolute;right:14px;top:50%;margin-top:-11px;"
                + "color:#c3c9d3;font-size:19px'>&#8250;</span>";

        String html = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
                + "<body style='margin:0;padding:52px 0 0;background:#f6f7f8;color:#1a1d21;"
                + "font:15px/1.65 system-ui,-apple-system,sans-serif'>"
                + "<div style='width:100%;max-width:420px;padding:0 20px;margin:0 auto;box-sizing:border-box'>"
                + "<div style='font-size:19px;font-weight:600;margin-bottom:6px'>先找到家里的库房</div>"
                + "<div style='font-size:13px;color:#6b7280;margin-bottom:20px;line-height:1.7'>"
                + "两台设备连同一个 WiFi，点下面的按钮自动搜。搜不到再手填地址。</div>"

                + "<a href='nasbak://find' style='" + card + "border-color:#bcd3f7;background:#f4f8ff'>"
                + arrow
                + "<div style='font-weight:600;margin-bottom:4px'>自动查找　"
                + "<span style='font-size:11px;color:#2563eb;background:#e3edfd;"
                + "padding:1px 6px;border-radius:4px;font-weight:500'>推荐</span></div>"
                + "<div style='font-size:12.5px;color:#6b7280;line-height:1.6'>"
                + "扫描当前网络，自动认出跑着 Pantry 的那台设备。几秒钟。</div></a>"

                + "<a href='nasbak://settings' style='" + card + "'>" + arrow
                + "<div style='font-weight:600;margin-bottom:4px'>手动填地址</div>"
                + "<div style='font-size:12.5px;color:#6b7280;line-height:1.6'>"
                + "知道库房 IP 时直接输入，形如 192.168.x.x:8083。</div></a>"

                + "<a href='nasbak://local' style='" + card + "'>" + arrow
                + "<div style='font-weight:600;margin-bottom:4px'>这台手机就是库房</div>"
                + "<div style='font-size:12.5px;color:#6b7280;line-height:1.6'>"
                + "本机已经在跑 Pantry 服务时才选。适合长期插电的旧手机。</div></a>"

                + "<div style='font-size:12px;color:#9aa1ab;margin-top:16px;line-height:1.7'>"
                + "自动查找靠扫描 8083 端口识别，不会连到别的设备上，也不上传任何信息。</div>"
                + "</div></body>";
        web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
    }

    // ───────────────────────── 自动查找 ─────────────────────────

    private void showFindingPage() {
        String html = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
                + "<body style='margin:0;height:100vh;display:flex;align-items:center;"
                + "justify-content:center;background:#f6f7f8;color:#1a1d21;"
                + "font:15px/1.7 system-ui,sans-serif'>"
                + "<div style='text-align:center;padding:24px'>"
                + "<div style='width:34px;height:34px;margin:0 auto 16px;border-radius:50%;"
                + "border:3px solid #d5dbe4;border-top-color:#2563eb;"
                + "animation:sp .8s linear infinite'></div>"
                + "<style>@keyframes sp{to{transform:rotate(360deg)}}</style>"
                + "<div style='font-weight:600;margin-bottom:6px'>正在查找库房…</div>"
                + "<div id=msg style='font-size:13px;color:#8b929c'>扫描当前网络</div>"
                + "</div></body>";
        web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
    }

    /**
     * @param silent true = 掉线后的后台重连，不换页面，找到不同地址才切过去
     */
    private void startFind(final boolean silent) {
        if (scanning) return;
        scanning = true;
        if (!silent) showFindingPage();
        final long t0 = System.currentTimeMillis();

        Discovery.scan(new Discovery.Cb() {
            @Override
            public void onProgress(final int done, final int total) {
                if (silent) return;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        try {
                            web.evaluateJavascript(
                                    "var m=document.getElementById('msg');"
                                            + "if(m)m.textContent='已检查 " + done + " / " + total + "';",
                                    null);
                        } catch (Exception ignored) {
                        }
                    }
                });
            }

            @Override
            public void onDone(final List<Discovery.Host> found) {
                scanning = false;
                final long secs = Math.max(1, (System.currentTimeMillis() - t0) / 1000);
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        if (silent) {
                            // 只有找到「和当前不一样」的地址才自动切换；
                            // 同一地址仍失败说明服务真的没起来，报错页给人看
                            String curIp = hostOf(curUrl);
                            for (Discovery.Host h : found) {
                                if (!h.ip.equals(curIp)) {
                                    Toast.makeText(MainActivity.this,
                                            "库房地址已更新为 " + h.ip, Toast.LENGTH_LONG).show();
                                    saveAndLoad(h.url(), true);
                                    return;
                                }
                            }
                            showErrorPage();
                            return;
                        }
                        showFindResult(found, secs);
                    }
                });
            }
        });
    }

    private void showFindResult(List<Discovery.Host> found, long secs) {
        StringBuilder sb = new StringBuilder();
        String head = "width:100%;max-width:420px;padding:0 20px;margin:0 auto;box-sizing:border-box";
        sb.append("<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>")
                .append("<body style='margin:0;padding:52px 0 0;background:#f6f7f8;color:#1a1d21;")
                .append("font:15px/1.65 system-ui,sans-serif'>")
                .append("<div style='").append(head).append("'>");

        if (found.isEmpty()) {
            boolean noNet = !Discovery.hasLocalNet();
            sb.append("<div style='font-size:19px;font-weight:600;margin-bottom:6px'>")
                    .append(noNet ? "这台手机没连 WiFi" : "没找到库房")
                    .append("</div>")
                    .append("<div style='font-size:13px;color:#6b7280;margin-bottom:18px;line-height:1.7'>");
            if (noNet) {
                sb.append("先连上家里的 WiFi，再回来搜一次。用移动数据是找不到的。</div>");
            } else {
                sb.append("扫了 ").append(secs).append(" 秒，当前网络里没有回应。按顺序检查：</div>")
                        .append("<ol style='font-size:13px;color:#4b5563;line-height:1.95;padding-left:20px;margin:0 0 20px'>")
                        .append("<li>两台设备连的是<b>同一个 WiFi</b>（不是一个连 WiFi、一个连 4G）</li>")
                        .append("<li>库房那台开着 Pantry 面板，8083 端口能访问</li>")
                        .append("<li>路由器没开「访客网络」或「AP 隔离」，这两种会挡住设备互访</li>")
                        .append("</ol>");
            }
        } else {
            sb.append("<div style='font-size:19px;font-weight:600;margin-bottom:6px'>找到 ")
                    .append(found.size()).append(" 台</div>")
                    .append("<div style='font-size:13px;color:#6b7280;margin-bottom:18px'>")
                    .append("用时 ").append(secs).append(" 秒，点一下进入</div>");
            for (Discovery.Host h : found) {
                sb.append("<a href='nasbak://use?ip=").append(h.ip)
                        .append("' style='position:relative;display:block;text-decoration:none;")
                        .append("color:inherit;background:#fff;border:1px solid #dcdfe3;")
                        .append("border-radius:10px;padding:14px 34px 14px 15px;margin-bottom:10px'>")
                        .append("<span style='position:absolute;right:14px;top:50%;margin-top:-11px;")
                        .append("color:#c3c9d3;font-size:19px'>&#8250;</span>")
                        .append("<div style='font-weight:600;margin-bottom:3px'>")
                        .append(esc(h.name)).append("</div>")
                        .append("<div style='font-size:12.5px;color:#6b7280;font-family:ui-monospace,monospace'>")
                        .append(h.ip).append(":8083</div></a>");
            }
        }

        sb.append("<div style='display:flex;gap:10px;margin-top:8px'>")
                .append("<a href='nasbak://find' style='flex:1;text-align:center;text-decoration:none;")
                .append("padding:11px 0;border-radius:8px;background:#2563eb;color:#fff;font-size:14px'>再搜一次</a>")
                .append("<a href='nasbak://settings' style='flex:1;text-align:center;text-decoration:none;")
                .append("padding:11px 0;border-radius:8px;background:#fff;color:#374151;")
                .append("border:1px solid #dcdfe3;font-size:14px'>手动填</a>")
                .append("</div></div></body>");

        web.loadDataWithBaseURL(null, sb.toString(), "text/html", "utf-8", null);
    }

    // ───────────────────────── 页面与地址 ─────────────────────────

    private void saveAndLoad(String u) {
        saveAndLoad(u, false);
    }

    private void saveAndLoad(String u, boolean silent) {
        curUrl = u;
        SharedPreferences sp = getSharedPreferences(PREF, MODE_PRIVATE);
        sp.edit().putString(KEY_URL, u).apply();
        web.loadUrl(u);
        // 第一次连上库房的手机才问；自动重连不弹，弹过一次也不再弹
        if (!silent && !sp.contains(Backup.KEY_ON)) {
            web.postDelayed(new Runnable() {
                @Override
                public void run() { askBackupOnce(); }
            }, 900);
        }
    }

    /** 备份默认关。装到家人手机上只是看照片，不能悄悄把人家相册搬走。 */
    private void askBackupOnce() {
        new AlertDialog.Builder(this)
                .setTitle("把这台手机的照片也存进去？")
                .setMessage("开启后先勾选要备份的文件夹（相机、截图、微信各是分开的），"
                        + "只传勾选的那些，以后新增的照片增量补上。只是看家里照片的话选「不用」，"
                        + "以后按返回键随时能改。")
                .setPositiveButton("开启备份", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        getSharedPreferences(PREF, MODE_PRIVATE)
                                .edit().putBoolean(Backup.KEY_ON, true).apply();
                        chooseBuckets(true);
                    }
                })
                .setNegativeButton("只是看看", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        getSharedPreferences(PREF, MODE_PRIVATE)
                                .edit().putBoolean(Backup.KEY_ON, false).apply();
                    }
                })
                .setOnCancelListener(new DialogInterface.OnCancelListener() {
                    @Override
                    public void onCancel(DialogInterface d) {
                        getSharedPreferences(PREF, MODE_PRIVATE)
                                .edit().putBoolean(Backup.KEY_ON, false).apply();
                    }
                })
                .show();
    }

    /** 列出本机相册文件夹让用户勾选；权限没给就先申请，回来接着弹 */
    private void chooseBuckets(final boolean thenSync) {
        if (!Backup.hasPermission(this)) {
            pendingBuckets = true;
            pendingBucketsSync = thenSync;
            requestPermissions(Backup.permissions(), REQ_PERM);
            return;
        }
        toast("正在读相册列表…");
        new Thread(new Runnable() {
            @Override
            public void run() {
                final List<Backup.Bucket> bs = Backup.listBuckets(MainActivity.this);
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() { showBucketDialog(bs, thenSync); }
                });
            }
        }, "pantry-buckets").start();
    }

    private void showBucketDialog(final List<Backup.Bucket> buckets, final boolean thenSync) {
        if (buckets.isEmpty()) {
            toast("没读到相册，确认已经给了相册权限");
            return;
        }
        final SharedPreferences sp = getSharedPreferences(PREF, MODE_PRIVATE);
        final boolean first = !sp.contains(Backup.KEY_BUCKETS);
        final Set<String> saved = Backup.loadBuckets(sp);
        final int n = buckets.size();
        final CharSequence[] labels = new CharSequence[n];
        final boolean[] checked = new boolean[n];
        for (int i = 0; i < n; i++) {
            Backup.Bucket b = buckets.get(i);
            // 两行排版：长文件夹名不再和「N 张 / 大小」挤在一行里折得乱七八糟
            labels[i] = b.name + "\n" + b.count + " 张 · " + Backup.fmtSize(b.bytes);
            checked[i] = saved.contains(b.name);
            // 第一次只预勾相机类文件夹，截图、微信缓存不给默认勾上
            if (first && !checked[i]) {
                String low = b.name.toLowerCase(Locale.US);
                if (low.contains("camera") || low.contains("dcim") || low.contains("相机")) {
                    checked[i] = true;
                }
            }
        }
        AlertDialog.Builder builder = new AlertDialog.Builder(this)
                .setTitle("选要备份的文件夹")
                .setMultiChoiceItems(labels, checked, new DialogInterface.OnMultiChoiceClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int i, boolean isChecked) {
                        checked[i] = isChecked;
                    }
                })
                .setPositiveButton("保存", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        Set<String> sel = new HashSet<String>();
                        for (int i = 0; i < n; i++) {
                            if (checked[i]) sel.add(buckets.get(i).name);
                        }
                        Backup.saveBuckets(sp, sel);
                        if (sel.isEmpty()) {
                            toast("一个都没选，不会传照片");
                            return;
                        }
                        toast("已选 " + sel.size() + " 个文件夹");
                        if (thenSync) startBackup(false);
                    }
                })
                .setNegativeButton("取消", null)
                .setNeutralButton("全选", null);
        final AlertDialog dlg = builder.create();
        // 中性按钮默认点完就关对话框，这里改成「全选」且不关闭
        dlg.setOnShowListener(new DialogInterface.OnShowListener() {
            @Override
            public void onShow(DialogInterface di) {
                dlg.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener(new View.OnClickListener() {
                    @Override
                    public void onClick(View v) {
                        for (int i = 0; i < n; i++) {
                            checked[i] = true;
                            dlg.getListView().setItemChecked(i, true);
                        }
                    }
                });
            }
        });
        dlg.show();
    }

    private void startBackup(final boolean quiet) {
        if (syncing) {
            if (!quiet) toast("正在同步，稍等一下");
            return;
        }
        if (!Backup.hasPermission(this)) {
            requestPermissions(Backup.permissions(), REQ_PERM);
            return;
        }
        if (Backup.loadBuckets(getSharedPreferences(PREF, MODE_PRIVATE)).isEmpty()) {
            if (!quiet) {
                toast("先选要备份的文件夹");
                chooseBuckets(true);
            }
            return;
        }
        if (Backup.originOf(curUrl) == null) {
            toast("还没找到库房");
            return;
        }
        syncing = true;
        final boolean show = !quiet;
        if (show) {
            syncTip.setText("正在读相册…");
            syncTip.setVisibility(View.VISIBLE);
        }
        Backup.run(this, curUrl, new Backup.Cb() {
            @Override
            public void onProgress(final int done, final int total, final int uploaded) {
                if (!show) return;
                // 每 10 张刷一次；几千张的首轮同步不把 UI 线程刷爆
                if (done % 10 != 0 && done != total) return;
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        syncTip.setText("正在传 " + done + " / " + total
                                + "　本次已传 " + uploaded + " 张");
                    }
                });
            }

            @Override
            public void onDone(final int up, final int skip, final int fail, final String err) {
                runOnUiThread(new Runnable() {
                    @Override
                    public void run() {
                        syncing = false;
                        if (show) {
                            web.postDelayed(new Runnable() {
                                @Override
                                public void run() { syncTip.setVisibility(View.GONE); }
                            }, 800);
                        }
                        if (fail > 0) {
                            toast("传了 " + up + " 张，" + fail + " 张失败"
                                    + (err == null ? "" : "：" + err));
                        } else if (up > 0) {
                            toast("已传 " + up + " 张，其余 " + skip + " 张之前传过");
                        } else if (show || fail > 0) {
                            toast("没有新照片要传（已传 " + skip + " 张）");
                        }
                    }
                });
            }
        });
    }

    /** 「备份状态」：传没传、传到哪一步、失败在哪，一眼能看出来 */
    private void showBackupStatus() {
        final SharedPreferences sp = getSharedPreferences(PREF, MODE_PRIVATE);
        boolean on = sp.getBoolean(Backup.KEY_ON, false);
        Set<String> sel = Backup.loadBuckets(sp);
        long at = sp.getLong(Backup.KEY_LAST_AT, 0);
        int up = sp.getInt(Backup.KEY_LAST_UP, 0);
        int skip = sp.getInt(Backup.KEY_LAST_SKIP, 0);
        int fail = sp.getInt(Backup.KEY_LAST_FAIL, 0);
        int total = sp.getInt(Backup.KEY_TOTAL, 0);
        String err = sp.getString(Backup.KEY_LAST_ERR, "");

        StringBuilder sb = new StringBuilder();
        sb.append("备份：").append(on ? "开" : "关").append('\n');
        sb.append("已选文件夹：");
        if (sel.isEmpty()) {
            sb.append("（一个都没选，不会传照片）");
        } else {
            TreeSet<String> sorted = new TreeSet<String>(sel);
            int n = 0;
            for (String s : sorted) {
                if (n >= 8) { sb.append(" 等 ").append(sorted.size()).append(" 个"); break; }
                if (n++ > 0) sb.append("、");
                sb.append(s);
            }
        }
        sb.append("\n\n");
        if (at == 0) {
            sb.append("还没同步过。");
        } else {
            sb.append("上次同步：")
                    .append(new SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.CHINA)
                            .format(new Date(at)))
                    .append('\n')
                    .append("那一轮：传 ").append(up).append(" 张 · 跳过 ").append(skip)
                    .append(" 张 · 失败 ").append(fail).append(" 张");
            if (fail > 0 && err != null && !err.isEmpty()) {
                sb.append('\n').append("第一条失败：")
                        .append(err.length() > 90 ? err.substring(0, 90) : err);
            }
        }
        sb.append("\n累计已传：").append(total).append(" 张");
        sb.append("\n\n取消勾选某个文件夹，库房里已收下的文件不会删，只是不再传新增的。");

        new AlertDialog.Builder(this)
                .setTitle("备份状态")
                .setMessage(sb.toString())
                .setPositiveButton("知道了", null)
                .setNeutralButton("立即同步一次", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) { startBackup(false); }
                })
                .show();
    }

    private void toast(String s) {
        Toast.makeText(this, s, Toast.LENGTH_LONG).show();
    }

    @Override
    public void onRequestPermissionsResult(int req, String[] perms, int[] res) {
        if (req == REQ_PERM) {
            if (Backup.hasPermission(this)) {
                if (pendingBuckets) {
                    pendingBuckets = false;
                    chooseBuckets(pendingBucketsSync);
                } else {
                    startBackup(false);
                }
            } else {
                getSharedPreferences(PREF, MODE_PRIVATE)
                        .edit().putBoolean(Backup.KEY_ON, false).apply();
                toast("没给相册权限，备份没开");
            }
            return;
        }
        super.onRequestPermissionsResult(req, perms, res);
    }

    /** 拦截自定义 scheme；http/https 一律留在 WebView 内 */
    private boolean handleUrl(String url) {
        if (url == null) return false;
        if (url.startsWith("nasbak://local")) {
            saveAndLoad(DEFAULT_URL);
            return true;
        }
        if (url.startsWith("nasbak://find")) {
            startFind(false);
            return true;
        }
        if (url.startsWith("nasbak://use")) {
            String ip = param(url, "ip");
            if (ip != null && ip.matches("[0-9.]{7,15}")) {
                saveAndLoad("http://" + ip + ":" + Discovery.PORT + "/index.html");
            }
            return true;
        }
        if (url.startsWith("nasbak://")) {
            // settings 以及其它未定义入口都进地址输入
            askUrl();
            return true;
        }
        return false;
    }

    /** 掉线后的静默重连：限频，避免连环失败把网段扫爆 */
    private void autoRelocate() {
        String curIp = hostOf(curUrl);
        if ("127.0.0.1".equals(curIp) || curIp == null) {
            // 本机服务没起来，扫网段没意义，直接报错
            showErrorPage();
            return;
        }
        if (scanning) {
            showErrorPage();
            return;
        }
        long now = System.currentTimeMillis();
        if (now - lastRelocateAt < 15000) {
            showErrorPage();
            return;
        }
        lastRelocateAt = now;
        startFind(true);
    }

    private void showErrorPage() {
        String html = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
                + "<body style='margin:0;height:100vh;display:flex;align-items:center;justify-content:center;"
                + "background:#0f1115;color:#c9ced6;font:15px/1.7 system-ui,sans-serif'>"
                + "<div style='text-align:center;padding:24px;max-width:360px'>"
                + "<div style='font-size:34px;margin-bottom:10px'>&#9888;</div>"
                + "<div style='font-weight:600;margin-bottom:8px'>连不上面板</div>"
                + "<div style='font-size:13px;color:#8b929c;font-family:ui-monospace,monospace'>"
                + esc(curUrl) + "</div>"
                + "<div style='font-size:12.5px;color:#6b727c;margin-top:10px'>"
                + "确认两台设备在同一个 WiFi 内，且库房那台的 8083 服务在运行</div>"
                + "<a href='nasbak://find' style='display:inline-block;margin-top:20px;padding:10px 22px;"
                + "background:#2563eb;color:#fff;border-radius:8px;text-decoration:none;font-size:14px'>"
                + "自动查找</a>"
                + "<div style='margin-top:10px'>"
                + "<a href='nasbak://settings' style='color:#8b929c;font-size:13px;text-decoration:none'>"
                + "手动填地址</a>"
                + "<a href='nasbak://local' style='color:#8b929c;font-size:13px;text-decoration:none;"
                + "margin-left:18px'>本机当库房</a>"
                + "</div>"
                + "</div></body>";
        web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
    }

    private void askUrl() {
        final EditText et = new EditText(this);
        et.setInputType(InputType.TYPE_TEXT_VARIATION_URI);
        et.setText(curUrl == null ? DEFAULT_URL : curUrl);
        et.setSelection(et.getText().length());
        new AlertDialog.Builder(this)
                .setTitle("面板地址")
                .setMessage("形如 192.168.x.x:8083，可以不写 http://")
                .setView(et)
                .setPositiveButton("保存并打开", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        String u = et.getText().toString().trim();
                        if (u.isEmpty()) return;
                        if (!u.startsWith("http://") && !u.startsWith("https://")) u = "http://" + u;
                        saveAndLoad(u);
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    // ───────────────────────── 工具 ─────────────────────────

    private static String hostOf(String url) {
        if (url == null) return null;
        try {
            String s = url;
            int i = s.indexOf("://");
            if (i > 0) s = s.substring(i + 3);
            int e = s.indexOf('/');
            if (e > 0) s = s.substring(0, e);
            int c = s.indexOf(':');
            if (c > 0) s = s.substring(0, c);
            return s;
        } catch (Exception e) {
            return null;
        }
    }

    /** 从 nasbak://use?ip=1.2.3.4 里取值 */
    private static String param(String url, String key) {
        int q = url.indexOf('?');
        if (q < 0) return null;
        for (String kv : url.substring(q + 1).split("&")) {
            int e = kv.indexOf('=');
            if (e > 0 && kv.substring(0, e).equals(key)) {
                return kv.substring(e + 1);
            }
        }
        return null;
    }

    private static String esc(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace("\"", "&quot;");
    }

    @Override
    protected void onActivityResult(int req, int res, Intent data) {
        if (req == REQ_FILE) {
            if (filePathCb != null) {
                Uri[] out = null;
                if (res == RESULT_OK && data != null) {
                    if (data.getClipData() != null) {
                        int n = data.getClipData().getItemCount();
                        out = new Uri[n];
                        for (int i = 0; i < n; i++) {
                            out[i] = data.getClipData().getItemAt(i).getUri();
                        }
                    } else if (data.getData() != null) {
                        out = new Uri[]{data.getData()};
                    }
                }
                filePathCb.onReceiveValue(out);
                filePathCb = null;
            }
            return;
        }
        super.onActivityResult(req, res, data);
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            if (web.canGoBack()) {
                web.goBack();
                return true;
            }
            // 面板首页按返回：给一个换库房的出口，否则地址填错后没地方改
            final boolean on = getSharedPreferences(PREF, MODE_PRIVATE)
                    .getBoolean(Backup.KEY_ON, false);
            new AlertDialog.Builder(this)
                    .setTitle("Pantry")
                    .setItems(new String[]{
                            "重新查找库房",
                            "手动填地址",
                            "选择备份文件夹",
                            "备份状态",
                            on ? "关闭本机照片备份（当前开）" : "开启本机照片备份（当前关）",
                            "立即同步一次",
                            "退出"
                    }, new DialogInterface.OnClickListener() {
                        @Override
                        public void onClick(DialogInterface d, int i) {
                            if (i == 0) startFind(false);
                            else if (i == 1) askUrl();
                            else if (i == 2) chooseBuckets(false);
                            else if (i == 3) showBackupStatus();
                            else if (i == 4) {
                                boolean next = !on;
                                SharedPreferences sp = getSharedPreferences(PREF, MODE_PRIVATE);
                                sp.edit().putBoolean(Backup.KEY_ON, next).apply();
                                if (!next) toast("已关闭本机照片备份");
                                else if (Backup.loadBuckets(sp).isEmpty()) chooseBuckets(true);
                                else startBackup(false);
                            }
                            else if (i == 5) startBackup(false);
                            else finish();
                        }
                    })
                    .setNegativeButton("取消", null)
                    .show();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}
