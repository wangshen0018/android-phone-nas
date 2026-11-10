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
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * 把本机的照片/视频增量送进库房。
 *
 * 只做三件事：读 MediaStore、按 id+修改时间跳过已传的、HTTP POST 原始字节。
 * 1.8 起把相册名、稳定去重键和真正的拍摄时间一起交给服务端：文件按相册分目录收，
 * 归位脚本把文件搬走之后也不会被误判成「没传过」而让整批照片重传。
 * 不常驻、不开前台服务、不引 AndroidX —— 打开 App 时跑一轮，跑完就结束。
 * 国产 ROM 的后台限制躲不掉，与其假装能 7x24 自动备份，不如让用户看得见地传一次。
 *
 * 备份范围由用户勾选的文件夹（MediaStore 的 bucket_display_name）决定，
 * 不勾选就一张都不传；截图、微信缓存图那些文件夹不会被悄悄搬走。
 * 开关默认关：装到家人手机上只是看照片，不能悄悄把人家相册搬走。
 */
public class Backup {

    public static final String PREF = "nasbak";
    public static final String KEY_ON = "backupOn";
    public static final String KEY_DONE = "backupDone";
    public static final String KEY_BUCKETS = "backupBuckets";
    /** 最近一轮同步的结果，给「备份状态」页看 */
    public static final String KEY_LAST_AT = "backupLastAt";
    public static final String KEY_LAST_UP = "backupLastUp";
    public static final String KEY_LAST_SKIP = "backupLastSkip";
    public static final String KEY_LAST_FAIL = "backupLastFail";
    public static final String KEY_LAST_ERR = "backupLastErr";
    public static final String KEY_TOTAL = "backupTotal";
    /** 不用常量，minSdk 24 上 MediaColumns 里不一定有 BUCKET_* */
    private static final String COL_BUCKET = "bucket_display_name";

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

    public static class Bucket {
        public String name;
        public int count;
        public long bytes;
    }

    /** 列出本机相册文件夹，按张数降序；只统计够大、会被备份的文件 */
    public static List<Bucket> listBuckets(Context c) {
        Map<String, Bucket> map = new LinkedHashMap<String, Bucket>();
        String[] proj = {"_id", MediaStore.MediaColumns.SIZE, COL_BUCKET};
        Uri[] tables = {MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                         MediaStore.Video.Media.EXTERNAL_CONTENT_URI};
        for (Uri table : tables) {
            Cursor cur = null;
            try {
                cur = c.getContentResolver().query(table, proj, null, null, null);
                if (cur == null) continue;
                int iBucket = cur.getColumnIndex(COL_BUCKET);
                int iSize = cur.getColumnIndex(MediaStore.MediaColumns.SIZE);
                while (cur.moveToNext()) {
                    long sz = iSize >= 0 ? cur.getLong(iSize) : 0;
                    if (sz < MIN_SIZE) continue;
                    String bn = iBucket >= 0 ? cur.getString(iBucket) : null;
                    if (bn == null || bn.isEmpty()) bn = "（未命名）";
                    Bucket b = map.get(bn);
                    if (b == null) {
                        b = new Bucket();
                        b.name = bn;
                        map.put(bn, b);
                    }
                    b.count++;
                    b.bytes += sz;
                }
            } catch (Exception ignored) {
                // 某个表读不到就跳过，另一个还能列
            } finally {
                if (cur != null) try { cur.close(); } catch (Exception ignored) { }
            }
        }
        List<Bucket> out = new ArrayList<Bucket>(map.values());
        Collections.sort(out, new Comparator<Bucket>() {
            @Override
            public int compare(Bucket a, Bucket b) { return b.count - a.count; }
        });
        return out;
    }

    public static Set<String> loadBuckets(SharedPreferences sp) {
        Set<String> set = new HashSet<String>();
        String raw = sp.getString(KEY_BUCKETS, "");
        if (raw == null || raw.isEmpty()) return set;
        for (String k : raw.split("\n")) {
            if (!k.isEmpty()) set.add(k);
        }
        return set;
    }

    public static void saveBuckets(SharedPreferences sp, Set<String> set) {
        StringBuilder sb = new StringBuilder();
        for (String k : set) {
            if (sb.length() > 0) sb.append('\n');
            sb.append(k);
        }
        sp.edit().putString(KEY_BUCKETS, sb.toString()).apply();
    }

    public static String fmtSize(long b) {
        if (b < 1024) return b + " B";
        if (b < 1024L * 1024) return String.format(Locale.US, "%.0f KB", b / 1024.0);
        if (b < 1024L * 1024 * 1024) return String.format(Locale.US, "%.1f MB", b / (1024.0 * 1024));
        return String.format(Locale.US, "%.1f GB", b / (1024.0 * 1024 * 1024));
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
        long id;
        long modified;
        long taken;
        long size;
        String key;
        String bucket;
        String stableId;
    }

    private static void collect(ContentResolver cr, Uri table, String takenCol,
                                Set<String> buckets, List<Item> out) {
        String[] proj = {
                MediaStore.MediaColumns._ID,
                MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.DATE_MODIFIED,
                MediaStore.MediaColumns.SIZE,
                COL_BUCKET,
                takenCol
        };
        String sort = MediaStore.MediaColumns.DATE_MODIFIED + " DESC";
        Cursor cur = null;
        try {
            try {
                cur = cr.query(table, proj, null, null, sort);
            } catch (IllegalArgumentException e1) {
                // 少数 ROM 的 MediaProvider 不认拍摄时间列；去掉最后一列重查，
                // 不能让一张照片都查不出来，拍摄时间退回用修改时间兜底
                String[] proj2 = new String[proj.length - 1];
                System.arraycopy(proj, 0, proj2, 0, proj2.length);
                cur = cr.query(table, proj2, null, null, sort);
            }
            if (cur == null) return;
            int iId = cur.getColumnIndexOrThrow(MediaStore.MediaColumns._ID);
            int iName = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME);
            int iMod = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED);
            int iSize = cur.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE);
            int iBucket = cur.getColumnIndex(COL_BUCKET);
            int iTaken = cur.getColumnIndex(takenCol);
            while (cur.moveToNext()) {
                long size = cur.getLong(iSize);
                if (size < MIN_SIZE) continue;
                String name = cur.getString(iName);
                if (name == null || name.isEmpty()) continue;
                String bk = iBucket >= 0 ? cur.getString(iBucket) : null;
                if (bk == null || bk.isEmpty()) bk = "（未命名）";
                if (!buckets.contains(bk)) continue;
                Item it = new Item();
                it.id = cur.getLong(iId);
                it.uri = ContentUris.withAppendedId(table, it.id);
                it.name = name;
                it.modified = cur.getLong(iMod);
                // DATE_TAKEN 是毫秒、DATE_MODIFIED 是秒；没有 EXIF 时间的视频会取到 0
                long takenMs = iTaken >= 0 ? cur.getLong(iTaken) : 0;
                it.taken = takenMs > 0 ? takenMs / 1000 : it.modified;
                it.size = size;
                it.key = it.id + ":" + it.modified;
                it.bucket = bk;
                // 服务端的稳定去重键：换手机/清 App 数据也不会把已归档的照片重传一遍；
                // 带上相册 hash 是为了让不同相册里的同名文件各自算一份
                it.stableId = safeAscii(Build.MODEL) + "-"
                        + Integer.toHexString(bk.hashCode()) + "-"
                        + it.id + "-" + it.modified + "-" + it.size;
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
            noteFailure(ctx, "面板地址不对，先找到库房");
            cb.onDone(0, 0, 0, "面板地址不对，先找到库房");
            return;
        }
        new Thread(new Runnable() {
            @Override
            public void run() {
                final SharedPreferences sp = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE);
                Set<String> buckets = loadBuckets(sp);
                if (buckets.isEmpty()) {
                    noteFailure(ctx, "还没选要备份的文件夹");
                    cb.onDone(0, 0, 0, "还没选要备份的文件夹");
                    return;
                }
                Set<String> done = loadDone(sp);
                List<Item> all = new ArrayList<Item>();
                collect(ctx.getContentResolver(), MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                        MediaStore.Images.Media.DATE_TAKEN, buckets, all);
                collect(ctx.getContentResolver(), MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                        MediaStore.Video.Media.DATE_TAKEN, buckets, all);

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
                // 结果落到 prefs，「备份状态」页随时能看；失败原因只留第一条，够定位问题
                sp.edit()
                        .putLong(KEY_LAST_AT, System.currentTimeMillis())
                        .putInt(KEY_LAST_UP, uploaded)
                        .putInt(KEY_LAST_SKIP, skipped)
                        .putInt(KEY_LAST_FAIL, failed)
                        .putString(KEY_LAST_ERR, firstErr == null ? "" : firstErr)
                        .putInt(KEY_TOTAL, sp.getInt(KEY_TOTAL, 0) + uploaded)
                        .apply();
                cb.onDone(uploaded, skipped, failed, firstErr);
            }
        }, "pantry-backup").start();
    }

    /** 没跑起来也要留下痕迹，否则静默同步的失败在「备份状态」里查不到 */
    private static void noteFailure(Context ctx, String err) {
        SharedPreferences sp = ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE);
        sp.edit().putLong(KEY_LAST_AT, System.currentTimeMillis())
                .putInt(KEY_LAST_UP, 0)
                .putInt(KEY_LAST_SKIP, 0)
                .putInt(KEY_LAST_FAIL, 1)
                .putString(KEY_LAST_ERR, err).apply();
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
            conn.setRequestProperty("X-Pantry-Name", b64(it.name));
            conn.setRequestProperty("X-Pantry-Bucket", b64(it.bucket));
            conn.setRequestProperty("X-Pantry-Id", it.stableId);
            conn.setRequestProperty("X-Pantry-Dev", safeAscii(Build.MODEL));
            conn.setRequestProperty("X-Pantry-Taken", String.valueOf(it.taken));
            // 旧版 upload.cgi 只认 Shot，留着兼容；新版优先用 Taken 还原拍摄时间
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

    /** HTTP 头不能带中文，文件名和相册名统一转 base64 */
    private static String b64(String s) {
        return Base64.encodeToString(s.getBytes(Charset.forName("UTF-8")), Base64.NO_WRAP);
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
