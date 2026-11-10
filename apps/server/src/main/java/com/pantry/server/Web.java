package com.pantry.server;

import android.content.Context;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * 面板的 HTTP 服务，用来替代 busybox httpd。
 *
 * 为什么自己写而不用 busybox：
 *   Android 10 起不允许 exec 应用私有目录里的 ELF 文件，busybox 放 filesDir 会被拒。
 *   而本类只是「起 socket + 解析 HTTP」，纯 Java 没有这个限制。
 *
 * CGI 仍然沿用原来的 3000 多行 shell 脚本，用 /system/bin/sh 执行。
 * 这一点很关键：exec 的是系统自带的 sh（只读、可执行），脚本本身只是参数，
 * 文件放在可写的私有目录里完全合规，不需要 Magisk，也不需要二进制重打包。
 *
 * 与 busybox httpd 的差异（都是往好里改）：
 *   · 多线程，视频和缩略图不会互相卡死；
 *   · 支持 Range，视频能拖进度（httpd 这里一直有问题）；
 *   · 支持 keep-alive，画廊加载少建连接；
 *   · thumb.cgi / vthumb.cgi 由 Java 直接生成，不依赖 ffmpeg。
 */
final class Web {

    private final Context ctx;
    private final int port;
    private ServerSocket server;
    private ExecutorService pool;
    private volatile boolean running;

    /** 单个请求体上限，upload.cgi 自己限 512 MB，这里再兜一层 */
    private static final int MAX_BODY = 256 * 1024 * 1024;
    /** CGI 输出上限，防止脚本失控把内存吃光 */
    private static final int MAX_CGI_OUT = 64 * 1024 * 1024;
    private static final int CGI_TIMEOUT_SEC = 120;

    Web(Context c, int port) {
        this.ctx = c;
        this.port = port;
    }

    String start() throws IOException {
        server = new ServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress(port), 32);
        pool = Executors.newFixedThreadPool(6);
        running = true;
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                acceptLoop();
            }
        }, "pantry-http");
        t.setDaemon(true);
        t.start();
        Env.log(ctx, "HTTP 已监听 0.0.0.0:" + port + "  root=" + Env.wwwDir(ctx));
        return Env.lanIp();
    }

    void stop() {
        running = false;
        try {
            if (server != null) server.close();
        } catch (Exception ignored) {
        }
        if (pool != null) pool.shutdownNow();
        server = null;
        pool = null;
    }

    private void acceptLoop() {
        while (running) {
            Socket s = null;
            try {
                s = server.accept();
                final Socket sock = s;
                if (pool != null) pool.execute(new Runnable() {
                    @Override
                    public void run() {
                        handle(sock);
                    }
                });
            } catch (Exception e) {
                if (running) {
                    // 单个连接出错不能把整个监听带下去
                    try {
                        if (s != null) s.close();
                    } catch (Exception ignored) {
                    }
                } else {
                    break;
                }
            }
        }
    }

    private void handle(Socket s) {
        try {
            s.setSoTimeout(20000);
            s.setTcpNoDelay(true);
            InputStream in = new BufferedInputStream(s.getInputStream(), 16384);
            OutputStream out = new BufferedOutputStream(s.getOutputStream(), 32768);
            String ip = s.getInetAddress() == null ? "?" : s.getInetAddress().getHostAddress();
            // 简单 keep-alive：一次连接最多处理 40 个请求或 60 秒
            long deadline = System.currentTimeMillis() + 60000;
            for (int i = 0; i < 40; i++) {
                if (!handleOne(in, out, ip)) break;
                if (System.currentTimeMillis() > deadline) break;
            }
            out.flush();
        } catch (Exception ignored) {
        } finally {
            try {
                s.close();
            } catch (Exception ignored) {
            }
        }
    }

    /** @return false = 结束这条连接 */
    private boolean handleOne(InputStream in, OutputStream out, String clientIp) throws IOException {
        String line;
        try {
            line = readLine(in);
        } catch (IOException e) {
            return false;
        }
        if (line == null || line.isEmpty()) return false;

        String[] parts = line.split(" ");
        if (parts.length < 2) {
            sendText(out, 400, "Bad Request");
            return false;
        }
        String method = parts[0].toUpperCase(Locale.US);
        String target = parts[1];

        Map<String, String> headers = new HashMap<String, String>();
        int total = 0;
        String h;
        while ((h = readLine(in)) != null && !h.isEmpty()) {
            total += h.length();
            if (total > 32768) {
                sendText(out, 431, "Request Header Fields Too Large");
                return false;
            }
            int c = h.indexOf(':');
            if (c > 0) {
                headers.put(h.substring(0, c).trim().toLowerCase(Locale.US),
                        h.substring(c + 1).trim());
            }
        }

        int clen = parseInt(headers.get("content-length"), 0);
        if (clen > MAX_BODY) {
            sendText(out, 413, "Payload Too Large");
            return false;
        }

        int q = target.indexOf('?');
        String rawPath = q >= 0 ? target.substring(0, q) : target;
        String query = q >= 0 ? target.substring(q + 1) : "";
        String path;
        try {
            path = URLDecoder.decode(rawPath, "UTF-8");
        } catch (Exception e) {
            path = rawPath;
        }
        if (path.isEmpty()) path = "/";
        if (path.equals("/")) path = "/index.html";

        long t0 = System.currentTimeMillis();
        try {
            if (path.startsWith("/cgi/")) {
                String name = path.substring(5);
                if (name.isEmpty() || name.indexOf('/') >= 0 || name.startsWith(".")) {
                    skipFully(in, clen);
                    sendText(out, 404, "Not Found");
                } else if (name.equals("thumb.cgi") || name.equals("vthumb.cgi")) {
                    // 用 Java 出图，不需要 ffmpeg；接口、落盘路径与 thumb.cgi 一致
                    skipFully(in, clen);
                    Thumbs.serve(ctx, out, query, name.equals("vthumb.cgi"));
                } else {
                    // 上传的照片/视频可能有几百 MB，绝不能先读进内存再转发
                    if (!runCgi(out, method, name, query, headers, in, clen, clientIp)) {
                        return false;
                    }
                }
            } else {
                skipFully(in, clen);
                serveStatic(out, method, path, headers);
            }
        } catch (Exception e) {
            Env.log(ctx, "处理 " + method + " " + path + " 出错: " + e);
            try {
                sendText(out, 500, "Server Error");
            } catch (Exception ignored) {
            }
            return false;
        } finally {
            long ms = System.currentTimeMillis() - t0;
            if (ms > 3000) Env.log(ctx, method + " " + path + " 耗时 " + ms + " ms");
        }
        out.flush();
        return true;
    }

    // ───────────────────────── 静态文件 ─────────────────────────

    private void serveStatic(OutputStream out, String method, String path,
                             Map<String, String> headers) throws IOException {
        File www = Env.wwwDir(ctx);
        File f = new File(www, path);
        String base = www.getCanonicalPath();
        String canon = f.getCanonicalPath();
        if (!canon.equals(base) && !canon.startsWith(base + File.separator)) {
            sendText(out, 403, "Forbidden");
            return;
        }
        if (!f.isFile()) {
            sendText(out, 404, "Not Found");
            return;
        }

        long size = f.length();
        String ctype = mime(f.getName());
        long start = 0, end = size - 1;
        boolean partial = false;

        String range = headers.get("range");
        if (range != null && range.startsWith("bytes=")) {
            String spec = range.substring(6).trim();
            int dash = spec.indexOf('-');
            if (dash >= 0) {
                String a = spec.substring(0, dash).trim();
                String b = spec.substring(dash + 1).trim();
                try {
                    if (!a.isEmpty()) {
                        start = Long.parseLong(a);
                        if (!b.isEmpty()) end = Long.parseLong(b);
                    } else if (!b.isEmpty()) {
                        // bytes=-N 取末尾 N 字节
                        long n = Long.parseLong(b);
                        start = Math.max(0, size - n);
                    }
                    if (end >= size) end = size - 1;
                    if (start <= end && start < size) partial = true;
                } catch (NumberFormatException e) {
                    partial = false;
                }
            }
        }

        if (partial) {
            long len = end - start + 1;
            StringBuilder sb = new StringBuilder();
            sb.append("HTTP/1.1 206 Partial Content\r\n");
            sb.append("Content-Type: ").append(ctype).append("\r\n");
            sb.append("Content-Length: ").append(len).append("\r\n");
            sb.append("Content-Range: bytes ").append(start).append('-').append(end)
                    .append('/').append(size).append("\r\n");
            sb.append("Accept-Ranges: bytes\r\n");
            sb.append("Cache-Control: max-age=86400\r\n");
            sb.append("Connection: keep-alive\r\n\r\n");
            out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
            if (!"HEAD".equals(method)) {
                FileInputStream fis = new FileInputStream(f);
                try {
                    skipFully(fis, start);
                    copy(fis, out, len);
                } finally {
                    fis.close();
                }
            }
            return;
        }

        StringBuilder sb = new StringBuilder();
        sb.append("HTTP/1.1 200 OK\r\n");
        sb.append("Content-Type: ").append(ctype).append("\r\n");
        sb.append("Content-Length: ").append(size).append("\r\n");
        sb.append("Accept-Ranges: bytes\r\n");
        sb.append("Cache-Control: max-age=86400\r\n");
        sb.append("Connection: keep-alive\r\n\r\n");
        out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        if (!"HEAD".equals(method)) {
            FileInputStream fis = new FileInputStream(f);
            try {
                copy(fis, out, size);
            } finally {
                fis.close();
            }
        }
    }

    /** 首页和页面依赖的静态资源走缓存，改脚本时靠 ?v= 时间戳破缓存。 */
    static String mime(String name) {
        String n = name.toLowerCase(Locale.US);
        if (n.endsWith(".html") || n.endsWith(".htm")) return "text/html; charset=utf-8";
        if (n.endsWith(".js")) return "application/javascript; charset=utf-8";
        if (n.endsWith(".css")) return "text/css; charset=utf-8";
        if (n.endsWith(".json")) return "application/json; charset=utf-8";
        if (n.endsWith(".jpg") || n.endsWith(".jpeg")) return "image/jpeg";
        if (n.endsWith(".png")) return "image/png";
        if (n.endsWith(".webp")) return "image/webp";
        if (n.endsWith(".gif")) return "image/gif";
        if (n.endsWith(".bmp")) return "image/bmp";
        if (n.endsWith(".heic") || n.endsWith(".heif")) return "image/heic";
        if (n.endsWith(".mp4") || n.endsWith(".m4v")) return "video/mp4";
        if (n.endsWith(".mov")) return "video/quicktime";
        if (n.endsWith(".3gp")) return "video/3gpp";
        if (n.endsWith(".mkv")) return "video/x-matroska";
        if (n.endsWith(".webm")) return "video/webm";
        if (n.endsWith(".svg")) return "image/svg+xml";
        if (n.endsWith(".ico")) return "image/x-icon";
        if (n.endsWith(".woff2")) return "font/woff2";
        if (n.endsWith(".txt") || n.endsWith(".md")) return "text/plain; charset=utf-8";
        return "application/octet-stream";
    }

    // ───────────────────────── CGI ─────────────────────────

    /** @return false = 请求体没被 CGI 读完，这条连接不能复用 */
    private boolean runCgi(OutputStream out, String method, String name, String query,
                           Map<String, String> headers, InputStream bodyIn, long bodyLen,
                           String clientIp) throws IOException {
        File script = new File(new File(Env.wwwDir(ctx), "cgi"), name);
        String base = new File(Env.wwwDir(ctx), "cgi").getCanonicalPath();
        if (!script.getCanonicalPath().startsWith(base + File.separator) || !script.isFile()) {
            skipFully(bodyIn, bodyLen);
            sendText(out, 404, "No such CGI");
            return false;
        }

        ProcessBuilder pb = new ProcessBuilder("/system/bin/sh", script.getAbsolutePath());
        pb.directory(Env.wwwDir(ctx));
        Map<String, String> e = pb.environment();
        e.put("PATH", "/system/bin:/system/xbin");
        e.put("REQUEST_METHOD", method);
        e.put("QUERY_STRING", query);
        e.put("CONTENT_LENGTH", String.valueOf(bodyLen));
        if (headers.containsKey("content-type")) {
            e.put("CONTENT_TYPE", headers.get("content-type"));
        }
        e.put("SCRIPT_NAME", "/cgi/" + name);
        e.put("SCRIPT_FILENAME", script.getAbsolutePath());
        e.put("DOCUMENT_ROOT", Env.wwwDir(ctx).getAbsolutePath());
        e.put("SERVER_PORT", String.valueOf(port));
        e.put("SERVER_PROTOCOL", "HTTP/1.1");
        e.put("SERVER_SOFTWARE", "Pantry/1.0 (Android)");
        e.put("REMOTE_ADDR", clientIp);
        e.put("GATEWAY_INTERFACE", "CGI/1.1");
        // lib-path.sh 第一优先级读这个，脚本因此不用关心自己在哪个目录
        e.put("NASBAK_CONF", Env.confFile(ctx).getAbsolutePath());
        e.put("HOME", Env.runtimeDir(ctx).getAbsolutePath());
        // upload.cgi 的参数全在自定义头里，必须原样转成 HTTP_*
        for (Map.Entry<String, String> en : headers.entrySet()) {
            String k = en.getKey();
            if (k.equals("content-length") || k.equals("content-type")
                    || k.equals("connection") || k.equals("host")) continue;
            e.put("HTTP_" + k.toUpperCase(Locale.US).replace('-', '_'), en.getValue());
        }

        final Process p;
        try {
            p = pb.start();
        } catch (Exception ex) {
            Env.log(ctx, "CGI 起不来 " + name + ": " + ex);
            skipFully(bodyIn, bodyLen);
            sendText(out, 500, "CGI start failed");
            return false;
        }

        final ByteArrayOutputStream ob = new ByteArrayOutputStream();
        final ByteArrayOutputStream eb = new ByteArrayOutputStream();
        Thread t1 = drain(p.getInputStream(), ob, MAX_CGI_OUT);
        Thread t2 = drain(p.getErrorStream(), eb, 256 * 1024);

        // 请求体边读边喂给 CGI，不落内存：一段 200 MB 的视频不能先读成 byte[]
        final long[] sent = {0};
        Thread writer = null;
        if (bodyLen > 0) {
            writer = new Thread(new Runnable() {
                @Override
                public void run() {
                    OutputStream os = null;
                    try {
                        os = p.getOutputStream();
                        byte[] buf = new byte[65536];
                        long left = bodyLen;
                        while (left > 0) {
                            int want = (int) Math.min(buf.length, left);
                            int n = bodyIn.read(buf, 0, want);
                            if (n < 0) break;
                            os.write(buf, 0, n);
                            left -= n;
                            sent[0] += n;
                        }
                        os.flush();
                    } catch (Exception ignored) {
                        // 脚本不读 stdin 就提前退出，写会抛 EPIPE，正常现象
                    } finally {
                        try {
                            if (os != null) os.close();
                        } catch (Exception ignored) {
                        }
                    }
                }
            }, "pantry-cgi-body");
            writer.setDaemon(true);
            writer.start();
        }

        // 上传大文件时按 512 KB/s 额外放宽，别让慢速 WiFi 把正常上传判成超时
        long waitSec = CGI_TIMEOUT_SEC + bodyLen / (512 * 1024);
        boolean finished;
        try {
            finished = p.waitFor(waitSec, TimeUnit.SECONDS);
        } catch (InterruptedException ie) {
            finished = false;
        }
        if (!finished) {
            p.destroyForcibly();
            Env.log(ctx, "CGI 超时 " + name + " " + waitSec + "s");
            sendText(out, 504, "CGI timeout");
            return false;
        }
        if (writer != null) {
            try {
                writer.join(5000);
            } catch (InterruptedException ignored) {
            }
            if (writer.isAlive() || sent[0] < bodyLen) {
                p.destroyForcibly();
                Env.log(ctx, name + " 没读完请求体 " + sent[0] + "/" + bodyLen + "，断开连接");
                sendText(out, 400, "request body not consumed");
                return false;
            }
        }
        try {
            t1.join(2000);
            t2.join(2000);
        } catch (InterruptedException ignored) {
        }

        byte[] raw = ob.toByteArray();
        byte[] errRaw = eb.toByteArray();
        if (errRaw.length > 0) {
            String msg = new String(errRaw, StandardCharsets.UTF_8).trim();
            if (msg.length() > 800) msg = msg.substring(0, 800);
            Env.log(ctx, "CGI " + name + " stderr: " + msg);
        }

        int sep = findHeaderEnd(raw);
        if (sep < 0) {
            // 脚本没输出头，多半是提前报错退出；把 stderr 一起回给页面便于定位
            String msg = new String(raw, StandardCharsets.UTF_8);
            if (errRaw.length > 0) msg += new String(errRaw, StandardCharsets.UTF_8);
            if (msg.trim().isEmpty()) msg = "CGI 没有输出";
            sendText(out, 500, msg.trim());
            return false;
        }

        int skip = (raw[sep] == '\r') ? 4 : 2;
        String head = new String(raw, 0, sep, StandardCharsets.UTF_8);
        String ctype = "text/plain; charset=utf-8";
        String cache = "no-store";
        for (String l : head.split("\r?\n")) {
            int c = l.indexOf(':');
            if (c <= 0) continue;
            String k = l.substring(0, c).trim().toLowerCase(Locale.US);
            String v = l.substring(c + 1).trim();
            if (k.equals("content-type")) ctype = v;
            else if (k.equals("cache-control")) cache = v;
        }
        // 注意别叫 bodyLen：那个名字已经是方法参数（请求体长度），这里是响应体长度
        int respLen = raw.length - sep - skip;
        if (respLen < 0) respLen = 0;

        StringBuilder sb = new StringBuilder();
        sb.append("HTTP/1.1 200 OK\r\n");
        sb.append("Content-Type: ").append(ctype).append("\r\n");
        sb.append("Content-Length: ").append(respLen).append("\r\n");
        sb.append("Cache-Control: ").append(cache).append("\r\n");
        sb.append("Connection: keep-alive\r\n\r\n");
        out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        if (!"HEAD".equals(method) && respLen > 0) {
            out.write(raw, sep + skip, respLen);
        }
        return true;
    }

    private void sendText(OutputStream out, int code, String text) throws IOException {
        byte[] b = (text == null ? "" : text).getBytes(StandardCharsets.UTF_8);
        String reason = code == 400 ? "Bad Request"
                : code == 403 ? "Forbidden"
                : code == 404 ? "Not Found"
                : code == 405 ? "Method Not Allowed"
                : code == 413 ? "Payload Too Large"
                : code == 431 ? "Request Header Fields Too Large"
                : code == 504 ? "Gateway Timeout"
                : code == 500 ? "Internal Server Error" : "Error";
        StringBuilder sb = new StringBuilder();
        sb.append("HTTP/1.1 ").append(code).append(' ').append(reason).append("\r\n");
        sb.append("Content-Type: text/plain; charset=utf-8\r\n");
        sb.append("Content-Length: ").append(b.length).append("\r\n");
        sb.append("Cache-Control: no-store\r\n");
        sb.append("Connection: close\r\n\r\n");
        out.write(sb.toString().getBytes(StandardCharsets.UTF_8));
        out.write(b);
        out.flush();
    }

    // ───────────────────────── 工具 ─────────────────────────

    /** 找头部结束位置，返回 \r 或 \n 的起点；找不到返回 -1 */
    private static int findHeaderEnd(byte[] b) {
        for (int i = 0; i < b.length - 3; i++) {
            if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n') {
                return i;
            }
        }
        for (int i = 0; i < b.length - 1; i++) {
            if (b[i] == '\n' && b[i + 1] == '\n') return i;
        }
        return -1;
    }

    private static String readLine(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int c;
        while ((c = in.read()) >= 0) {
            if (c == '\n') break;
            if (c != '\r') b.write(c);
            if (b.size() > 8192) throw new IOException("header too long");
        }
        if (c < 0 && b.size() == 0) return null;
        return b.toString("UTF-8");
    }

    private static void readFully(InputStream in, byte[] buf) throws IOException {
        int off = 0;
        while (off < buf.length) {
            int r = in.read(buf, off, buf.length - off);
            if (r < 0) throw new EOFException("body truncated");
            off += r;
        }
    }

    private static void skipFully(InputStream in, long n) throws IOException {
        long left = n;
        while (left > 0) {
            long s = in.skip(left);
            if (s <= 0) {
                if (in.read() < 0) return;
                s = 1;
            }
            left -= s;
        }
    }

    private static void copy(InputStream in, OutputStream out, long len) throws IOException {
        byte[] buf = new byte[32768];
        long left = len;
        while (left > 0) {
            int want = (int) Math.min(buf.length, left);
            int n = in.read(buf, 0, want);
            if (n < 0) break;
            out.write(buf, 0, n);
            left -= n;
        }
    }

    private static Thread drain(final InputStream src, final ByteArrayOutputStream dst,
                                final int cap) {
        Thread t = new Thread(new Runnable() {
            @Override
            public void run() {
                byte[] buf = new byte[16384];
                int n;
                try {
                    while ((n = src.read(buf)) > 0) {
                        if (dst.size() < cap) {
                            dst.write(buf, 0, Math.min(n, cap - dst.size()));
                        }
                    }
                } catch (Exception ignored) {
                }
            }
        }, "pantry-cgi-pipe");
        t.setDaemon(true);
        t.start();
        return t;
    }

    private static int parseInt(String s, int def) {
        if (s == null) return def;
        try {
            return Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            return def;
        }
    }
}
