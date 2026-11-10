package com.pantry.server;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.Settings;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/** 环境相关的小工具，不依赖 AndroidX。 */
final class Env {

    /** App 私有目录里的运行时根目录。 */
    static File runtimeDir(Context c) {
        return new File(c.getFilesDir(), "runtime");
    }

    static File wwwDir(Context c) {
        return new File(runtimeDir(c), "www");
    }

    static File binDir(Context c) {
        return new File(runtimeDir(c), "bin");
    }

    /**
     * Android 11 起，要按路径读写共享存储里的照片，必须拿「所有文件访问」。
     * 这个权限要用户自己去设置页开，代码只能跳转过去。
     */
    static boolean allFilesAccess(Context c) {
        if (Build.VERSION.SDK_INT < 30) return true; // 老系统走 READ/WRITE 就够了
        return Environment.isExternalStorageManager();
    }

    static Intent allFilesSettingsIntent(Context c) {
        Intent i = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
        i.setData(Uri.parse("package:" + c.getPackageName()));
        return i;
    }

    /** 取本机局域网 IPv4，给家人手机上填地址用。 */
    static String lanIp() {
        try {
            Enumeration<NetworkInterface> nis = NetworkInterface.getNetworkInterfaces();
            while (nis.hasMoreElements()) {
                NetworkInterface ni = nis.nextElement();
                if (ni == null || !ni.isUp() || ni.isLoopback()) continue;
                String name = ni.getName() == null ? "" : ni.getName();
                if (!(name.startsWith("wlan") || name.startsWith("eth")
                        || name.startsWith("ap"))) continue;
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

    /**
     * 把 assets/runtime.zip 解压到私有目录。
     * zip 里只放脚本、页面和配置，不放可执行二进制——见 pack-assets.py 的说明。
     * 已解压过就跳过，避免每次启动都重写几千个文件。
     */
    static boolean unpack(Context c, StringBuilder err) {
        File root = runtimeDir(c);
        File stamp = new File(root, "www/index.html");
        if (stamp.exists()) return true;

        try {
            root.mkdirs();
            InputStream in = c.getAssets().open("runtime.zip");
            ZipInputStream zis = new ZipInputStream(in);
            byte[] buf = new byte[8192];
            ZipEntry e;
            while ((e = zis.getNextEntry()) != null) {
                String name = e.getName();
                // 防目录穿越：assets 是自己的，仍按规矩拦一道
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
                }
                zis.closeEntry();
            }
            zis.close();
            return stamp.exists();
        } catch (Exception ex) {
            err.append(ex.getClass().getSimpleName()).append(": ").append(ex.getMessage());
            return false;
        }
    }

    private Env() {
    }
}
