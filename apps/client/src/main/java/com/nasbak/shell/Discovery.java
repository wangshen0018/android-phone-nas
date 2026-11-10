package com.nasbak.shell;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.InterfaceAddress;
import java.net.NetworkInterface;
import java.net.Socket;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 局域网自动发现。
 *
 * 做法：取本机所有物理网卡的 /24 段，并发探测每台主机的 8083 端口，
 * 再请求 /cgi/ping.cgi 看响应里有没有 "nasbak" 标记。
 *
 * 为什么不用 UDP 广播或 mDNS：
 * - busybox httpd 不监听 UDP，加广播意味着设备上多一个常驻进程，旧手机不稳；
 * - mDNS 要 avahi，busybox 环境根本没有。
 * 纯 TCP 扫描不需要任何权限，也不用改设备侧任何东西，是这里最省事的路径。
 *
 * 254 个地址、48 线程、320ms 超时：局域网内正常整段扫完在 1 秒上下，
 * 全段都不通的最坏情况约 2 秒。
 */
final class Discovery {

    static final int PORT = 8083;

    /** 连接超时。同网段正常 RTT < 20ms，320ms 足够，再大会白等。 */
    private static final int CONNECT_TIMEOUT_MS = 320;
    /** 读响应超时。本地服务器几乎是立即返回。 */
    private static final int READ_TIMEOUT_MS = 1200;
    private static final int THREADS = 48;
    private static final String PATH = "/cgi/ping.cgi";

    interface Cb {
        void onProgress(int done, int total);

        void onDone(List<Host> found);
    }

    /** 发现结果 */
    static final class Host {
        final String ip;
        final String name;

        Host(String ip, String name) {
            this.ip = ip;
            this.name = name;
        }

        String url() {
            return "http://" + ip + ":" + PORT + "/index.html";
        }
    }

    private Discovery() {
    }

    static void scan(final Cb cb) {
        final Set<String> targets = buildTargets();
        final int total = targets.size();
        if (total == 0) {
            cb.onDone(new ArrayList<Host>());
            return;
        }

        final List<Host> found = Collections.synchronizedList(new ArrayList<Host>());
        final AtomicInteger done = new AtomicInteger(0);
        final ExecutorService pool = Executors.newFixedThreadPool(THREADS);

        for (final String ip : targets) {
            pool.execute(new Runnable() {
                @Override
                public void run() {
                    Host h = probe(ip);
                    if (h != null) {
                        found.add(h);
                    }
                    int d = done.incrementAndGet();
                    // 每 16 个报一次，避免把 UI 线程刷爆
                    if (d % 16 == 0 || d == total) {
                        cb.onProgress(d, total);
                    }
                }
            });
        }

        pool.shutdown();
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    pool.awaitTermination(60, TimeUnit.SECONDS);
                } catch (InterruptedException ignored) {
                }
                // 按 IP 末段排序，结果稳定，不会每次顺序都变
                List<Host> out;
                synchronized (found) {
                    out = new ArrayList<Host>(found);
                }
                Collections.sort(out, new java.util.Comparator<Host>() {
                    @Override
                    public int compare(Host a, Host b) {
                        return lastOctet(a.ip) - lastOctet(b.ip);
                    }
                });
                cb.onDone(out);
            }
        }).start();
    }

    private static int lastOctet(String ip) {
        int i = ip.lastIndexOf('.');
        try {
            return Integer.parseInt(ip.substring(i + 1));
        } catch (Exception e) {
            return 0;
        }
    }

    /**
     * 收集要扫的地址：每个物理 IPv4 网卡取它的 /24 段。
     * 跳过回环、链路本地 169.254、以及 Tailscale 的 100.64/10
     * （安卓的 VPN 网卡在独立网络命名空间里，扫这一段只会白等）。
     */
    private static Set<String> buildTargets() {
        Set<String> out = new LinkedHashSet<String>();
        Set<String> prefixes = new LinkedHashSet<String>();

        try {
            Enumeration<NetworkInterface> nis = NetworkInterface.getNetworkInterfaces();
            while (nis.hasMoreElements()) {
                NetworkInterface ni = nis.nextElement();
                if (ni == null || !ni.isUp() || ni.isLoopback()) continue;
                String n = ni.getName() == null ? "" : ni.getName();
                // 只认真实网卡：wlan / eth / ap，其余（tun、rmnet 蜂窝）不扫
                if (!(n.startsWith("wlan") || n.startsWith("eth") || n.startsWith("ap")
                        || n.startsWith("swlan") || n.startsWith("p2p"))) {
                    continue;
                }
                for (InterfaceAddress ia : ni.getInterfaceAddresses()) {
                    InetAddress a = ia.getAddress();
                    if (a == null || !(a instanceof Inet4Address)) continue;
                    String ip = a.getHostAddress();
                    if (ip == null) continue;
                    if (ip.startsWith("127.") || ip.startsWith("169.254.")) continue;
                    if (isTailscale(ip)) continue;
                    int dot = ip.lastIndexOf('.');
                    if (dot <= 0) continue;
                    prefixes.add(ip.substring(0, dot));
                }
            }
        } catch (Exception ignored) {
        }

        for (String p : prefixes) {
            for (int i = 1; i <= 254; i++) {
                out.add(p + "." + i);
            }
        }
        return out;
    }

    /** 有没有可扫的网段。没有多半是没连 WiFi，提示文案要区分开。 */
    static boolean hasLocalNet() {
        return !buildTargets().isEmpty();
    }

    private static boolean isTailscale(String ip) {
        if (!ip.startsWith("100.")) return false;
        try {
            int b = Integer.parseInt(ip.substring(4, ip.indexOf('.', 4)));
            return b >= 64 && b <= 127;
        } catch (Exception e) {
            return false;
        }
    }

    /** 探测单台主机；不是本系统的服务就返回 null */
    private static Host probe(String ip) {
        Socket s = new Socket();
        try {
            s.connect(new InetSocketAddress(ip, PORT), CONNECT_TIMEOUT_MS);
            s.setSoTimeout(READ_TIMEOUT_MS);
            OutputStream o = s.getOutputStream();
            o.write(("GET " + PATH + " HTTP/1.0\r\nHost: " + ip + ":" + PORT
                    + "\r\nUser-Agent: nasbak-shell\r\nConnection: close\r\n\r\n").getBytes("UTF-8"));
            o.flush();

            InputStream in = s.getInputStream();
            byte[] buf = new byte[2048];
            StringBuilder sb = new StringBuilder();
            int n;
            // 响应头和 body 会分包。不能拿 "nasbak" 当结束标志——
            // 它的位置在 JSON 开头，分包边界常常正好切在 name 之前，
            // 会导致名字读不全。认 JSON 的结束花括号才可靠。
            while (sb.length() < 2048 && (n = in.read(buf)) > 0) {
                sb.append(new String(buf, 0, n, "UTF-8"));
                if (sb.indexOf("}") >= 0) break;
            }
            String r = sb.toString();
            if (!r.contains("nasbak")) return null;
            return new Host(ip, field(r, "name"));
        } catch (Exception e) {
            return null;
        } finally {
            try {
                s.close();
            } catch (Exception ignored) {
            }
        }
    }

    /** 从 JSON 文本里抠出字符串字段，抠不到给默认值 */
    private static String field(String json, String key) {
        String k = "\"" + key + "\":\"";
        int i = json.indexOf(k);
        if (i < 0) return "Pantry";
        int b = i + k.length();
        int e = json.indexOf('"', b);
        if (e <= b) return "Pantry";
        String v = json.substring(b, e).trim();
        return v.isEmpty() ? "Pantry" : v;
    }
}
