package com.pantry.server;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * 库房端界面。只有三件事能点：开文件权限、起服务、停服务。
 *
 * 之所以用代码拼布局而不写 XML：这个 App 一共就一屏，
 * 少一个资源文件，也少一处和构建工具版本较劲的地方。
 */
public class MainActivity extends Activity {

    private TextView stateText;
    private Button btnPerm;
    private Button btnStart;
    private Button btnStop;
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
        sub.setText("这台手机当库房，照片存在这里。保持插电，别清后台。");
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
                    Toast.makeText(MainActivity.this, "打不开设置页，请手动到 设置 → 应用 → 特殊权限 → 所有文件访问 里开启",
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
                Intent i = new Intent(MainActivity.this, ServerService.class);
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(i);
                else startService(i);
            }
        });
        box.addView(btnStart, buttonParams(dp(10)));

        btnStop = makeButton("停止服务", "#6B7280");
        btnStop.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                Intent i = new Intent(MainActivity.this, ServerService.class);
                i.setAction(ServerService.ACTION_STOP);
                startService(i);
            }
        });
        box.addView(btnStop, buttonParams(dp(10)));

        TextView note = new TextView(this);
        note.setText("面板端口 8083。家人手机上装的是另一个 App（Pantry），"
                + "首次打开会自动搜到这台设备。\n\n"
                + "第一版骨架只负责把服务和运行时跑起来，"
                + "业务脚本的打包方式见 apps/server/pack-assets.py。");
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

        String ip = Env.lanIp();
        StringBuilder sb = new StringBuilder();
        sb.append("状态：").append(ServerService.STATE).append('\n');
        if (!ServerService.DETAIL.isEmpty()) {
            sb.append(ServerService.DETAIL).append('\n');
        }
        sb.append('\n');
        sb.append("文件权限：").append(perm ? "已开启" : "未开启").append('\n');
        sb.append("局域网地址：")
                .append(ip == null ? "没连上 WiFi" : ip + ":8083");
        stateText.setText(sb.toString());
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
