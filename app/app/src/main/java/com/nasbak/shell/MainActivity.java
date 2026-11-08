package com.nasbak.shell;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.DownloadManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.text.InputType;
import android.util.Log;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.ConsoleMessage;
import android.webkit.CookieManager;
import android.webkit.DownloadListener;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceResponse;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ProgressBar;
import android.widget.Toast;

/**
 * NasBak 壳：把 K40 上的 8083 面板装进一个原生 WebView。
 *
 * 设计取舍：
 * - 不引入 AndroidX，只用系统 Activity/WebView，构建依赖降到 0；
 * - 地址存 SharedPreferences，加载失败页给「设置地址」入口，不额外占屏幕空间；
 * - 面板本身是同源 iframe 结构，直接加载 index.html 即可。
 */
public class MainActivity extends Activity {

    private static final String TAG = "NasBak";
    private static final String PREF = "nasbak";
    private static final String KEY_URL = "url";
    // 默认走回环：面板就跑在本机上。注意不能用本机的 Tailscale IP
    // （100.64.x.x），实测 Android 的 VPN 不回环到自身，请求直接超时。
    // 若装到别的手机，用「设置地址」填 K40 的局域网 IP 或 Tailscale IP。
    private static final String DEFAULT_URL = "http://127.0.0.1:8083/index.html";
    private static final int REQ_FILE = 1001;

    private WebView web;
    private ProgressBar bar;
    private String curUrl;
    private ValueCallback<Uri[]> filePathCb;

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
                    showErrorPage();
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
        curUrl = sp.getString(KEY_URL, DEFAULT_URL);
        web.loadUrl(curUrl);
    }

    /** 拦截自定义 scheme；http/https 一律留在 WebView 内 */
    private boolean handleUrl(String url) {
        if (url == null) return false;
        if (url.startsWith("nasbak://")) {
            askUrl();
            return true;
        }
        return false;
    }

    private void showErrorPage() {
        String html = "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
                + "<body style='margin:0;height:100vh;display:flex;align-items:center;justify-content:center;"
                + "background:#0f1115;color:#c9ced6;font:15px/1.7 system-ui,sans-serif'>"
                + "<div style='text-align:center;padding:24px'>"
                + "<div style='font-size:34px;margin-bottom:10px'>&#9888;</div>"
                + "<div style='font-weight:600;margin-bottom:8px'>连不上面板</div>"
                + "<div style='font-size:13px;color:#8b929c'>" + curUrl + "</div>"
                + "<div style='font-size:12.5px;color:#6b727c;margin-top:10px'>"
                + "确认手机在局域网或 Tailscale 内，且 8083 服务在运行</div>"
                + "<a href='nasbak://settings' style='display:inline-block;margin-top:20px;padding:10px 20px;"
                + "background:#2563eb;color:#fff;border-radius:8px;text-decoration:none;font-size:14px'>"
                + "设置地址</a></div></body>";
        web.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
    }

    private void askUrl() {
        final EditText et = new EditText(this);
        et.setInputType(InputType.TYPE_TEXT_VARIATION_URI);
        et.setText(curUrl);
        et.setSelection(et.getText().length());
        new AlertDialog.Builder(this)
                .setTitle("面板地址")
                .setView(et)
                .setPositiveButton("保存并打开", (d, w) -> {
                    String u = et.getText().toString().trim();
                    if (u.isEmpty()) return;
                    if (!u.startsWith("http://") && !u.startsWith("https://")) u = "http://" + u;
                    curUrl = u;
                    getSharedPreferences(PREF, MODE_PRIVATE).edit().putString(KEY_URL, u).apply();
                    web.loadUrl(u);
                })
                .setNegativeButton("取消", null)
                .show();
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
        if (keyCode == KeyEvent.KEYCODE_BACK && web.canGoBack()) {
            web.goBack();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}
