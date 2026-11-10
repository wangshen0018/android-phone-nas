package com.pantry.server;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.IBinder;
import android.util.Log;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.InputStream;
import java.util.Map;
import java.util.concurrent.TimeUnit;

/**
 * 库房服务：前台常驻，跑 8083 面板，每 30 分钟把 inbox 里的新照片按拍摄日期归位。
 *
 * 与 Magisk 版的对应关系：
 *   service.d/zzz-nasbak.sh 起 httpd → 这里的 Web
 *   cron 起来跑 daemon.sh        → 这里的 Handler 定时 tick
 *   busybox httpd               → 这里的 Web（Java 实现）
 *
 * 之所以在 Java 里重起一个调度，而不直接跑 daemon.sh：
 * daemon.sh 是 while true 死循环，服务停的时候要靠杀进程，容易留孤儿；
 * 而且它依赖 busybox crontab 之外的环环相扣，出问题只能翻日志。
 * 这里只保留最必要的三步：归位 → 登记 → 判读，节奏和阈值跟 daemon.sh 一致。
 */
public class ServerService extends Service {

    public static final String ACTION_STOP = "com.pantry.server.STOP";
    public static final String ACTION_TICK = "com.pantry.server.TICK";

    static volatile String STATE = "未启动";
    static volatile String DETAIL = "";
    static volatile boolean RUNNING = false;
    static volatile long LAST_TICK_AT = 0;
    static volatile String LAST_TICK_RESULT = "";

    private static final String TAG = "PantryServer";
    private static final String CHANNEL = "pantry-server";
    private static final int NOTI_ID = 1;
    private static final long PERIOD_MS = 30 * 60 * 1000L;

    private Web web;
    private HandlerThread worker;
    private Handler ui;
    private long lastIngestAt;
    private volatile boolean ticking;

    @Override
    public void onCreate() {
        super.onCreate();
        makeChannel();
        worker = new HandlerThread("pantry-tick");
        worker.start();
        ui = new Handler(worker.getLooper());
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopAll();
            stopSelf();
            return START_NOT_STICKY;
        }
        startForegroundCompat(notice());
        if (intent != null && ACTION_TICK.equals(intent.getAction())) {
            final Handler h = ui;
            if (h != null) h.post(new Runnable() {
                @Override
                public void run() {
                    tick(true);
                }
            });
            return START_STICKY;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                startAll();
            }
        }, "pantry-boot").start();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        stopAll();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent i) {
        return null;
    }

    // ───────────────────────── 启动 ─────────────────────────

    private void startAll() {
        if (web != null) {
            // 已经在跑，重启一遍（用户点「启动 / 重启」的场景）
            web.stop();
            web = null;
            RUNNING = false;
        }

        STATE = "检查权限";
        notifyState();
        if (!Env.allFilesAccess(this)) {
            STATE = "缺文件权限";
            DETAIL = "到 设置 → 应用 → Pantry 库房 → 所有文件访问 里打开";
            notifyState();
            return;
        }

        STATE = "准备运行时";
        notifyState();
        StringBuilder err = new StringBuilder();
        if (!Env.unpack(this, err)) {
            STATE = "运行时没准备好";
            DETAIL = err.length() > 0 ? err.toString() : "APK 里没有 runtime.zip";
            notifyState();
            return;
        }

        try {
            Env.ensureStore(this);
            Env.writeConf(this);
        } catch (Exception e) {
            STATE = "存储初始化失败";
            DETAIL = e.getClass().getSimpleName() + ": " + e.getMessage();
            notifyState();
            return;
        }

        STATE = "启动面板";
        notifyState();
        try {
            Web w = new Web(this, Env.PORT);
            String ip = w.start();
            web = w;
            RUNNING = true;
            STATE = "运行中";
            DETAIL = (ip == null ? "没连上 WiFi" : ip + ":" + Env.PORT);
            Env.log(this, "服务已启动 " + DETAIL);
        } catch (Exception e) {
            STATE = "端口被占用";
            DETAIL = Env.PORT + " 起不来：" + e.getMessage()
                    + "。如果之前用 Magisk 部署过，先停掉那边的 httpd。";
            notifyState();
            return;
        }
        notifyState();

        // 首轮延迟 20 秒：让面板先能打开，别一进来就抢 CPU
        lastIngestAt = System.currentTimeMillis() - PERIOD_MS + 20000;
        if (ui != null) {
            ui.removeCallbacks(tickRun);
            ui.postDelayed(tickRun, 20000);
        }
    }

    private void stopAll() {
        if (ui != null) ui.removeCallbacks(tickRun);
        if (web != null) {
            web.stop();
            web = null;
        }
        if (worker != null) {
            worker.quitSafely();
            worker = null;
            ui = null;
        }
        RUNNING = false;
        STATE = "已停止";
        DETAIL = "";
        notifyState();
    }

    // ───────────────────────── 定时归位 ─────────────────────────

    private final Runnable tickRun = new Runnable() {
        @Override
        public void run() {
            tick(false);
            if (ui != null) ui.postDelayed(this, 60000);
        }
    };

    private void tick(boolean force) {
        if (ticking) return;
        long now = System.currentTimeMillis();
        if (!force && now - lastIngestAt < PERIOD_MS) return;
        ticking = true;
        lastIngestAt = now;

        try {
            String moved = exec(60, "move-by-date.sh", "--apply");
            int n = extract(moved, "moved=");
            exec(180, "judge.sh", "--ingest");
            // --judge 里的 build 负责重建 www/data.json（判定页的数据源），
            // 所以每轮都要跑，不能只在有新增时跑，否则新照片进不了判定页。
            // 没配在线模型时判读会失败但不影响 build，手工判定照常。
            exec(900, "judge.sh", "--judge");
            LAST_TICK_AT = System.currentTimeMillis();
            LAST_TICK_RESULT = n > 0 ? ("上轮归位 " + n + " 个") : "上轮无新文件";
            Env.log(this, "tick " + LAST_TICK_RESULT);
        } catch (Exception e) {
            LAST_TICK_RESULT = "归位出错：" + e.getMessage();
            Env.log(this, "tick 失败: " + e);
        } finally {
            ticking = false;
            notifyState();
        }
    }

    /**
     * 在当前进程里跑一个 shell 脚本。
     * exec 的是 /system/bin/sh，脚本只是参数，所以放在私有目录里也能执行。
     */
    private String exec(int timeoutSec, String script, String... args) {
        String[] cmd = new String[args.length + 2];
        cmd[0] = "/system/bin/sh";
        cmd[1] = new java.io.File(Env.binDir(this), script).getAbsolutePath();
        System.arraycopy(args, 0, cmd, 2, args.length);

        Process p = null;
        try {
            ProcessBuilder pb = new ProcessBuilder(cmd);
            pb.directory(Env.binDir(this));
            pb.redirectErrorStream(true);
            Map<String, String> e = pb.environment();
            e.put("PATH", "/system/bin:/system/xbin");
            e.put("NASBAK_CONF", Env.confFile(this).getAbsolutePath());
            e.put("HOME", Env.runtimeDir(this).getAbsolutePath());
            p = pb.start();

            final ByteArrayOutputStream buf = new ByteArrayOutputStream();
            final InputStream in = p.getInputStream();
            Thread t = new Thread(new Runnable() {
                @Override
                public void run() {
                    byte[] b = new byte[8192];
                    int n;
                    try {
                        while ((n = in.read(b)) > 0) {
                            if (buf.size() < 256 * 1024) buf.write(b, 0, n);
                        }
                    } catch (Exception ignored) {
                    }
                }
            }, "pantry-exec");
            t.setDaemon(true);
            t.start();

            if (!p.waitFor(timeoutSec, TimeUnit.SECONDS)) {
                p.destroyForcibly();
                Env.log(this, script + " 超时 " + timeoutSec + "s");
                return "";
            }
            try {
                t.join(1500);
            } catch (InterruptedException ignored) {
            }
            return new String(buf.toByteArray(), "UTF-8");
        } catch (Exception ex) {
            Env.log(this, script + " 执行失败: " + ex);
            return "";
        } finally {
            if (p != null) try {
                p.destroy();
            } catch (Exception ignored) {
            }
        }
    }

    private static int extract(String text, String key) {
        int i = text.lastIndexOf(key);
        if (i < 0) return 0;
        int j = i + key.length();
        int k = j;
        while (k < text.length() && Character.isDigit(text.charAt(k))) k++;
        if (k == j) return 0;
        try {
            return Integer.parseInt(text.substring(j, k));
        } catch (NumberFormatException e) {
            return 0;
        }
    }

    // ───────────────────────── 通知 ─────────────────────────

    private void notifyState() {
        try {
            ((NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE))
                    .notify(NOTI_ID, notice());
        } catch (Exception ignored) {
        }
    }

    private Notification notice() {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            b = new Notification.Builder(this, CHANNEL);
        } else {
            b = new Notification.Builder(this);
        }
        String sub = LAST_TICK_RESULT;
        if (sub == null || sub.isEmpty()) sub = "等待首轮归位";
        PendingIntent pi = PendingIntent.getActivity(this, 0,
                new Intent(this, MainActivity.class),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        return b.setSmallIcon(R.drawable.ic_stat)
                .setContentTitle("Pantry 库房 · " + STATE)
                .setContentText(DETAIL.isEmpty() ? "面板 8083" : DETAIL)
                .setSubText(sub)
                .setContentIntent(pi)
                .setOngoing(true)
                .build();
    }

    private void startForegroundCompat(Notification n) {
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTI_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTI_ID, n);
        }
    }

    private void makeChannel() {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationChannel c = new NotificationChannel(CHANNEL, "库房服务",
                NotificationManager.IMPORTANCE_LOW);
        c.setDescription("面板 8083 与定期归位的运行状态");
        c.setShowBadge(false);
        ((NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE))
                .createNotificationChannel(c);
    }
}
