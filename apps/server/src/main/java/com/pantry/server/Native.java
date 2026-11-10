package com.pantry.server;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;

/**
 * 内置静态程序的管理。
 *
 * Android 10 起禁止 exec 应用私有可写目录里的 ELF，但 APK 里
 * lib/&lt;abi&gt;/lib*.so 会由系统解压到 nativeLibraryDir（只读、可执行）。
 * 所以 aria2c / curl 以 libaria2c.so / libcurl.so 之名随包分发，
 * 这里负责找到它们、核对完整性、跑一次 --version 自证能 exec。
 *
 * 任何一步失败都只是让「下载 / 抓取」类功能降级，绝不影响 8083 主面板。
 */
public final class Native {
    public static final String ARIA2 = "aria2c";
    public static final String CURL = "curl";

    private static final String CACERTS = "/system/etc/security/cacerts";

    private Native() {
    }

    public static File bin(Context c, String name) {
        return new File(c.getApplicationInfo().nativeLibraryDir, "lib" + name + ".so");
    }

    public static boolean available(Context c, String name) {
        File f = bin(c, name);
        if (!f.isFile()) return false;
        if (!f.canExecute()) {
            // 多数 ROM 解出来的 .so 就是 0755；个别不是的话试一次，
            // 目录归 root 所有，改不动就算了，由 probe 报出来。
            try {
                f.setExecutable(true, false);
            } catch (Exception ignored) {
            }
        }
        return f.canExecute();
    }

    /** 真跑一次 --version，比看文件在不在可靠得多。 */
    public static String version(Context c, String name) {
        if (!available(c, name)) return "缺失或不可执行";
        Process p = null;
        try {
            p = new ProcessBuilder(bin(c, name).getAbsolutePath(), "--version")
                    .redirectErrorStream(true).start();
            BufferedReader r = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8));
            String line = r.readLine();
            r.close();
            waitOrKill(p, 5);
            if (line == null || line.trim().isEmpty()) return "无输出";
            return line.length() > 90 ? line.substring(0, 90) : line;
        } catch (Exception e) {
            return "执行失败：" + e.getClass().getSimpleName();
        } finally {
            if (p != null) p.destroy();
        }
    }

    /** 对照 assets/tools.sha256，防止构建期资产被换包。只校验 ELF 那两行。 */
    public static String verify(Context c) {
        Map<String, String> want = new HashMap<>();
        try {
            InputStream in = c.getAssets().open("tools.sha256");
            BufferedReader r = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8));
            String line;
            while ((line = r.readLine()) != null) {
                if (line.startsWith("#") || line.trim().isEmpty()) continue;
                String[] a = line.trim().split("\\s+");
                if (a.length >= 2) want.put(a[0], a[1]);
            }
            r.close();
        } catch (Exception e) {
            return "清单缺失";
        }
        StringBuilder sb = new StringBuilder();
        for (String name : new String[]{ARIA2, CURL}) {
            String exp = want.get(name);
            if (exp == null) {
                sb.append(name).append(":清单无记录 ");
                continue;
            }
            File f = bin(c, name);
            String got = f.isFile() ? sha256(f) : "";
            sb.append(name).append(exp.equalsIgnoreCase(got) ? ":校验通过 " : ":校验失败 ");
        }
        return sb.toString().trim();
    }

    /**
     * Android 的 CA 是一堆 /system/etc/security/cacerts/*.0，而 aria2 / curl
     * 只认一个 PEM bundle。启动时拼一份到私有目录，HTTPS 下载才不会报证书错。
     */
    public static File caBundle(Context c) {
        File out = new File(c.getFilesDir(), "cacert.pem");
        File dir = new File(CACERTS);
        if (!dir.isDirectory()) return null;
        File[] list = dir.listFiles();
        if (list == null || list.length == 0) return null;
        Arrays.sort(list);
        FileOutputStream os = null;
        try {
            os = new FileOutputStream(out);
            byte[] buf = new byte[8192];
            for (File f : list) {
                if (!f.isFile() || f.length() > 64 * 1024) continue;
                FileInputStream in = null;
                try {
                    in = new FileInputStream(f);
                    int n;
                    while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
                    os.write('\n');
                } catch (Exception ignored) {
                } finally {
                    if (in != null) try {
                        in.close();
                    } catch (Exception ignored) {
                    }
                }
            }
            os.close();
            return out;
        } catch (Exception e) {
            if (os != null) try {
                os.close();
            } catch (Exception ignored) {
            }
            return null;
        }
    }

    /** 给前端 /cgi/caps.cgi 用：按真实能力决定菜单显示哪些项。 */
    public static String capsJson(Context c, boolean downloadOn) {
        boolean aria = available(c, ARIA2);
        boolean curl = available(c, CURL);
        String b64 = android.util.Base64.encodeToString(
                Env.ARIA2_SECRET.getBytes(StandardCharsets.UTF_8),
                android.util.Base64.URL_SAFE | android.util.Base64.NO_WRAP);
        return "{\"aria2\":" + (aria && downloadOn)
                + ",\"curl\":" + curl
                + ",\"rpcSecretB64\":\"" + b64 + "\""
                + ",\"files\":true"
                + ",\"screen\":false"
                + ",\"alist\":false}";
    }

    public static String sha256(File f) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            FileInputStream in = new FileInputStream(f);
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
            in.close();
            StringBuilder sb = new StringBuilder();
            for (byte b : md.digest()) sb.append(String.format("%02x", b & 0xff));
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    /** minSdk 24 没有 Process.waitFor(long, TimeUnit)，统一用轮询。@return true=超时被杀 */
    public static boolean waitOrKill(Process p, int seconds) {
        long end = System.currentTimeMillis() + seconds * 1000L;
        while (System.currentTimeMillis() < end) {
            try {
                p.exitValue();
                return false;
            } catch (IllegalThreadStateException e) {
                try {
                    Thread.sleep(150);
                } catch (InterruptedException ie) {
                    return false;
                }
            }
        }
        p.destroy();
        return true;
    }
}
