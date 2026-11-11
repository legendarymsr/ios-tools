// SPDX-License-Identifier: GPL-3.0-or-later
package com.macoskvm.launcher;

import android.app.Activity;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;

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

        // Vertical split: the framebuffer is letterboxed in the area above
        // the key strip, so the strip never covers the guest menu bar or Dock.
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.BLACK);

        FrameLayout display = new FrameLayout(this);
        display.setBackgroundColor(Color.BLACK);
        view = new VncView(this);
        display.addView(view, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setBackgroundColor(0xC0000000);
        status.setPadding(24, 24, 24, 24);
        status.setText("Connecting to " + host + ":" + port + " …");
        display.addView(status, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER));

        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        root.addView(display, dlp);

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setBackgroundColor(0xFF1A1A1A);
        bar.setPadding(12, 8, 12, 8);
        bar.addView(barButton("Keyboard", v -> toggleKeyboard()));
        bar.addView(barButton("Esc", v -> view.tap(Keysyms.ESCAPE)));
        bar.addView(barButton("Ctrl+C", v -> combo(Keysyms.CONTROL, 'c')));
        bar.addView(barButton("\u2190", v -> view.tap(Keysyms.LEFT)));
        bar.addView(barButton("\u2192", v -> view.tap(Keysyms.RIGHT)));
        bar.addView(barButton("\u2191", v -> view.tap(Keysyms.UP)));
        bar.addView(barButton("\u2193", v -> view.tap(Keysyms.DOWN)));
        bar.addView(barButton("Enter", v -> view.tap(Keysyms.RETURN)));
        bar.addView(barButton("Space", v -> view.tap(' ')));
        bar.addView(barButton("Tab", v -> view.tap(Keysyms.TAB)));
        bar.addView(barButton("Fit", v -> view.resetZoom()));
        // The bar is wider than a phone screen: let it scroll sideways.
        HorizontalScrollView barScroll = new HorizontalScrollView(this);
        barScroll.setHorizontalScrollBarEnabled(false);
        barScroll.setBackgroundColor(0xFF1A1A1A);
        barScroll.setFillViewport(true);
        barScroll.addView(bar);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        root.addView(barScroll, blp);

        // Edge-to-edge: the key strip sits at the physical bottom when the
        // nav bar is hidden. When the IME is open, pad only by the IME inset
        // so the strip stays just above the keyboard.
        ViewCompat.setOnApplyWindowInsetsListener(root, (v, insets) -> {
            Insets ime = insets.getInsets(WindowInsetsCompat.Type.ime());
            v.setPadding(0, 0, 0, ime.bottom);
            return insets;
        });

        setContentView(root);
        setTitle(title != null ? title : "VNC " + host + ":" + port);
        hideSystemBars();
        connect();
    }

    /**
     * Immersive sticky full screen: hide the status and navigation bars,
     * draw into the display cutout, and let a swipe show the bars briefly.
     * Re-applied from onResume / onWindowFocusChanged because Android can
     * restore the bars after focus changes.
     */
    @SuppressWarnings("deprecation")
    private void hideSystemBars() {
        Window window = getWindow();
        if (window == null) return;
        // Make sure the decor view exists: Window.getInsetsController()
        // dereferences it and throws if called before setContentView().
        View decor = window.getDecorView();
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                WindowManager.LayoutParams lp = window.getAttributes();
                lp.layoutInDisplayCutoutMode =
                        WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
                window.setAttributes(lp);
            }
        } catch (RuntimeException ignored) { }
        try {
            WindowCompat.setDecorFitsSystemWindows(window, false);
            window.setStatusBarColor(Color.TRANSPARENT);
            window.setNavigationBarColor(Color.TRANSPARENT);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                window.setNavigationBarContrastEnforced(false);
            }
        } catch (RuntimeException ignored) { }
        boolean hidden = false;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                WindowInsetsController c = decor.getWindowInsetsController();
                if (c == null) c = window.getInsetsController();
                if (c != null) {
                    c.setSystemBarsBehavior(
                            WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
                    c.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
                    hidden = true;
                }
            } catch (RuntimeException ignored) { }
        }
        if (!hidden) {
            try {
                decor.setSystemUiVisibility(
                        View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                                | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                                | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                                | View.SYSTEM_UI_FLAG_FULLSCREEN);
            } catch (RuntimeException ignored) { }
        }
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    @Override protected void onResume() {
        super.onResume();
        hideSystemBars();
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
