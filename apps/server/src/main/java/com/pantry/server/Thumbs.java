package com.pantry.server;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.MediaMetadataRetriever;
import android.os.Build;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/**
 * thumb.cgi / vthumb.cgi 的 Java 实现。
 *
 * 脚本版依赖 ffmpeg，而服务端 App 里不带二进制；Android 自带的
 * BitmapFactory 和 MediaMetadataRetriever 已经够抽一帧 320px 缩略图。
 * 接口、落盘路径、缓存策略跟脚本版完全一致（state/thumb/<mid>.jpg），
 * 所以两种部署方式混用时，缓存可以互相复用。
 */
final class Thumbs {

    private static final int MAXPX = 320;
    private static final int QUALITY = 60;

    private static final String[] IMG_EXT = {
            "jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif"
    };
    private static final String[] VID_EXT = {
            "mp4", "mov", "3gp", "m4v", "mkv", "webm"
    };

    static void serve(Context ctx, OutputStream out, String query, boolean preferVideo)
            throws IOException {
        String mid = param(query, "mid");
        if (mid == null || mid.length() != 16 || !mid.matches("[0-9a-f]+")) {
            fail(out, "bad mid");
            return;
        }

        File thumbDir = new File(Env.stateDir(), "thumb");
        thumbDir.mkdirs();
        File jpg = new File(thumbDir, mid + ".jpg");

        if (!jpg.isFile() || jpg.length() == 0) {
            File mediaDir = new File(Env.stateDir(), "media");
            // vthumb 先找视频、thumb 先找图片，找不到再全类型兜一遍
            File src = find(mediaDir, mid, preferVideo ? VID_EXT : IMG_EXT);
            if (src == null) src = find(mediaDir, mid, null);
            if (src == null) {
                fail(out, "media not found");
                return;
            }
            if (!render(src, jpg)) {
                fail(out, "decode failed");
                return;
            }
        }

        long len = jpg.length();
        StringBuilder sb = new StringBuilder();
        sb.append("HTTP/1.1 200 OK\r\n");
        sb.append("Content-Type: image/jpeg\r\n");
        sb.append("Content-Length: ").append(len).append("\r\n");
        sb.append("Cache-Control: max-age=604800\r\n");
        sb.append("Connection: keep-alive\r\n\r\n");
        out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        FileInputStream in = new FileInputStream(jpg);
        try {
            byte[] buf = new byte[16384];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        } finally {
            in.close();
        }
    }

    /** 按扩展名找 state/media/<mid>.<ext>；exts 为 null 表示不限 */
    private static File find(File dir, String mid, String[] exts) {
        for (String e : (exts == null ? concat() : exts)) {
            File f = new File(dir, mid + "." + e);
            if (f.isFile() && f.length() > 0) return f;
        }
        return null;
    }

    private static String[] concat() {
        String[] all = new String[IMG_EXT.length + VID_EXT.length];
        System.arraycopy(IMG_EXT, 0, all, 0, IMG_EXT.length);
        System.arraycopy(VID_EXT, 0, all, IMG_EXT.length, VID_EXT.length);
        return all;
    }

    private static boolean render(File src, File dst) {
        String ext = ext(src.getName());
        boolean video = false;
        for (String v : VID_EXT) {
            if (v.equals(ext)) {
                video = true;
                break;
            }
        }
        Bitmap bm = video ? videoFrame(src) : imageBitmap(src);
        if (bm == null) return false;

        Bitmap scaled = scaleTo(bm, MAXPX);
        if (scaled != bm) bm.recycle();

        File tmp = new File(dst.getParentFile(), dst.getName() + ".part");
        FileOutputStream fos = null;
        try {
            fos = new FileOutputStream(tmp);
            boolean ok = scaled.compress(Bitmap.CompressFormat.JPEG, QUALITY, fos);
            fos.flush();
            fos.close();
            fos = null;
            scaled.recycle();
            if (!ok) {
                tmp.delete();
                return false;
            }
            if (tmp.renameTo(dst)) return true;
            tmp.delete();
            return false;
        } catch (Exception e) {
            return false;
        } finally {
            if (fos != null) try {
                fos.close();
            } catch (Exception ignored) {
            }
            if (tmp.exists() && !dst.exists()) tmp.delete();
        }
    }

    private static Bitmap imageBitmap(File src) {
        try {
            BitmapFactory.Options probe = new BitmapFactory.Options();
            probe.inJustDecodeBounds = true;
            BitmapFactory.decodeFile(src.getAbsolutePath(), probe);
            if (probe.outWidth <= 0 || probe.outHeight <= 0) return null;

            int sample = 1;
            int maxSide = Math.max(probe.outWidth, probe.outHeight);
            while (maxSide / (sample * 2) >= MAXPX) sample *= 2;

            BitmapFactory.Options o = new BitmapFactory.Options();
            o.inSampleSize = sample;
            o.inPreferredConfig = Bitmap.Config.RGB_565;
            return BitmapFactory.decodeFile(src.getAbsolutePath(), o);
        } catch (Throwable t) {
            return null;
        }
    }

    private static Bitmap videoFrame(File src) {
        MediaMetadataRetriever r = new MediaMetadataRetriever();
        try {
            r.setDataSource(src.getAbsolutePath());
            long durUs = 0;
            String d = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            if (d != null) {
                try {
                    durUs = Long.parseLong(d) * 1000L;
                } catch (NumberFormatException ignored) {
                }
            }
            // 取 10% 处避开开头黑场，最多 5 秒
            long at = durUs > 0 ? Math.min(durUs / 10, 5000000L) : 0;

            Bitmap bm = null;
            if (Build.VERSION.SDK_INT >= 27) {
                int vw = intMeta(r, MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH);
                int vh = intMeta(r, MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT);
                if (vw > 0 && vh > 0) {
                    float sc = (float) MAXPX / Math.max(vw, vh);
                    int tw = Math.max(1, (int) (vw * sc));
                    int th = Math.max(1, (int) (vh * sc));
                    bm = r.getScaledFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC, tw, th);
                }
            }
            if (bm == null) bm = r.getFrameAtTime(at, MediaMetadataRetriever.OPTION_CLOSEST_SYNC);
            if (bm == null) bm = r.getFrameAtTime(0);
            return bm;
        } catch (Throwable t) {
            return null;
        } finally {
            try {
                r.release();
            } catch (Exception ignored) {
            }
        }
    }

    private static int intMeta(MediaMetadataRetriever r, int key) {
        try {
            String s = r.extractMetadata(key);
            return s == null ? 0 : Integer.parseInt(s);
        } catch (Exception e) {
            return 0;
        }
    }

    private static Bitmap scaleTo(Bitmap bm, int max) {
        int w = bm.getWidth(), h = bm.getHeight();
        int side = Math.max(w, h);
        if (side <= max) return bm;
        float sc = (float) max / side;
        int tw = Math.max(1, Math.round(w * sc));
        int th = Math.max(1, Math.round(h * sc));
        return Bitmap.createScaledBitmap(bm, tw, th, true);
    }

    private static String ext(String name) {
        int i = name.lastIndexOf('.');
        return i < 0 ? "" : name.substring(i + 1).toLowerCase(Locale.US);
    }

    private static String param(String query, String key) {
        if (query == null || query.isEmpty()) return null;
        for (String kv : query.split("&")) {
            int e = kv.indexOf('=');
            if (e > 0 && kv.substring(0, e).equals(key)) {
                return kv.substring(e + 1);
            }
        }
        return null;
    }

    /** 与 thumb.cgi 一致：不返回图片而是 JSON，<img> 的 onerror 会兜住 */
    private static void fail(OutputStream out, String err) throws IOException {
        byte[] b = ("{\"ok\":false,\"err\":\"" + err + "\"}\n")
                .getBytes(StandardCharsets.UTF_8);
        String sb = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json; charset=utf-8\r\n"
                + "Content-Length: " + b.length + "\r\n"
                + "Cache-Control: no-store\r\n"
                + "Connection: keep-alive\r\n\r\n";
        out.write(sb.getBytes(StandardCharsets.UTF_8));
        out.write(b);
    }

    private Thumbs() {
    }
}
