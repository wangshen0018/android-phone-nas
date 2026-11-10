package com.nasbak.shell;

import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;
import android.util.Base64;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.Charset;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 把本机的照片/视频增量送进库房。
 *
 * 只做三件事：读 MediaStore、按 id+修改时间跳过已传的、HTTP POST 原始字节。
 * 不常驻、不开前台服务、不引 AndroidX —— 打开 App 时跑一轮，跑完就结束。
 * 国产 ROM 的后台限制躲不掉，与其假装能 7x24 自动备份，不如让用户看得见地传一次。
 *
 * 开关默认关：装到家人手机上只是看照片，不能悄悄把人家相册搬走。
 */
public class Backup {

    public static final String PREF = "nasbak";
    public static final String KEY_ON = "backupOn";
    public static final String KEY_DONE = "backupDone";

    private static final String[] PERM_NEW = {
            "android.permission.READ_MEDIA_IMAGES",
            "android.permission.READ_MEDIA_VIDEO"
    };
    private static final String[] PERM_OLD = {
            "android.permission.READ_EXTERNAL_STORAGE"
    };
    /** 太小的多半是缩略图、表情包、缓存图，不值得占库房 */
    private static final long MIN_SIZE = 50 * 1024;

    public interface Cb {
        void onProgress(int done, int total, int uploaded);
        void onDone(int uploaded, int skipped, int failed, String err);
    }

    public static String[] permissions() {
        return Build.VERSION.SDK_INT >= 33 ? PERM_NEW : PERM_OLD;
    }

    public static boolean hasPermission(Context c) {
        for (String p : permissions()) {
            if (c.checkSelfPermission(p) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                return false;
            }
        }
        return true;
    }

    /** 从面板地址推出服务端 origin：http://192.168.x.x:8083/index.html -> http://192.168.x.x:8083 */
    public static String originOf(String panelUrl) {
        if (panelUrl == null) return null;
        int i = panelUrl.indexOf("://");
        if (i < 0) return null;
        int slash = panelUrl.indexOf('/', i + 3);
        String base = slash > 0 ? panelUrl.substring(0, slash) : panelUrl;
        return base;
    }

    private static Set<String> loadDone(SharedPreferences sp) {
        Set<String> set = new HashSet<String>();
        String raw = sp.getString(KEY_DONE, "");
        if (raw.isEmpty()) return set;
        for (String k : raw.split(",")) {
            if (!k.isEmpty()) set.add(k);
        }
        return set;
    }

    private static void saveDone(SharedPreferences sp, Set<String> done) {
        // 上限保护：极端情况下几万条会让 SharedPreferences 变胖，只留最近两万条
        StringBuilder sb = new StringBuilder();
        int n = 0;
        for (String k : done) {
            if (n++ > 20000) break;
            if (sb.length() > 0) sb.append(',');
            sb.append(k);
        }
        sp.edit().putString(KEY_DONE, sb.toString()).apply();
    }

    private static class Item {
        Uri uri;
        String name;
        long modified;
        long size;
        String key;
    }

    private static void collect(ContentResolver cr, Uri table, List<Item> out) {
        String[] proj = {
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.DATE_MODIFIED,
                MediaStore.MediaColumns.SIZE
        };
        Cursor cur = null;
        try {
            cur = cr.query(table, proj, null, null,
                    MediaStore.MediaColumns.DATE_MODIFIED + " DESC");
            if (cur == null) return;
            int iId = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID);
            int iName = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME);
            int iMod = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED);
            int iSize = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE);
            while (cur.moveToNext()) {
                long size = cur.getLong(iSize);
                if (size < MIN_SIZE) continue;
                String name = cur.getString(iName);
                if (name == null || name.isEmpty()) continue;
                Item it = new Item();
                it.uri = ContentUris.withAppendedId(table, cur.getLong(iId));
                it.name = name;
                it.modified = cur.getLong(iMod);
                it.size = size;
                it.key = cur.getLong(iId) + ":" + it.modified;
                out.add(it);
            }
        } catch (Exception e) {
            // 某个表读不到就跳过，另一张表还能传
        } finally {
            if (cur != null) try { cur.close(); } catch (Exception ignored) { }
        }
    }

    /** 后台线程执行；回调在调用方线程之外，需要刷新 UI 就自己 post 回去 */
    public static void run(final Context ctx, final String panelUrl, final Cb cb) {
        final String origin = originOf(panelUrl);
        if (origin == null) {
            cb.onDone(0, 0, 0, "面板地址不对，先找到库房");
            return;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                final SharedPreferences sp = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE);
                Set<String> done = loadDone(sp);
                List<Item> all = new ArrayList<Item>();
                collect(ctx.getContentResolver(), MediaStore.Images.Media.EXTERNAL_CONTENT_URI, all);
                collect(ctx.getContentResolver(), MediaStore.Video.Media.EXTERNAL_CONTENT_URI, all);

                String url = origin + "/cgi/upload.cgi";
                int uploaded = 0, skipped = 0, failed = 0;
                String firstErr = null;
                int total = all.size();
                for (int i = 0; i < total; i++) {
                    Item it = all.get(i);
                    if (done.contains(it.key)) { skipped++; }
                    else {
                        String err = uploadOne(ctx, url, it);
                        if (err == null) {
                            uploaded++;
                            done.add(it.key);
                            // 每张都存一次，中途被杀也不会从头再来
                            saveDone(sp, done);
                        } else {
                            failed++;
                            if (firstErr == null) firstErr = err;
                        }
                    }
                    final int fdone = i + 1, ftotal = total, fup = uploaded;
                    cb.onProgress(fdone, ftotal, fup);
                }
                saveDone(sp, done);
                cb.onDone(uploaded, skipped, failed, firstErr);
            }
        }, "pantry-backup").start();
    }

    private static String uploadOne(Context ctx, String url, Item it) {
        HttpURLConnection conn = null;
        try {
            conn = (HttpURLConnection) new URL(url).openConnection();
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setConnectTimeout(8000);
            conn.setReadTimeout(60000);
            conn.setRequestProperty("Content-Type", "application/octet-stream");
            conn.setRequestProperty("X-Pantry-Name", Base64.encodeToString(
                    it.name.getBytes(Charset.forName("UTF-8")), Base64.NO_WRAP));
            conn.setRequestProperty("X-Pantry-Dev", safeAscii(Build.MODEL));
            conn.setRequestProperty("X-Pantry-Shot", String.valueOf(it.modified));
            conn.setFixedLengthStreamingMode(it.size);

            InputStream in = ctx.getContentResolver().openInputStream(it.uri);
            if (in == null) return "打不开 " + it.name;
            OutputStream os = conn.getOutputStream();
            byte[] buf = new byte[64 * 1024];
            int n;
            try {
                while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
            } finally {
                try { in.close(); } catch (Exception ignored) { }
                os.close();
            }

            int code = conn.getResponseCode();
            if (code != 200) return "HTTP " + code;
            String resp = readAll(conn);
            if (resp == null || !resp.contains("\"ok\":true")) {
                return resp == null ? "库房没回应" : resp.trim();
            }
            return null;
        } catch (Exception e) {
            return e.getClass().getSimpleName() + ": " + e.getMessage();
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private static String readAll(HttpURLConnection conn) {
        InputStream in = null;
        try {
            in = conn.getInputStream();
            StringBuilder sb = new StringBuilder();
            byte[] b = new byte[512];
            int n;
            while ((n = in.read(b)) > 0 && sb.length() < 4096) {
                sb.append(new String(b, 0, n, "UTF-8"));
            }
            return sb.toString();
        } catch (Exception e) {
            return null;
        } finally {
            if (in != null) try { in.close(); } catch (Exception ignored) { }
        }
    }

    /** HTTP 头不能带中文/空格，型号名先折成安全 ASCII */
    private static String safeAscii(String s) {
        if (s == null) return "unknown";
        StringBuilder sb = new StringBuilder();
        for (char c : s.toCharArray()) {
            sb.append((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                    || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' ? c : '_');
        }
        return sb.length() == 0 ? "unknown" : sb.toString();
    }
}
