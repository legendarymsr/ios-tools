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
import android.view.inputmethod.InputMethodManager;
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
    private boolean keyboardShown = false;
    private static final long RETRY_MS = 60_000;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        host = getIntent().getStringExtra(EXTRA_HOST);
        if (host == null) host = "127.0.0.1";
        port = getIntent().getIntExtra(EXTRA_PORT, 5900);
        String title = getIntent().getStringExtra(EXTRA_TITLE);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        view = new VncView(this);
        root.addView(view, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setBackgroundColor(0xB0000000);
        bar.setPadding(12, 8, 12, 8);
        bar.addView(barButton("Keyboard", v -> toggleKeyboard()));
        bar.addView(barButton("Esc", v -> view.tap(Keysyms.ESCAPE)));
        bar.addView(barButton("Ctrl+C", v -> combo(Keysyms.CONTROL, 'c')));
        bar.addView(barButton("Fit", v -> view.resetZoom()));
        // iPhone 11 has no home button: both are swipes from the bottom edge.
        bar.addView(barButton("Swipe up", v -> view.swipe(0.5f, 0.995f, 0.5f, 0.30f, 450)));
        bar.addView(barButton("Home", v -> view.swipe(0.5f, 0.995f, 0.5f, 0.50f, 400)));
        FrameLayout.LayoutParams blp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP);
        android.widget.HorizontalScrollView barScroll = new android.widget.HorizontalScrollView(this);
        barScroll.setHorizontalScrollBarEnabled(false);
        barScroll.addView(bar);
        root.addView(barScroll, blp);

        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setBackgroundColor(0xC0000000);
        status.setPadding(24, 24, 24, 24);
        status.setText("Connecting to " + host + ":" + port + " …");
        root.addView(status, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER));

        setContentView(root);
        setTitle(title != null ? title : "VNC " + host + ":" + port);
        connect();
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

    private void toggleKeyboard() {
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm == null) return;
        if (keyboardShown) {
            imm.hideSoftInputFromWindow(view.getWindowToken(), 0);
            keyboardShown = false;
        } else {
            view.requestFocus();
            imm.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT);
            keyboardShown = true;
        }
    }

    private void combo(int modifier, int ch) {
        if (client == null) return;
        client.sendKey(modifier, true);
        client.tapKey(Keysyms.forCodePoint(ch));
        client.sendKey(modifier, false);
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
