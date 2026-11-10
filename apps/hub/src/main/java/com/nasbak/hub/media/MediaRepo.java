package com.nasbak.hub.media;

import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.MediaStore;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * 照片/视频仓库：只做一件事——从 MediaStore 读出「这台手机上现有的媒体」。
 *
 * 为什么不用文件遍历：Android 11+ 分区存储下，直接读 /storage/emulated/0 需要
 * 全盘权限，而且扫 5000 个文件要 20 秒；MediaStore 是系统索引，同样的量级
 * 一个 Cursor 就出来了，还能拿到尺寸和时长。
 */
public final class MediaRepo {

    public static final class Item {
        public long id;
        public String name = "";
        public String mime = "";
        public long size;
        public long dateSec;      // DATE_ADDED，秒
        public int width;
        public int height;
        public long durationMs;   // 视频时长
        public boolean video;

        public String toJson() {
            StringBuilder b = new StringBuilder(192);
            b.append('{')
                    .append("\"id\":").append(id)
                    .append(",\"name\":").append(quote(name))
                    .append(",\"mime\":").append(quote(mime))
                    .append(",\"size\":").append(size)
                    .append(",\"date\":").append(dateSec)
                    .append(",\"w\":").append(width)
                    .append(",\"h\":").append(height)
                    .append(",\"dur\":").append(durationMs)
                    .append(",\"video\":").append(video)
                    .append('}');
            return b.toString();
        }

        private static String quote(String s) {
            if (s == null) return "\"\"";
            StringBuilder b = new StringBuilder(s.length() + 8).append('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                if (c == '"' || c == '\\') b.append('\\').append(c);
                else if (c < 0x20) b.append(' ');
                else b.append(c);
            }
            return b.append('"').toString();
        }
    }

    private static Uri uri(boolean video) {
        return video ? MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                : MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
    }

    private static String[] cols(boolean video) {
        if (video) {
            return new String[]{
                    MediaStore.Video.Media._ID,
                    MediaStore.Video.Media.DISPLAY_NAME,
                    MediaStore.Video.Media.SIZE,
                    MediaStore.Video.Media.DATE_ADDED,
                    MediaStore.Video.Media.WIDTH,
                    MediaStore.Video.Media.HEIGHT,
                    MediaStore.Video.Media.MIME_TYPE,
                    MediaStore.Video.Media.DURATION
            };
        }
        return new String[]{
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.SIZE,
                MediaStore.Images.Media.DATE_ADDED,
                MediaStore.Images.Media.WIDTH,
                MediaStore.Images.Media.HEIGHT,
                MediaStore.Images.Media.MIME_TYPE
        };
    }

    /** 按加入时间倒序分页取。kind = "image" | "video" */
    public static List<Item> list(Context ctx, boolean video, int offset, int limit) {
        List<Item> out = new ArrayList<>();
        ContentResolver cr = ctx.getContentResolver();
        String[] c = cols(video);
        String order = MediaStore.MediaColumns.DATE_ADDED + " DESC";
        try (Cursor cur = cr.query(uri(video), c, null, null, order)) {
            if (cur == null) return out;
            int iId = cur.getColumnIndexOrThrow(c[0]);
            int iName = cur.getColumnIndexOrThrow(c[1]);
            int iSize = cur.getColumnIndexOrThrow(c[2]);
            int iDate = cur.getColumnIndexOrThrow(c[3]);
            int iW = cur.getColumnIndexOrThrow(c[4]);
            int iH = cur.getColumnIndexOrThrow(c[5]);
            int iMime = cur.getColumnIndexOrThrow(c[6]);
            int iDur = video ? cur.getColumnIndexOrThrow(c[7]) : -1;

            int skipped = 0;
            while (cur.moveToNext() && out.size() < limit) {
                if (skipped++ < offset) continue;
                Item it = new Item();
                it.id = cur.getLong(iId);
                it.name = cur.getString(iName) == null ? "" : cur.getString(iName);
                it.size = cur.getLong(iSize);
                it.dateSec = cur.getLong(iDate);
                it.width = cur.getInt(iW);
                it.height = cur.getInt(iH);
                it.mime = cur.getString(iMime) == null ? "" : cur.getString(iMime);
                it.durationMs = iDur >= 0 ? cur.getLong(iDur) : 0;
                it.video = video;
                out.add(it);
            }
        } catch (Exception ignored) {
        }
        return out;
    }

    public static int count(Context ctx, boolean video) {
        try (Cursor cur = ctx.getContentResolver().query(uri(video),
                new String[]{MediaStore.MediaColumns._ID}, null, null, null)) {
            return cur == null ? 0 : cur.getCount();
        } catch (Exception e) {
            return 0;
        }
    }

    public static Item find(Context ctx, long id, boolean video) {
        ContentResolver cr = ctx.getContentResolver();
        String[] c = cols(video);
        try (Cursor cur = cr.query(uri(video), c,
                MediaStore.MediaColumns._ID + "=?", new String[]{String.valueOf(id)}, null)) {
            if (cur == null || !cur.moveToNext()) return null;
            Item it = new Item();
            it.id = cur.getLong(cur.getColumnIndexOrThrow(c[0]));
            it.name = cur.getString(cur.getColumnIndexOrThrow(c[1]));
            it.size = cur.getLong(cur.getColumnIndexOrThrow(c[2]));
            it.dateSec = cur.getLong(cur.getColumnIndexOrThrow(c[3]));
            it.width = cur.getInt(cur.getColumnIndexOrThrow(c[4]));
            it.height = cur.getInt(cur.getColumnIndexOrThrow(c[5]));
            it.mime = cur.getString(cur.getColumnIndexOrThrow(c[6]));
            it.durationMs = video ? cur.getLong(cur.getColumnIndexOrThrow(c[7])) : 0;
            it.video = video;
            return it;
        } catch (Exception e) {
            return null;
        }
    }

    public static Uri contentUri(long id, boolean video) {
        return ContentUris.withAppendedId(uri(video), id);
    }

    public static InputStream open(Context ctx, long id, boolean video) throws Exception {
        return ctx.getContentResolver().openInputStream(contentUri(id, video));
    }
}
