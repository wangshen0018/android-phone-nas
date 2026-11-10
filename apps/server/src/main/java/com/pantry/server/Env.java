package com.pantry.server;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.Settings;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/** 路径、权限、IP、运行时解压。全部集中在这里，别处不再拼路径。 */
final class Env {

    static final String TAG = "PantryServer";
    static final int PORT = 8083;
    static final int ARIA2_PORT = 6800;
    /** 只在自家 WiFi 里用；8083 本身就无鉴权，这个 secret 不是安全边界。 */
    static final String ARIA2_SECRET = "k40srv";

    /** 脚本、页面、配置：解压进 App 私有目录，升级 App 时整体替换。 */
    static File runtimeDir(Context c) {
        return new File(c.getFilesDir(), "runtime");
    }

    static File wwwDir(Context c) {
        return new File(runtimeDir(c), "www");
    }

    static File binDir(Context c) {
        return new File(runtimeDir(c), "bin");
    }

    static File logDir(Context c) {
        return new File(runtimeDir(c), "logs");
    }

    static File confFile(Context c) {
        return new File(new File(runtimeDir(c), "etc"), "nasbak.conf");
    }

    /**
     * 脚本的临时文件和锁目录。
     * 设备版用 /data/local/tmp，但那里普通 App 不可写，改成私有目录；
     * 同一个 App 的所有 CGI 子进程共用一个 uid，mkdir 原子锁照样有效。
     */
    static File tmpDir(Context c) {
        return new File(c.getFilesDir(), "tmp");
    }

    /**
     * 照片和账本存共享存储，不放 App 私有目录：
     * 卸载重装不会丢，数据线插上电脑能直接按文件夹翻。
     */
    static File storeDir() {
        return new File(Environment.getExternalStorageDirectory(), "Pantry");
    }

    static File stateDir() {
        return new File(storeDir(), "state");
    }

    static File inboxDir() {
        return new File(storeDir(), "inbox");
    }

    static File archiveDir() {
        return new File(storeDir(), "archive");
    }

    // ───────────────────────── 权限 ─────────────────────────

    /** Android 11 起按路径读写共享存储必须拿「所有文件访问」，代码只能跳设置页让用户点。 */
    static boolean allFilesAccess(Context c) {
        if (Build.VERSION.SDK_INT < 30) return true;
        return Environment.isExternalStorageManager();
    }

    static Intent allFilesSettingsIntent(Context c) {
        Intent i = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
        i.setData(Uri.parse("package:" + c.getPackageName()));
        return i;
    }

    // ───────────────────────── 网络 ─────────────────────────

    /** 取本机局域网 IPv4，给家人手机填地址用。 */
    static String lanIp() {
        try {
            Enumeration<NetworkInterface> nis = NetworkInterface.getNetworkInterfaces();
            while (nis.hasMoreElements()) {
                NetworkInterface ni = nis.nextElement();
                if (ni == null || !ni.isUp() || ni.isLoopback()) continue;
                String name = ni.getName() == null ? "" : ni.getName();
                if (!(name.startsWith("wlan") || name.startsWith("eth")
                        || name.startsWith("ap") || name.startsWith("swlan"))) continue;
                Enumeration<InetAddress> as = ni.getInetAddresses();
                while (as.hasMoreElements()) {
                    InetAddress a = as.nextElement();
                    if (a instanceof Inet4Address && !a.isLoopbackAddress()) {
                        return a.getHostAddress();
                    }
                }
            }
        } catch (Exception ignored) {
        }
        return null;
    }

    // ───────────────────────── 运行时解压 ─────────────────────────

    /**
     * 把 assets/runtime.zip 解到私有目录。
     *
     * 版本戳 = APK versionCode + zip 字节数。戳变了就重解压，
     * 否则改了脚本却因为「已解压过」一直跑旧的，排查起来非常费劲。
     * 只清 www/bin/etc/srv，logs 和 daemon.pid 留着。
     */
    static boolean unpack(Context c, StringBuilder err) {
        File root = runtimeDir(c);
        String want = versionTag(c);
        File stamp = new File(root, ".stamp");
        if (stamp.isFile()
                && want.equals(readSmall(stamp))
                && new File(wwwDir(c), "index.html").isFile()) {
            return true;
        }
        try {
            root.mkdirs();
            deleteTree(wwwDir(c));
            deleteTree(binDir(c));
            deleteTree(new File(root, "etc"));
            deleteTree(new File(root, "srv"));

            InputStream in = c.getAssets().open("runtime.zip");
            ZipInputStream zis = new ZipInputStream(in);
            byte[] buf = new byte[16384];
            int files = 0;
            ZipEntry e;
            while ((e = zis.getNextEntry()) != null) {
                String name = e.getName();
                // 自己的 assets 也按规矩拦一道，防以后打错包
                if (name.contains("..") || name.startsWith("/")) {
                    zis.closeEntry();
                    continue;
                }
                File out = new File(root, name);
                if (e.isDirectory()) {
                    out.mkdirs();
                } else {
                    File parent = out.getParentFile();
                    if (parent != null) parent.mkdirs();
                    OutputStream os = new FileOutputStream(out);
                    int n;
                    while ((n = zis.read(buf)) > 0) os.write(buf, 0, n);
                    os.close();
                    files++;
                }
                zis.closeEntry();
            }
            zis.close();
            in.close();

            if (!new File(wwwDir(c), "index.html").isFile()) {
                err.append("runtime.zip 里没有 www/index.html");
                return false;
            }
            writeSmall(stamp, want);
            log(c, "解压运行时 " + files + " 个文件，版本 " + want);
            return true;
        } catch (Exception ex) {
            err.append(ex.getClass().getSimpleName()).append(": ").append(ex.getMessage());
            return false;
        }
    }

    /**
     * 写 App 版路径配置。lib-path.sh 第一优先级读 NASBAK_CONF，
     * 所以脚本里不需要知道自己在哪，跟着这份配置走。
     */
    static void writeConf(Context c) throws IOException {
        File f = confFile(c);
        File parent = f.getParentFile();
        if (parent != null) parent.mkdirs();
        String s = "# 服务端 App 生成，每次启动重写，手改会被覆盖\n"
                + "NASBAK_HOME=" + runtimeDir(c).getAbsolutePath() + "\n"
                + "NASBAK_ROOT=" + storeDir().getAbsolutePath() + "\n"
                + "NASBAK_PORT=" + PORT + "\n"
                + "NASBAK_BB=/system/bin/toybox\n"
                + "NASBAK_LOGD=" + logDir(c).getAbsolutePath() + "\n"
                + "NASBAK_TMP=" + tmpDir(c).getAbsolutePath() + "\n"
                + "NASBAK_CURL=" + (Native.available(c, Native.CURL)
                        ? Native.bin(c, Native.CURL).getAbsolutePath() : "") + "\n"
                + "NASBAK_ARIA2=" + (Native.available(c, Native.ARIA2)
                        ? Native.bin(c, Native.ARIA2).getAbsolutePath() : "") + "\n"
                + "NASBAK_CA=" + (caFile(c).exists() ? caFile(c).getAbsolutePath() : "") + "\n"
                + "NASBAK_RPC_SECRET=" + ARIA2_SECRET + "\n"
                + "NASBAK_RPC_PORT=" + ARIA2_PORT + "\n"
                + "NASBAK_DOWNLOAD=" + downloadDir().getAbsolutePath() + "\n";
        writeSmall(f, s);
    }

    static File caFile(Context c) {
        return new File(c.getFilesDir(), "cacert.pem");
    }

    static File downloadDir() {
        return new File(storeDir(), "Downloads");
    }

    static File aria2StateDir() {
        return new File(stateDir(), "aria2");
    }

    /** 共享存储下的目录骨架，缺哪个补哪个。 */
    static void ensureStore(Context c) {
        String[] dirs = {
                "state", "state/media", "state/thumb", "archive",
                "inbox", "inbox/Camera", "inbox/CamScanner", "inbox/scanner",
                "inbox/儿子", "inbox/身份证", "inbox/Pantry", "inbox/_dup_backup",
                "Downloads", "state/aria2"
        };
        for (String d : dirs) {
            File f = new File(storeDir(), d);
            if (!f.isDirectory()) f.mkdirs();
        }
        logDir(c).mkdirs();
        tmpDir(c).mkdirs();
        for (String f : new String[]{"ledger.jsonl", "decisions.jsonl", "receipts.jsonl",
                "analysis.jsonl", "events.jsonl", "pending.queue"}) {
            File x = new File(stateDir(), f);
            if (!x.exists()) {
                try {
                    x.createNewFile();
                } catch (IOException ignored) {
                }
            }
        }
    }

    // ───────────────────────── 杂项 ─────────────────────────

    static String versionTag(Context c) {
        long vc = 0;
        try {
            vc = c.getPackageManager().getPackageInfo(c.getPackageName(), 0).versionCode;
        } catch (PackageManager.NameNotFoundException ignored) {
        }
        long size = 0;
        try {
            InputStream in = c.getAssets().open("runtime.zip");
            byte[] b = new byte[16384];
            int n;
            while ((n = in.read(b)) > 0) size += n;
            in.close();
        } catch (Exception ignored) {
        }
        return vc + "-" + size;
    }

    static void log(Context c, String msg) {
        try {
            File d = logDir(c);
            d.mkdirs();
            File f = new File(d, "app.log");
            if (f.length() > 512 * 1024) {
                File old = new File(d, "app.log.1");
                if (old.exists()) old.delete();
                f.renameTo(old);
            }
            FileOutputStream os = new FileOutputStream(f, true);
            os.write((new java.text.SimpleDateFormat("MM-dd HH:mm:ss",
                    java.util.Locale.US).format(new java.util.Date())
                    + " " + msg + "\n").getBytes("UTF-8"));
            os.close();
        } catch (Exception ignored) {
        }
    }

    static String readSmall(File f) {
        try {
            FileInputStream in = new FileInputStream(f);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] b = new byte[1024];
            int n;
            while ((n = in.read(b)) > 0 && out.size() < 8192) out.write(b, 0, n);
            in.close();
            return out.toString("UTF-8").trim();
        } catch (Exception e) {
            return "";
        }
    }

    static void writeSmall(File f, String s) throws IOException {
        FileOutputStream os = new FileOutputStream(f);
        os.write(s.getBytes("UTF-8"));
        os.close();
    }

    static void deleteTree(File f) {
        if (f == null || !f.exists()) return;
        if (f.isDirectory()) {
            File[] kids = f.listFiles();
            if (kids != null) for (File k : kids) deleteTree(k);
        }
        f.delete();
    }

    private Env() {
    }
}
