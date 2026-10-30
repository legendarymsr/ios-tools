// SPDX-License-Identifier: GPL-3.0-or-later
package com.qemut8030.launcher;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.IOException;
import java.net.Socket;

/**
 * Full-screen VNC viewer. Launch with EXTRA_HOST / EXTRA_PORT (defaults
 * 127.0.0.1:5900). Back closes the viewer only.
 */
public class VncActivity extends Activity implements RfbClient.Listener {
    public static final String EXTRA_HOST = "host";
    public static final String EXTRA_PORT = "port";
    public static final String EXTRA_TITLE = "title";

    private final Handler main = new Handler(Looper.getMainLooper());
    private VncView view;
    private TextView status;
    private volatile RfbClient client;
    private Thread netThread;
    private String host;
    private int port;
    private volatile boolean closing = false;
    private static final long RETRY_MS = 60_000;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        host = getIntent().getStringExtra(EXTRA_HOST);
        if (host == null) host = "127.0.0.1";
        port = getIntent().getIntExtra(EXTRA_PORT, 5900);
        String title = getIntent().getStringExtra(EXTRA_TITLE);

        // The buttons get a row of their own above the picture, so the whole remote screen fits
        // below them instead of being covered at the top (iOS's status bar was under them).
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.BLACK);

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setPadding(12, 4, 12, 4);
        // HackiOS's virtio keyboard is the phone's buttons, not a keyboard (redwood_virtio_input.c):
        // Home = KEY_HOME, l = lock, Up/Down = volume. Text is typed on iOS's own on-screen keyboard.
        bar.addView(barButton("Home", v -> view.tap(Keysyms.HOME)));
        bar.addView(barButton("Lock", v -> view.tap('l')));
        bar.addView(barButton("Swipe up", v -> view.swipe(0.5f, 0.995f, 0.5f, 0.30f, 450)));
        bar.addView(barButton("Vol +", v -> view.tap(Keysyms.UP)));
        bar.addView(barButton("Vol −", v -> view.tap(Keysyms.DOWN)));
        bar.addView(barButton("Fit", v -> {
            view.resetZoom();
            Toast.makeText(this, view.describeFit(), Toast.LENGTH_LONG).show();
        }));
        android.widget.HorizontalScrollView barScroll = new android.widget.HorizontalScrollView(this);
        barScroll.setHorizontalScrollBarEnabled(false);
        barScroll.addView(bar);
        root.addView(barScroll, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        FrameLayout screen = new FrameLayout(this);
        view = new VncView(this);
        screen.addView(view, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setBackgroundColor(0xC0000000);
        status.setPadding(24, 24, 24, 24);
        status.setText("Connecting to " + host + ":" + port + " …");
        screen.addView(status, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        root.addView(screen, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        setContentView(root);
        hideSystemBars();
        setTitle(title != null ? title : "VNC " + host + ":" + port);
        connect();
    }

    /** Android's status and navigation bars off (a swipe from the edge shows them for a moment). */
    @SuppressWarnings("deprecation")
    private void hideSystemBars() {
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            android.view.WindowInsetsController c = getWindow().getInsetsController();
            if (c != null) {
                c.hide(android.view.WindowInsets.Type.systemBars());
                c.setSystemBarsBehavior(android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN
                    | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY);
        }
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    private Button barButton(String label, View.OnClickListener l) {
        Button btn = new Button(this);
        btn.setText(label);
        btn.setAllCaps(false);
        btn.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.rightMargin = 8;
        btn.setLayoutParams(lp);
        return btn;
    }

    /** Connects, retrying for up to RETRY_MS so the viewer can be opened while QEMU starts. */
    private void connect() {
        if (netThread != null && netThread.isAlive()) return;
        status.setVisibility(View.VISIBLE);
        status.setOnClickListener(null);
        netThread = new Thread(() -> {
            long start = System.currentTimeMillis();
            String last = "";
            while (!closing && System.currentTimeMillis() - start < RETRY_MS) {
                RfbClient c = new RfbClient(this);
                try {
                    view.setClient(c);
                    client = c;
                    c.connect(host, port, 8000);
                    final String name = c.desktopName;
                    main.post(() -> {
                        status.setVisibility(View.GONE);
                        Toast.makeText(this, "Connected: " + name, Toast.LENGTH_SHORT).show();
                    });
                    c.runLoop(0);
                    return;
                } catch (IOException e) {
                    c.close();
                    last = e.getMessage() == null ? e.toString() : e.getMessage();
                    final long secs = (System.currentTimeMillis() - start) / 1000;
                    final String why = last;
                    main.post(() -> status.setText("Waiting for VNC on " + host + ":" + port
                            + " … " + secs + "s\n(" + why + ")"));
                    try { Thread.sleep(1000); } catch (InterruptedException ie) { return; }
                }
            }
            if (closing) return;
            final String why = last;
            main.post(() -> {
                status.setVisibility(View.VISIBLE);
                status.setText("Could not connect to " + host + ":" + port + "\n" + why
                        + "\n\nIs the VM running? Tap here to retry, Back to close.");
                status.setOnClickListener(v -> connect());
            });
        }, "rfb-net");
        netThread.start();
    }



    // Called on the reader thread before any pixels at the new size arrive.
    @Override public void onResize(int w, int h) { view.onRemoteResize(w, h); }

    @Override public void onUpdate(int x, int y, int w, int h) { view.onRemoteUpdate(x, y, w, h); }

    @Override public void onDisconnected(String reason) {
        if (closing) return;
        main.post(() -> {
            status.setVisibility(View.VISIBLE);
            status.setText("Disconnected: " + reason + "\n\nTap here to reconnect, Back to close.");
            status.setOnClickListener(v -> connect());
        });
    }

    @Override protected void onDestroy() {
        closing = true;
        if (netThread != null) netThread.interrupt();
        if (client != null) client.close();
        super.onDestroy();
    }

    /**
     * Blocks until a TCP connect to host:port succeeds or the deadline passes.
     * Used by the Boot step to open the viewer once QEMU's VNC port is up.
     */
    public static boolean waitForPort(String host, int port, int timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            try (Socket s = new Socket()) {
                s.connect(new java.net.InetSocketAddress(host, port), 1500);
                return true;
            } catch (IOException e) {
                try { Thread.sleep(1000); } catch (InterruptedException ie) { return false; }
            }
        }
        return false;
    }
}
