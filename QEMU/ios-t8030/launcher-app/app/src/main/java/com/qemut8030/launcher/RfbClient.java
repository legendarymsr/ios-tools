package com.qemut8030.launcher;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

/**
 * Small RFB (VNC) client. Speaks protocol 3.8 (also accepts 3.3/3.7 servers),
 * security type "None", Raw + CopyRect encodings and the DesktopSize
 * pseudo-encoding. No Android APIs, so it can be exercised on a desktop JVM.
 *
 * The framebuffer is kept as 0xFFRRGGBB ints in {@link #fb}; readers must
 * synchronize on {@link #lock} while touching it.
 */
public final class RfbClient {

    public interface Listener {
        /** Framebuffer (re)allocated at a new size. Called on the reader thread. */
        void onResize(int width, int height);
        /** End of one FramebufferUpdate; (x,y,w,h) is the union of changed rects. */
        void onUpdate(int x, int y, int w, int h);
        void onDisconnected(String reason);
    }

    public static final int ENC_RAW = 0;
    public static final int ENC_COPYRECT = 1;
    public static final int ENC_DESKTOPSIZE = -223;

    public final Object lock = new Object();
    public volatile int[] fb = new int[0];
    public volatile int width, height;
    public volatile String desktopName = "";
    public volatile String serverVersion = "";

    private final Listener listener;
    private Socket sock;
    private DataInputStream in;
    private DataOutputStream out;
    private volatile boolean running;
    private byte[] rowBuf = new byte[0];
    /** Input events are written from here: Android forbids socket I/O on the UI thread. */
    private final ExecutorService writer = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "rfb-writer"); t.setDaemon(true); return t; });

    public RfbClient(Listener l) { this.listener = l; }

    /** Connects and performs the full handshake (blocking). */
    public void connect(String host, int port, int timeoutMs) throws IOException {
        sock = new Socket();
        sock.setTcpNoDelay(true);
        sock.connect(new InetSocketAddress(host, port), timeoutMs);
        sock.setSoTimeout(timeoutMs);
        in = new DataInputStream(new BufferedInputStream(sock.getInputStream(), 1 << 16));
        out = new DataOutputStream(new BufferedOutputStream(sock.getOutputStream(), 8192));

        byte[] ver = new byte[12];
        in.readFully(ver);
        serverVersion = new String(ver, StandardCharsets.US_ASCII).trim();
        if (!serverVersion.startsWith("RFB ")) throw new IOException("not an RFB server: " + serverVersion);
        int major = Integer.parseInt(serverVersion.substring(4, 7));
        int minor = Integer.parseInt(serverVersion.substring(8, 11));
        int useMinor = (major > 3 || minor >= 8) ? 8 : (minor >= 7 ? 7 : 3);
        out.write(("RFB 003.00" + useMinor + "\n").getBytes(StandardCharsets.US_ASCII));
        out.flush();

        if (useMinor == 3) {
            int type = in.readInt();
            if (type == 0) throw new IOException("server refused: " + readReason());
            if (type != 1) throw new IOException("server requires security type " + type + " (only None is supported)");
        } else {
            int n = in.readUnsignedByte();
            if (n == 0) throw new IOException("server refused: " + readReason());
            boolean hasNone = false;
            StringBuilder offered = new StringBuilder();
            for (int i = 0; i < n; i++) {
                int t = in.readUnsignedByte();
                offered.append(i == 0 ? "" : ",").append(t);
                if (t == 1) hasNone = true;
            }
            if (!hasNone) throw new IOException("server offers security types [" + offered
                    + "], no 'None' (1); run QEMU VNC without a password");
            out.writeByte(1);
            out.flush();
            if (useMinor == 8) {
                int res = in.readInt();
                if (res != 0) throw new IOException("security handshake failed: " + readReason());
            }
        }

        out.writeByte(1); // ClientInit: shared
        out.flush();
        int w = in.readUnsignedShort();
        int h = in.readUnsignedShort();
        byte[] pf = new byte[16];
        in.readFully(pf); // server pixel format, ignored: we set our own
        int nameLen = in.readInt();
        byte[] name = new byte[Math.max(0, Math.min(nameLen, 4096))];
        in.readFully(name);
        if (nameLen > name.length) in.skipBytes(nameLen - name.length);
        desktopName = new String(name, StandardCharsets.UTF_8);
        resize(w, h);

        // SetPixelFormat: 32bpp, depth 24, little-endian, true colour, RGB888 at 16/8/0.
        out.writeByte(0); out.write(new byte[3]);
        out.writeByte(32); out.writeByte(24); out.writeByte(0); out.writeByte(1);
        out.writeShort(255); out.writeShort(255); out.writeShort(255);
        out.writeByte(16); out.writeByte(8); out.writeByte(0);
        out.write(new byte[3]);
        // SetEncodings
        int[] enc = { ENC_COPYRECT, ENC_RAW, ENC_DESKTOPSIZE };
        out.writeByte(2); out.writeByte(0); out.writeShort(enc.length);
        for (int e : enc) out.writeInt(e);
        out.flush();
        sock.setSoTimeout(0);
        running = true;
    }

    private String readReason() throws IOException {
        int len = in.readInt();
        byte[] b = new byte[Math.max(0, Math.min(len, 4096))];
        in.readFully(b);
        return new String(b, StandardCharsets.UTF_8);
    }

    private void resize(int w, int h) {
        synchronized (lock) {
            width = w; height = h;
            fb = new int[Math.max(1, w * h)];
        }
        listener.onResize(w, h);
    }

    public synchronized void requestUpdate(boolean incremental) throws IOException {
        out.writeByte(3);
        out.writeByte(incremental ? 1 : 0);
        out.writeShort(0); out.writeShort(0);
        out.writeShort(width); out.writeShort(height);
        out.flush();
    }

    /** buttons: bit0 = left, bit1 = middle, bit2 = right, bit3/4 = wheel up/down. Non-blocking. */
    public void sendPointer(final int x, final int y, final int buttons) {
        if (!running) return;
        post(() -> writePointer(x, y, buttons));
    }

    /** Non-blocking; safe to call from the UI thread. */
    public void sendKey(final int keysym, final boolean down) {
        if (!running) return;
        post(() -> writeKey(keysym, down));
    }

    private boolean post(Runnable r) {
        try { writer.execute(r); return true; }
        catch (RejectedExecutionException e) { return false; }
    }

    private synchronized void writePointer(int x, int y, int buttons) {
        try {
            out.writeByte(5); out.writeByte(buttons);
            out.writeShort(clamp(x, width)); out.writeShort(clamp(y, height));
            out.flush();
        } catch (IOException ignored) { }
    }

    private synchronized void writeKey(int keysym, boolean down) {
        try {
            out.writeByte(4); out.writeByte(down ? 1 : 0); out.writeShort(0);
            out.writeInt(keysym);
            out.flush();
        } catch (IOException ignored) { }
    }

    public void tapKey(int keysym) { sendKey(keysym, true); sendKey(keysym, false); }

    private static int clamp(int v, int max) { return Math.max(0, Math.min(v, Math.max(0, max - 1))); }

    /**
     * Reads server messages until disconnect. Requests one full update first,
     * then an incremental update after each FramebufferUpdate. maxUpdates &gt; 0
     * stops after that many updates (used by the desktop test).
     */
    public void runLoop(int maxUpdates) {
        String reason = "closed";
        int updates = 0;
        try {
            requestUpdate(false);
            while (running) {
                int type = in.readUnsignedByte();
                switch (type) {
                    case 0: {
                        readFramebufferUpdate();
                        updates++;
                        if (maxUpdates > 0 && updates >= maxUpdates) { running = false; break; }
                        requestUpdate(true);
                        break;
                    }
                    case 1: { // SetColourMapEntries (unused with true colour)
                        in.readUnsignedByte();
                        in.readUnsignedShort();
                        int n = in.readUnsignedShort();
                        in.skipBytes(n * 6);
                        break;
                    }
                    case 2: break; // Bell
                    case 3: { // ServerCutText
                        in.skipBytes(3);
                        int len = in.readInt();
                        skipFully(len);
                        break;
                    }
                    default:
                        throw new IOException("unknown server message " + type);
                }
            }
        } catch (IOException e) {
            if (running) reason = e.getMessage() == null ? e.toString() : e.getMessage();
        } finally {
            running = false;
            closeQuietly();
            writer.shutdownNow();
            listener.onDisconnected(reason);
        }
    }

    private void skipFully(long n) throws IOException {
        while (n > 0) {
            int s = in.skipBytes((int) Math.min(n, Integer.MAX_VALUE));
            if (s <= 0) { in.readByte(); s = 1; }
            n -= s;
        }
    }

    private void readFramebufferUpdate() throws IOException {
        in.readUnsignedByte(); // padding
        int n = in.readUnsignedShort();
        int ux0 = Integer.MAX_VALUE, uy0 = Integer.MAX_VALUE, ux1 = 0, uy1 = 0;
        boolean resized = false;
        for (int i = 0; i < n; i++) {
            int x = in.readUnsignedShort(), y = in.readUnsignedShort();
            int w = in.readUnsignedShort(), h = in.readUnsignedShort();
            int enc = in.readInt();
            if (enc == ENC_RAW) {
                readRaw(x, y, w, h);
            } else if (enc == ENC_COPYRECT) {
                int sx = in.readUnsignedShort(), sy = in.readUnsignedShort();
                copyRect(sx, sy, x, y, w, h);
            } else if (enc == ENC_DESKTOPSIZE) {
                resize(w, h);
                resized = true;
                ux0 = 0; uy0 = 0; ux1 = w; uy1 = h;
                continue;
            } else {
                throw new IOException("unsupported encoding " + enc);
            }
            ux0 = Math.min(ux0, x); uy0 = Math.min(uy0, y);
            ux1 = Math.max(ux1, x + w); uy1 = Math.max(uy1, y + h);
        }
        if (resized) { ux0 = 0; uy0 = 0; ux1 = width; uy1 = height; }
        if (ux0 < ux1 && uy0 < uy1) {
            ux1 = Math.min(ux1, width); uy1 = Math.min(uy1, height);
            listener.onUpdate(ux0, uy0, ux1 - ux0, uy1 - uy0);
        }
    }

    private void readRaw(int x, int y, int w, int h) throws IOException {
        int rowBytes = w * 4;
        if (rowBuf.length < rowBytes) rowBuf = new byte[rowBytes];
        for (int row = 0; row < h; row++) {
            in.readFully(rowBuf, 0, rowBytes);
            int yy = y + row;
            synchronized (lock) {
                int W = width, H = height;
                if (yy >= H) continue;
                int[] f = fb;
                int base = yy * W;
                for (int col = 0, o = 0; col < w; col++, o += 4) {
                    int xx = x + col;
                    if (xx >= W) break;
                    // little-endian 32bpp: B, G, R, X
                    f[base + xx] = 0xFF000000
                            | ((rowBuf[o + 2] & 0xFF) << 16)
                            | ((rowBuf[o + 1] & 0xFF) << 8)
                            | (rowBuf[o] & 0xFF);
                }
            }
        }
    }

    private void copyRect(int sx, int sy, int dx, int dy, int w, int h) {
        synchronized (lock) {
            int W = width, H = height;
            w = Math.min(w, Math.min(W - sx, W - dx));
            h = Math.min(h, Math.min(H - sy, H - dy));
            if (w <= 0 || h <= 0) return;
            int[] f = fb;
            if (dy > sy) {
                for (int r = h - 1; r >= 0; r--)
                    System.arraycopy(f, (sy + r) * W + sx, f, (dy + r) * W + dx, w);
            } else {
                for (int r = 0; r < h; r++)
                    System.arraycopy(f, (sy + r) * W + sx, f, (dy + r) * W + dx, w);
            }
        }
    }

    public boolean isRunning() { return running; }

    /** Closes the socket off the calling thread (safe from the UI thread). */
    public void close() {
        running = false;
        if (!post(this::closeQuietly)) closeQuietly();
        writer.shutdown();
    }

    private void closeQuietly() {
        try { if (sock != null) sock.close(); } catch (IOException ignored) { }
    }
}
