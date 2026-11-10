package com.pantry.server;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.TextUtils;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.File;
import java.io.RandomAccessFile;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/**
 * 库房端界面：开权限、起服务、看地址。
 *
 * 有意保持「一屏能看完」：装到旧手机上插电就不再动它，
 * 需要操作的只有第一次的权限和启动。
 */
public class MainActivity extends Activity {

    private static final String PREF = "pantry";
    private static final String KEY_AUTO = "autoStarted";

    private TextView stateText;
    private Button btnPerm, btnStart, btnStop, btnOpen, btnCopy, btnTick, btnLog;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Runnable refresh = new Runnable() {
        @Override
        public void run() {
            render();
            ui.postDelayed(this, 1500);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(22);
        box.setPadding(pad, dp(36), pad, pad);
        box.setBackgroundColor(Color.parseColor("#F6F7F8"));

        TextView title = new TextView(this);
        title.setText("Pantry 库房");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        title.setTextColor(Color.parseColor("#1A1D21"));
        title.getPaint().setFakeBoldText(true);
        box.addView(title);

        TextView sub = new TextView(this);
        sub.setText("这台手机当库房，照片存在共享存储里。保持插电、连 WiFi，别清后台。");
        sub.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        sub.setTextColor(Color.parseColor("#6B7280"));
        sub.setPadding(0, dp(6), 0, dp(20));
        box.addView(sub);

        stateText = new TextView(this);
        stateText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        stateText.setTextColor(Color.parseColor("#1A1D21"));
        stateText.setBackgroundColor(Color.WHITE);
        stateText.setPadding(dp(15), dp(15), dp(15), dp(15));
        stateText.setLineSpacing(dp(4), 1f);
        box.addView(stateText, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT));

        btnPerm = makeButton("1  开启文件访问权限", "#2563EB");
        btnPerm.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(Env.allFilesSettingsIntent(MainActivity.this));
                } catch (Exception e) {
                    Toast.makeText(MainActivity.this,
                            "打不开设置页，请手动到 设置 → 应用 → 特殊权限 → 所有文件访问 里开启",
                            Toast.LENGTH_LONG).show();
                }
            }
        });
        box.addView(btnPerm, buttonParams(dp(18)));

        btnStart = makeButton("启动 / 重启服务", "#1E3A34");
        btnStart.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (!Env.allFilesAccess(MainActivity.this)) {
                    Toast.makeText(MainActivity.this, "先开文件权限", Toast.LENGTH_SHORT).show();
                    return;
                }
                startServiceCompat(new Intent(MainActivity.this, ServerService.class));
                Toast.makeText(MainActivity.this, "正在启动，几秒后状态会变", Toast.LENGTH_SHORT).show();
            }
        });
        box.addView(btnStart, buttonParams(dp(10)));

        btnStop = makeButton("停止服务", "#6B7280");
        btnStop.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Intent i = new Intent(MainActivity.this, ServerService.class);
                i.setAction(ServerService.ACTION_STOP);
                startServiceCompat(i);
            }
        });
        box.addView(btnStop, buttonParams(dp(10)));

        btnOpen = makeButton("打开面板", "#0F766E");
        btnOpen.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW,
                            Uri.parse("http://127.0.0.1:" + Env.PORT + "/index.html")));
                } catch (Exception e) {
                    Toast.makeText(MainActivity.this, "没有可用的浏览器", Toast.LENGTH_SHORT).show();
                }
            }
        });
        box.addView(btnOpen, buttonParams(dp(10)));

        btnCopy = makeButton("复制局域网地址", "#334155");
        btnCopy.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                String ip = Env.lanIp();
                if (ip == null) {
                    Toast.makeText(MainActivity.this, "没连上 WiFi", Toast.LENGTH_SHORT).show();
                    return;
                }
                String addr = ip + ":" + Env.PORT;
                ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                cm.setPrimaryClip(ClipData.newPlainText("Pantry 地址", addr));
                Toast.makeText(MainActivity.this, "已复制 " + addr, Toast.LENGTH_SHORT).show();
            }
        });
        box.addView(btnCopy, buttonParams(dp(10)));

        btnTick = makeButton("立即归位一次", "#7C3AED");
        btnTick.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                if (!ServerService.RUNNING) {
                    Toast.makeText(MainActivity.this, "服务还没起来", Toast.LENGTH_SHORT).show();
                    return;
                }
                Intent i = new Intent(MainActivity.this, ServerService.class);
                i.setAction(ServerService.ACTION_TICK);
                startServiceCompat(i);
                Toast.makeText(MainActivity.this, "已触发一轮归位，稍后看「上次归位」",
                        Toast.LENGTH_SHORT).show();
            }
        });
        box.addView(btnTick, buttonParams(dp(10)));

        btnLog = makeButton("查看运行日志", "#334155");
        btnLog.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                showLog();
            }
        });
        box.addView(btnLog, buttonParams(dp(10)));

        TextView note = new TextView(this);
        note.setText("家人手机上装另一个 App（Pantry 用户端），首次打开会自动搜到这台设备。\n\n"
                + "照片和账本都在 共享存储/Pantry 下，卸载这个 App 不会删。\n"
                + "重装或升级后运行时脚本会自动换成新版本，不用手工清目录。\n\n"
                + "8083 没有鉴权，只在自己家 WiFi 里用，别做端口映射到公网。");
        note.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        note.setTextColor(Color.parseColor("#9AA1AB"));
        note.setLineSpacing(dp(3), 1f);
        note.setPadding(0, dp(22), 0, 0);
        box.addView(note);

        ScrollView sv = new ScrollView(this);
        sv.addView(box);
        setContentView(sv);
    }

    @Override
    protected void onResume() {
        super.onResume();
        ui.removeCallbacks(refresh);
        ui.post(refresh);
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        }
        // 首次进来且已经有权限，直接起服务，省得用户以为装完就完事
        SharedPreferences sp = getSharedPreferences(PREF, MODE_PRIVATE);
        if (!sp.getBoolean(KEY_AUTO, false)) {
            sp.edit().putBoolean(KEY_AUTO, true).apply();
            if (Env.allFilesAccess(this) && !ServerService.RUNNING) {
                startServiceCompat(new Intent(this, ServerService.class));
            }
        }
    }

    @Override
    protected void onPause() {
        ui.removeCallbacks(refresh);
        super.onPause();
    }

    private void render() {
        boolean perm = Env.allFilesAccess(this);
        btnPerm.setEnabled(!perm);
        btnPerm.setText(perm ? "文件权限：已开启" : "1  开启文件访问权限");
        btnPerm.setAlpha(perm ? 0.5f : 1f);

        boolean running = ServerService.RUNNING;
        btnOpen.setEnabled(running);
        btnOpen.setAlpha(running ? 1f : 0.5f);
        btnStop.setEnabled(running);
        btnStop.setAlpha(running ? 1f : 0.5f);

        String ip = Env.lanIp();
        StringBuilder sb = new StringBuilder();
        sb.append("状态：").append(ServerService.STATE).append('\n');
        if (!TextUtils.isEmpty(ServerService.DETAIL)) {
            sb.append(ServerService.DETAIL).append('\n');
        }
        sb.append('\n');
        sb.append("文件权限：").append(perm ? "已开启" : "未开启").append('\n');
        sb.append("局域网地址：").append(ip == null ? "没连上 WiFi" : ip + ":" + Env.PORT).append('\n');
        sb.append("存储位置：").append(Env.storeDir().getAbsolutePath()).append('\n');
        sb.append("下载引擎：").append(ServerService.ARIA2_STATE).append('\n');
        sb.append("下载目录：").append(Env.downloadDir().getAbsolutePath()).append('\n');
        sb.append("内置程序：").append(ServerService.NATIVE_INFO).append('\n');
        sb.append("开机自启：已启用\n");
        long last = ServerService.LAST_TICK_AT;
        if (last > 0) {
            sb.append("上次归位：")
                    .append(new SimpleDateFormat("HH:mm", Locale.US).format(new Date(last)));
            if (!TextUtils.isEmpty(ServerService.LAST_TICK_RESULT)) {
                sb.append(" · ").append(ServerService.LAST_TICK_RESULT);
            }
        } else {
            sb.append("上次归位：还没跑过");
        }
        stateText.setText(sb.toString());
    }

    /** 读 app.log 尾部 24 KB，够定位一次启动失败；不用 adb 也能把问题说出来。 */
    private void showLog() {
        String text;
        try {
            File f = new File(Env.logDir(this), "app.log");
            if (!f.isFile()) {
                text = "还没有日志。先点「启动 / 重启服务」。";
            } else {
                long len = f.length();
                long start = Math.max(0, len - 24 * 1024);
                RandomAccessFile raf = new RandomAccessFile(f, "r");
                raf.seek(start);
                StringBuilder b = new StringBuilder();
                String line;
                while ((line = raf.readLine()) != null) {
                    b.append(new String(line.getBytes("ISO-8859-1"), "UTF-8")).append('\n');
                }
                raf.close();
                text = b.toString().trim();
                if (text.isEmpty()) text = "日志是空的。";
            }
        } catch (Exception e) {
            text = "读日志失败：" + e;
        }
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        tv.setTextIsSelectable(true);
        tv.setPadding(dp(16), dp(12), dp(16), dp(12));
        ScrollView sv = new ScrollView(this);
        sv.addView(tv);
        new AlertDialog.Builder(this)
                .setTitle("运行日志（尾部）")
                .setView(sv)
                .setPositiveButton("关闭", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int w) {
                        d.dismiss();
                    }
                })
                .show();
    }

    private void startServiceCompat(Intent i) {
        if (Build.VERSION.SDK_INT >= 26) startForegroundService(i);
        else startService(i);
    }

    private Button makeButton(String text, String color) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextColor(Color.WHITE);
        b.setBackgroundColor(Color.parseColor(color));
        b.setAllCaps(false);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        b.setGravity(Gravity.CENTER);
        return b;
    }

    private LinearLayout.LayoutParams buttonParams(int top) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(46));
        p.topMargin = top;
        return p;
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density + 0.5f);
    }
}
