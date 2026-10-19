package com.qemukvm.launcher;

import android.content.Intent;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.content.ContextCompat;

import com.google.android.material.button.MaterialButton;
import com.topjohnwu.superuser.Shell;

import java.io.File;

public class MainActivity extends AppCompatActivity {
    static {
        Shell.enableVerboseLogging = BuildConfig.DEBUG;
        Shell.setDefaultBuilder(Shell.Builder.create()
                .setFlags(Shell.FLAG_MOUNT_MASTER)
                .setTimeout(3600));
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private TextView rootText;
    private TextView logText;
    private ScrollView logScroll;
    private LinearLayout buttons;
    private File payload;
    private boolean busy = false;
    private MaterialButton vncButton;
    private volatile boolean vncWatch = false;
    private volatile boolean resumed = false;
    static final String VNC_HOST = "127.0.0.1";
    static final int VNC_PORT = 5900;

    @Override
    protected void onCreate(@Nullable Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.activity_main);
        rootText = findViewById(R.id.rootText);
        logText = findViewById(R.id.logText);
        logScroll = findViewById(R.id.logScroll);
        buttons = findViewById(R.id.buttons);

        vncButton = new MaterialButton(this);
        vncButton.setText("Open VNC viewer (" + VNC_HOST + ":" + VNC_PORT + ")");
        LinearLayout.LayoutParams vlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        vlp.topMargin = 8;
        vncButton.setLayoutParams(vlp);
        vncButton.setOnClickListener(v -> openViewer());
        buttons.addView(vncButton);

        for (final Steps.Step s : Steps.STEPS) {
            MaterialButton btn = new MaterialButton(this);
            btn.setText(s.label);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.topMargin = 8;
            btn.setLayoutParams(lp);
            btn.setOnClickListener(v -> runStep(s));
            buttons.addView(btn);
        }

        appendLog(Steps.BANNER);
        checkRoot();
    }

    private void checkRoot() {
        rootText.setText("Root: checking…");
        Shell.getShell(shell -> main.post(() -> {
            boolean ok = shell.isRoot();
            rootText.setText(ok ? "Root: granted (KernelSU/Magisk)"
                                : "Root: NOT available — grant su to this app");
            rootText.setTextColor(ContextCompat.getColor(this, ok ? R.color.ok : R.color.err));
            if (ok) {
                try {
                    payload = ScriptRunner.extractPayload(this);
                    appendLog("Payload ready at " + payload.getAbsolutePath());
                    for (File f : payload.listFiles() != null ? payload.listFiles() : new File[0]) {
                        appendLog("  " + f.getName() + " (" + f.length() + " bytes)");
                    }
                } catch (Exception e) {
                    appendLog("Failed to extract payload: " + e.getMessage());
                }
            } else {
                appendLog("No root shell. Install KernelSU or Magisk and grant this app root.");
            }
        }));
    }

    private void runStep(Steps.Step s) {
        if (busy) { appendLog("Busy — wait for the current step to finish."); return; }
        if (payload == null) { appendLog("No root/payload yet."); return; }
        busy = true;
        setButtonsEnabled(false);
        String cmd = s.command.replace("{P}", payload.getAbsolutePath());
        appendLog("\n$ " + cmd);
        final boolean isBoot = s.label.contains("Boot");
        if (isBoot) watchVncAndOpen();
        ScriptRunner.run(cmd, new ScriptRunner.Listener() {
            @Override public void onLine(String line) { main.post(() -> appendLog(line)); }
            @Override public void onFinished(int code) {
                main.post(() -> {
                    appendLog("[exit " + code + "]");
                    if (isBoot) vncWatch = false;
                    busy = false;
                    setButtonsEnabled(true);
                });
            }
        });
    }

    private void setButtonsEnabled(boolean en) {
        for (int i = 0; i < buttons.getChildCount(); i++) {
            View b = buttons.getChildAt(i);
            if (b != vncButton) b.setEnabled(en);   // viewer stays usable while a VM runs
        }
    }

    private void openViewer() {
        Intent i = new Intent(this, VncActivity.class);
        i.putExtra(VncActivity.EXTRA_HOST, VNC_HOST);
        i.putExtra(VncActivity.EXTRA_PORT, VNC_PORT);
        startActivity(i);
    }

    /** After Boot starts: poll the VNC port for ~60 s and open the viewer once it accepts. */
    private void watchVncAndOpen() {
        if (vncWatch) return;
        vncWatch = true;
        appendLog("[vnc] waiting for " + VNC_HOST + ":" + VNC_PORT + " (up to 60 s)…");
        new Thread(() -> {
            long deadline = System.currentTimeMillis() + 60_000;
            boolean up = false;
            while (vncWatch && !up && System.currentTimeMillis() < deadline) {
                up = VncActivity.waitForPort(VNC_HOST, VNC_PORT, 2000);
            }
            final boolean ok = up, stillBooting = vncWatch;
            vncWatch = false;
            main.post(() -> {
                if (ok) {
                    appendLog("[vnc] port is up, opening viewer");
                    if (resumed) openViewer();
                    else appendLog("[vnc] app in background; tap 'Open VNC viewer'");
                } else if (stillBooting) {
                    appendLog("[vnc] no VNC after 60 s; tap 'Open VNC viewer' when the VM is up");
                } else {
                    appendLog("[vnc] boot step ended before VNC came up");
                }
            });
        }, "vnc-watch").start();
    }

    @Override protected void onResume() { super.onResume(); resumed = true; }

    @Override protected void onPause() { resumed = false; super.onPause(); }

    private void appendLog(String line) {
        if (logText.getText().length() > 0) logText.append("\n");
        logText.append(line);
        logScroll.post(() -> logScroll.fullScroll(ScrollView.FOCUS_DOWN));
    }
}
