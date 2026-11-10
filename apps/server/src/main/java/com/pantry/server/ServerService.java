package com.pantry.server;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;

/**
 * 库房服务：前台常驻，把 8083 面板跑起来。
 *
 * 现在只做「解压运行时 → 起 httpd」这一段，daemon 定时调度和二进制打包
 * 留给下一版。这样骨架能编译、能装、能看出缺什么，不会假装已经能跑。
 */
public class ServerService extends Service {

    public static final String ACTION_STOP = "com.pantry.server.STOP";

    static volatile String STATE = "未启动";
    static volatile String DETAIL = "";

    private static final String TAG = "PantryServer";
    private static final String CHANNEL = "pantry-server";
    private static final int NOTI_ID = 1;

    private volatile Process httpd;

    @Override
    public void onCreate() {
        super.onCreate();
        makeChannel();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_STOP.equals(intent.getAction())) {
            stopAll();
            stopSelf();
            return START_NOT_STICKY;
        }
        startForeground(NOTI_ID, notice("正在准备…"));
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

    private void startAll() {
        STATE = "检查运行时";
        StringBuilder err = new StringBuilder();
        if (!Env.unpack(this, err)) {
            STATE = "运行时没准备好";
            DETAIL = err.length() > 0 ? err.toString()
                    : "仓库里没有 assets/runtime.zip。先在电脑上跑 apps/server/pack-assets.py 生成它。";
            notifyState();
            return;
        }

        File bb = new File(Env.binDir(this), "busybox");
        if (!bb.exists()) {
            STATE = "缺运行时二进制";
            DETAIL = "busybox 还没打进包。见 apps/server/pack-assets.py 里的说明："
                    + " Android 10 起不能直接 exec filesDir 里的文件，"
                    + "要以 libbusybox.so 放进 jniLibs，由系统装到 nativeLibraryDir。";
            notifyState();
            return;
        }

        STATE = "启动 httpd";
        notifyState();
        try {
            File root = Env.runtimeDir(this);
            ProcessBuilder pb = new ProcessBuilder(
                    bb.getAbsolutePath(), "httpd", "-f",
                    "-p", "8083",
                    "-h", Env.wwwDir(this).getAbsolutePath(),
                    "-c", new File(root, "httpd.conf").getAbsolutePath());
            pb.directory(root);
            pb.redirectErrorStream(true);
            httpd = pb.start();

            // 读一会儿输出，启动失败时能把原因留在 DETAIL 里
            final BufferedReader r = new BufferedReader(
                    new InputStreamReader(httpd.getInputStream()));
            new Thread(new Runnable() {
                @Override
                public void run() {
                    try {
                        String line;
                        while ((line = r.readLine()) != null) {
                            Log.i(TAG, "httpd: " + line);
                        }
                    } catch (Exception ignored) {
                    }
                }
            }, "pantry-httpd-log").start();

            String ip = Env.lanIp();
            STATE = "运行中";
            DETAIL = (ip == null ? "本机" : ip) + ":8083";
        } catch (Exception ex) {
            STATE = "启动失败";
            DETAIL = ex.getClass().getSimpleName() + ": " + ex.getMessage();
            Log.e(TAG, STATE, ex);
        }
        notifyState();
    }

    private void stopAll() {
        Process p = httpd;
        if (p != null) {
            p.destroy();
            httpd = null;
        }
        STATE = "已停止";
        DETAIL = "";
        notifyState();
    }

    private void notifyState() {
        ((NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE))
                .notify(NOTI_ID, notice(STATE + (DETAIL.isEmpty() ? "" : " · " + DETAIL)));
    }

    private Notification notice(String text) {
        Notification.Builder b;
        if (Build.VERSION.SDK_INT >= 26) {
            b = new Notification.Builder(this, CHANNEL);
        } else {
            b = new Notification.Builder(this);
        }
        return b.setSmallIcon(R.drawable.ic_stat)
                .setContentTitle("Pantry 库房")
                .setContentText(text)
                .setOngoing(true)
                .build();
    }

    private void makeChannel() {
        if (Build.VERSION.SDK_INT < 26) return;
        NotificationChannel c = new NotificationChannel(CHANNEL, "库房服务",
                NotificationManager.IMPORTANCE_LOW);
        c.setDescription("面板 8083 的运行状态");
        ((NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE))
                .createNotificationChannel(c);
    }
}
