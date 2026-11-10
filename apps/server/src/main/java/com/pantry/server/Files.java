package com.pantry.server;

import java.io.File;
import java.net.URLDecoder;
import java.util.Arrays;
import java.util.Comparator;

/**
 * 轻量文件浏览。原来靠 alist（119 MB 的 Go 二进制 + 一份 data.db），
 * App 版用 Java 直接列目录，配合 Web 的 /dl/ 路径做带 Range 的下载。
 *
 * 只做三件事：列当前目录、给出上级、给出下载链接。
 * 不提供删除/重命名/上传——那些在判定页和归档流程里有专门的入口，
 * 让文件浏览器有写权限反而容易误删账本。
 */
final class Files {
    private Files() {
    }

    static String listJson(String query) {
        String rel = param(query, "d");
        File root = Env.storeDir();
        File dir = resolve(root, rel);
        if (dir == null || !dir.isDirectory()) {
            return "{\"error\":\"目录不存在或不允许访问\"}";
        }
        String canonRoot = canon(root);
        String canonDir = canon(dir);
        String shown = canonDir.equals(canonRoot) ? ""
                : canonDir.substring(canonRoot.length() + 1).replace('\\', '/');
        String parent = "";
        if (!shown.isEmpty()) {
            int i = shown.lastIndexOf('/');
            parent = i < 0 ? "" : shown.substring(0, i);
        }

        File[] items = dir.listFiles();
        if (items == null) items = new File[0];
        Arrays.sort(items, new Comparator<File>() {
            @Override
            public int compare(File a, File b) {
                if (a.isDirectory() != b.isDirectory()) return a.isDirectory() ? -1 : 1;
                return a.getName().compareToIgnoreCase(b.getName());
            }
        });

        StringBuilder sb = new StringBuilder();
        sb.append("{\"path\":").append(q(shown))
                .append(",\"parent\":").append(q(parent))
                .append(",\"items\":[");
        boolean first = true;
        for (File f : items) {
            String n = f.getName();
            if (n.startsWith(".")) continue;          // 元数据、上传半成品不列
            if (!first) sb.append(',');
            first = false;
            String child = shown.isEmpty() ? n : shown + "/" + n;
            sb.append("{\"name\":").append(q(n))
                    .append(",\"dir\":").append(f.isDirectory())
                    .append(",\"size\":").append(f.isDirectory() ? 0 : f.length())
                    .append(",\"mtime\":").append(f.lastModified() / 1000)
                    .append(",\"url\":").append(q("/dl/" + child))
                    .append('}');
        }
        sb.append("]}");
        return sb.toString();
    }

    /** 把 CGI 的 d= 参数解析成 root 内的路径；越界一律拒绝。 */
    static File resolve(File root, String rel) {
        try {
            String canonRoot = canon(root);
            File f = new File(root, rel == null ? "" : rel);
            String c = canon(f);
            if (!c.equals(canonRoot) && !c.startsWith(canonRoot + File.separator)) return null;
            return f;
        } catch (Exception e) {
            return null;
        }
    }

    private static String canon(File f) {
        try {
            return f.getCanonicalPath();
        } catch (Exception e) {
            return f.getAbsolutePath();
        }
    }

    private static String param(String query, String key) {
        if (query == null) return "";
        for (String p : query.split("&")) {
            int i = p.indexOf('=');
            String k = i < 0 ? p : p.substring(0, i);
            if (!k.equals(key)) continue;
            String v = i < 0 ? "" : p.substring(i + 1);
            try {
                return URLDecoder.decode(v, "UTF-8");
            } catch (Exception e) {
                return v;
            }
        }
        return "";
    }

    private static String q(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        return b.append('"').toString();
    }
}
