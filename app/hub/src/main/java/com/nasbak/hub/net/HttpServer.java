package com.nasbak.hub.net;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
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
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 极简 HTTP/1.1 服务器。
 *
 * 为什么自己写而不是引 NanoHTTPD / Ktor：
 * 这个 App 的对外接口只有「列表 / 取图 / 取原文件 / 上传」四个，
 * 引一个框架反而带来依赖体积和版本冲突风险。这里 400 行覆盖全部需求，
 * 且能精确控制 Range（视频拖动）和流式上传（不把大文件读进内存）。
 *
 * 线程模型：主线程 accept，8 个 worker 处理请求。单请求超时 30 秒。
 */
public final class HttpServer {

    public interface Handler {
        void handle(Req req, Res res) throws Exception;
    }

    private final int port;
    private final Handler handler;
    private final ExecutorService pool = Executors.newFixedThreadPool(8);
    private final AtomicInteger live = new AtomicInteger();

    private volatile boolean running;
    private ServerSocket server;
    private Thread accepter;

    public HttpServer(int port, Handler handler) {
        this.port = port;
        this.handler = handler;
    }

    public int getPort() {
        return port;
    }

    public synchronized void start() throws IOException {
        if (running) return;
        server = new ServerSocket();
        server.setReuseAddress(true);
        server.bind(new InetSocketAddress(port), 32);
        running = true;
        accepter = new Thread(() -> {
            while (running) {
                try {
                    final Socket s = server.accept();
                    s.setSoTimeout(30_000);
                    pool.execute(() -> serve(s));
                } catch (IOException e) {
                    if (running) {
                        // accept 出错通常是端口被抢或 socket 关掉了，退出循环避免空转
                        running = false;
                    }
                    return;
                }
            }
        }, "http-accept");
        accepter.start();
    }

    public synchronized void stop() {
        running = false;
        try {
            if (server != null) server.close();
        } catch (IOException ignored) {
        }
        server = null;
        accepter = null;
    }

    public boolean isRunning() {
        return running;
    }

    public int liveConnections() {
        return live.get();
    }

    private void serve(Socket socket) {
        live.incrementAndGet();
        try (Socket s = socket) {
            InputStream in = new BufferedInputStream(s.getInputStream(), 16 * 1024);
            OutputStream out = new BufferedOutputStream(s.getOutputStream(), 32 * 1024);

            Req req = Req.parse(in);
            if (req == null) return;

            Res res = new Res(out, req.headOnly);
            try {
                handler.handle(req, res);
            } catch (Exception e) {
                if (!res.committed) {
                    res.status(500).json("{\"ok\":false,\"err\":" + quote(String.valueOf(e.getMessage())) + "}");
                }
            }
            res.finish();
            out.flush();
        } catch (Exception ignored) {
            // 客户端中途断开是常态（图片懒加载、用户关页面），不值得记日志
        } finally {
            live.decrementAndGet();
        }
    }

    static String quote(String s) {
        if (s == null) return "null";
        StringBuilder b = new StringBuilder(s.length() + 16);
        b.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default:
                    if (c < 0x20) b.append(String.format(Locale.US, "\\u%04x", (int) c));
                    else b.append(c);
            }
        }
        return b.append('"').toString();
    }

    // ==================== 请求 ====================

    public static final class Req {
        public String method = "GET";
        public String path = "/";
        public String rawQuery = "";
        public final Map<String, String> headers = new HashMap<>();
        public final Map<String, String> query = new HashMap<>();
        public long contentLength;
        public InputStream body;
        public String remote;
        public boolean headOnly;

        static Req parse(InputStream in) throws IOException {
            String line = readLine(in);
            if (line == null || line.isEmpty()) return null;
            String[] parts = line.split(" ");
            if (parts.length < 2) return null;

            Req r = new Req();
            r.method = parts[0].toUpperCase(Locale.US);
            String target = parts[1];

            int q = target.indexOf('?');
            if (q >= 0) {
                r.path = target.substring(0, q);
                r.rawQuery = target.substring(q + 1);
            } else {
                r.path = target;
            }
            r.path = URLDecoder.decode(r.path, "UTF-8");
            parseQuery(r.rawQuery, r.query);

            String h;
            while ((h = readLine(in)) != null && !h.isEmpty()) {
                int c = h.indexOf(':');
                if (c > 0) {
                    r.headers.put(h.substring(0, c).trim().toLowerCase(Locale.US), h.substring(c + 1).trim());
                }
            }
            String cl = r.headers.get("content-length");
            if (cl != null) {
                try {
                    r.contentLength = Long.parseLong(cl.trim());
                } catch (NumberFormatException ignored) {
                }
            }
            r.body = in;
            r.headOnly = "HEAD".equals(r.method);
            return r;
        }

        static void parseQuery(String raw, Map<String, String> into) {
            if (raw == null || raw.isEmpty()) return;
            for (String kv : raw.split("&")) {
                if (kv.isEmpty()) continue;
                int e = kv.indexOf('=');
                try {
                    if (e < 0) {
                        into.put(URLDecoder.decode(kv, "UTF-8"), "");
                    } else {
                        into.put(URLDecoder.decode(kv.substring(0, e), "UTF-8"),
                                URLDecoder.decode(kv.substring(e + 1), "UTF-8"));
                    }
                } catch (Exception ignored) {
                }
            }
        }

        public String q(String k) {
            return query.get(k);
        }

        public String q(String k, String def) {
            String v = query.get(k);
            return v == null || v.isEmpty() ? def : v;
        }

        public int qInt(String k, int def) {
            try {
                return Integer.parseInt(q(k, String.valueOf(def)));
            } catch (Exception e) {
                return def;
            }
        }

        public String cookie(String name) {
            String c = headers.get("cookie");
            if (c == null) return null;
            for (String part : c.split(";")) {
                String t = part.trim();
                if (t.startsWith(name + "=")) return t.substring(name.length() + 1);
            }
            return null;
        }

        private static String readLine(InputStream in) throws IOException {
            ByteArrayOutputStream b = new ByteArrayOutputStream(128);
            int c;
            while ((c = in.read()) != -1) {
                if (c == '\n') {
                    byte[] a = b.toByteArray();
                    int len = a.length;
                    if (len > 0 && a[len - 1] == '\r') len--;
                    return new String(a, 0, len, StandardCharsets.UTF_8);
                }
                b.write(c);
                if (b.size() > 8192) break;
            }
            return b.size() == 0 ? null : b.toString("UTF-8");
        }
    }

    // ==================== 响应 ====================

    public static final class Res {
        private final OutputStream out;
        private final boolean headOnly;

        int status = 200;
        private final Map<String, String> headers = new HashMap<>();
        boolean committed;

        Res(OutputStream out, boolean headOnly) {
            this.out = out;
            this.headOnly = headOnly;
        }

        public Res status(int code) {
            this.status = code;
            return this;
        }

        public Res header(String k, String v) {
            headers.put(k, v);
            return this;
        }

        private String reason() {
            switch (status) {
                case 200: return "OK";
                case 206: return "Partial Content";
                case 300: return "Multiple Choices";
                case 302: return "Found";
                case 304: return "Not Modified";
                case 400: return "Bad Request";
                case 401: return "Unauthorized";
                case 404: return "Not Found";
                case 405: return "Method Not Allowed";
                case 413: return "Payload Too Large";
                case 500: return "Internal Server Error";
                default: return "OK";
            }
        }

        private void writeHead(long len) throws IOException {
            StringBuilder h = new StringBuilder(256);
            h.append("HTTP/1.1 ").append(status).append(' ').append(reason()).append("\r\n");
            if (!headers.containsKey("Content-Type")) headers.put("Content-Type", "text/plain; charset=utf-8");
            for (Map.Entry<String, String> e : headers.entrySet()) {
                h.append(e.getKey()).append(": ").append(e.getValue()).append("\r\n");
            }
            h.append("Content-Length: ").append(len).append("\r\n");
            h.append("Connection: close\r\n\r\n");
            out.write(h.toString().getBytes(StandardCharsets.UTF_8));
            committed = true;
        }

        public void json(String s) throws IOException {
            header("Content-Type", "application/json; charset=utf-8");
            header("Cache-Control", "no-store");
            byte[] b = s.getBytes(StandardCharsets.UTF_8);
            writeHead(b.length);
            if (!headOnly) out.write(b);
            out.flush();
        }

        public void text(String s) throws IOException {
            header("Content-Type", "text/plain; charset=utf-8");
            byte[] b = s.getBytes(StandardCharsets.UTF_8);
            writeHead(b.length);
            if (!headOnly) out.write(b);
            out.flush();
        }

        public void html(String s) throws IOException {
            header("Content-Type", "text/html; charset=utf-8");
            header("Cache-Control", "no-cache");
            byte[] b = s.getBytes(StandardCharsets.UTF_8);
            writeHead(b.length);
            if (!headOnly) out.write(b);
            out.flush();
        }

        public void bytes(byte[] b, String type) throws IOException {
            header("Content-Type", type);
            writeHead(b.length);
            if (!headOnly) out.write(b);
            out.flush();
        }

        public void redirect(String location) throws IOException {
            status(302);
            header("Location", location);
            writeHead(0);
            out.flush();
        }

        /**
         * 输出文件，支持 Range（视频拖动进度条必需）。
         * rangeHeader 传 null 表示整段输出；格式非法时退化成整段，不报错。
         */
        public void file(File f, String type, String rangeHeader, boolean cacheForever) throws IOException {
            long total = f.length();
            long start = 0;
            long end = total - 1;
            boolean partial = false;

            if (rangeHeader != null && rangeHeader.startsWith("bytes=")) {
                String spec = rangeHeader.substring(6).trim();
                int dash = spec.indexOf('-');
                if (dash > 0 || (dash == 0 && spec.length() > 1)) {
                    try {
                        if (dash == 0) {
                            long tail = Long.parseLong(spec.substring(1));
                            start = Math.max(0, total - tail);
                        } else {
                            start = Long.parseLong(spec.substring(0, dash));
                            if (dash < spec.length() - 1) {
                                end = Long.parseLong(spec.substring(dash + 1));
                            }
                        }
                    } catch (NumberFormatException ignored) {
                        start = 0;
                        end = total - 1;
                    }
                    if (start > end || start >= total) {
                        status(416);
                        header("Content-Range", "bytes */" + total);
                        writeHead(0);
                        out.flush();
                        return;
                    }
                    if (end >= total) end = total - 1;
                    partial = true;
                }
            }

            long len = end - start + 1;
            header("Content-Type", type);
            header("Accept-Ranges", "bytes");
            header("Cache-Control", cacheForever ? "public, max-age=2592000" : "no-cache");
            if (partial) {
                status(206);
                header("Content-Range", "bytes " + start + "-" + end + "/" + total);
            }
            writeHead(len);
            if (headOnly) {
                out.flush();
                return;
            }
            try (FileInputStream fis = new FileInputStream(f)) {
                long skipped = 0;
                while (skipped < start) {
                    long n = fis.skip(start - skipped);
                    if (n <= 0) break;
                    skipped += n;
                }
                byte[] buf = new byte[32 * 1024];
                long left = len;
                while (left > 0) {
                    int want = (int) Math.min(buf.length, left);
                    int n = fis.read(buf, 0, want);
                    if (n < 0) break;
                    out.write(buf, 0, n);
                    left -= n;
                }
            }
            out.flush();
        }

        void finish() throws IOException {
            if (!committed) {
                header("Content-Type", "text/plain; charset=utf-8");
                writeHead(0);
            }
            out.flush();
        }
    }
}
