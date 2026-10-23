package com.qemut8030.launcher;

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
    private boolean ensuringPayload = false;
    private Steps.Step pendingStep = null;
    private long waitStartedMs = 0;
    private int waitLogIndex = -1;  // start offset of the single waiting line in logText
    private MaterialButton vncButton;
    private MaterialButton powerButton;
    private volatile boolean poweringOff = false;
    private MaterialButton saveButton;
    private volatile boolean saving = false;
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
        LogStore.init(this);
        LogStore.append("\n=== launcher started " + new java.util.Date() + " (v" + BuildConfig.VERSION_NAME + ") ===");

        vncButton = new MaterialButton(this);
        vncButton.setText("Open VNC viewer (" + VNC_HOST + ":" + VNC_PORT + ")");
        LinearLayout.LayoutParams vlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        vlp.topMargin = 8;
        vncButton.setLayoutParams(vlp);
        vncButton.setOnClickListener(v -> openViewer());
        buttons.addView(vncButton);

        powerButton = new MaterialButton(this);
        powerButton.setText("Power off VM");
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        plp.topMargin = 8;
        powerButton.setLayoutParams(plp);
        powerButton.setOnClickListener(v -> powerOff());
        buttons.addView(powerButton);

        saveButton = new MaterialButton(this);
        saveButton.setText("Save iOS snapshot (next boot in seconds)");
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.topMargin = 8;
        saveButton.setLayoutParams(slp);
        saveButton.setOnClickListener(v -> saveSnapshot());
        buttons.addView(saveButton);

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
        ensurePayloadThen(null);
    }

    /**
     * Obtain root + extract assets/payload (including nested dirs like vhci-bridge/).
     * If {@code after} is non-null, run that step once ready. While waiting, keep a
     * single updating log line (no flood).
     */
    private void ensurePayloadThen(@Nullable Steps.Step after) {
        if (payload != null) {
            if (after != null) startStep(after);
            return;
        }
        if (after != null) pendingStep = after;
        if (ensuringPayload) return;
        ensuringPayload = true;
        if (waitStartedMs == 0) waitStartedMs = System.currentTimeMillis();
        setWaitLog("Waiting for root and app payload… grant su to this app in KernelSU if asked.");

        Shell.getShell(shell -> main.post(() -> {
            boolean ok = shell.isRoot();
            rootText.setText(ok ? "Root: granted (KernelSU/Magisk)"
                                : "Root: NOT available — grant su to this app");
            rootText.setTextColor(ContextCompat.getColor(this, ok ? R.color.ok : R.color.err));
            if (!ok) {
                ensuringPayload = false;
                long sec = (System.currentTimeMillis() - waitStartedMs) / 1000;
                setWaitLog("No root after " + sec + "s. Open KernelSU → Superuser, allow "
                        + "iOS VM (HackiOS), then tap the step again.");
                pendingStep = null;
                waitStartedMs = 0;
                return;
            }
            try {
                payload = ScriptRunner.extractPayload(this);
                clearWaitLog();
                appendLog("Payload ready at " + payload.getAbsolutePath());
                File[] files = payload.listFiles();
                if (files != null) {
                    for (File f : files) {
                        appendLog("  " + f.getName() + (f.isDirectory() ? "/" : " (" + f.length() + " bytes)"));
                    }
                }
                ensuringPayload = false;
                waitStartedMs = 0;
                Steps.Step next = pendingStep;
                pendingStep = null;
                if (next != null) startStep(next);
            } catch (Exception e) {
                ensuringPayload = false;
                long sec = (System.currentTimeMillis() - waitStartedMs) / 1000;
                setWaitLog("Payload extract failed after " + sec + "s: " + e.getMessage()
                        + " — reinstall the launcher module zip, then tap the step again.");
                pendingStep = null;
                waitStartedMs = 0;
                payload = null;
            }
        }));
    }

    private void runStep(Steps.Step s) {
        if (busy) { appendLog("Busy — wait for the current step to finish."); return; }
        if (payload == null) {
            // One line, then ensure; do not spam on every tap.
            if (waitStartedMs == 0) waitStartedMs = System.currentTimeMillis();
            long sec = (System.currentTimeMillis() - waitStartedMs) / 1000;
            setWaitLog("Waiting for root/payload (" + sec + "s)… grant su in KernelSU if asked, "
                    + "or wait for extract. Step \"" + s.label + "\" will start when ready.");
            ensurePayloadThen(s);
            return;
        }
        startStep(s);
    }

    private void startStep(Steps.Step s) {
        if (busy) { appendLog("Busy — wait for the current step to finish."); return; }
        if (payload == null) {
            ensurePayloadThen(s);
            return;
        }
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

    /** Replace or create a single waiting status line at the end of the log. */
    private void setWaitLog(String msg) {
        CharSequence cur = logText.getText();
        if (waitLogIndex >= 0 && waitLogIndex <= cur.length()) {
            logText.setText(cur.subSequence(0, waitLogIndex));
            if (logText.getText().length() > 0) logText.append("\n");
        } else if (logText.getText().length() > 0) {
            logText.append("\n");
        }
        waitLogIndex = logText.getText().length();
        logText.append(msg);
        LogStore.append(msg);
        logScroll.post(() -> logScroll.fullScroll(ScrollView.FOCUS_DOWN));
    }

    private void clearWaitLog() {
        if (waitLogIndex < 0) return;
        CharSequence cur = logText.getText();
        if (waitLogIndex <= cur.length()) {
            // drop the waiting line (and a preceding newline if we introduced one)
            int start = waitLogIndex;
            if (start > 0 && cur.charAt(start - 1) == '\n') start--;
            logText.setText(cur.subSequence(0, start));
        }
        waitLogIndex = -1;
    }

    private void setButtonsEnabled(boolean en) {
        for (int i = 0; i < buttons.getChildCount(); i++) {
            View b = buttons.getChildAt(i);
            if (b != vncButton && b != powerButton && b != saveButton) b.setEnabled(en);   // viewer stays usable while a VM runs
        }
    }

    /** Runs alongside a busy step (the Boot step stays busy while the VM runs). */
    private void powerOff() {
        if (payload == null) { appendLog("Power off: waiting for root/payload - tap again in a moment."); ensurePayloadThen(null); return; }
        if (poweringOff) { appendLog("Power off already in progress…"); return; }
        poweringOff = true;
        powerButton.setEnabled(false);
        String cmd = Steps.POWER_OFF.replace("{P}", payload.getAbsolutePath());
        appendLog("\n$ " + cmd);
        ScriptRunner.run(cmd, new ScriptRunner.Listener() {
            @Override public void onLine(String line) { main.post(() -> appendLog(line)); }
            @Override public void onFinished(int code) {
                main.post(() -> {
                    appendLog("[power off exit " + code + "]");
                    poweringOff = false;
                    powerButton.setEnabled(true);
                });
            }
        });
    }

    /** Also alongside the busy Boot step: saves the running iOS so the next boot resumes it. */
    private void saveSnapshot() {
        if (payload == null) { appendLog("Save: waiting for root/payload - tap again in a moment."); ensurePayloadThen(null); return; }
        if (saving) { appendLog("Saving already in progress…"); return; }
        saving = true;
        saveButton.setEnabled(false);
        String cmd = Steps.SAVE.replace("{P}", payload.getAbsolutePath());
        appendLog("\n$ " + cmd);
        ScriptRunner.run(cmd, new ScriptRunner.Listener() {
            @Override public void onLine(String line) { main.post(() -> appendLog(line)); }
            @Override public void onFinished(int code) {
                main.post(() -> {
                    appendLog("[save exit " + code + "]");
                    saving = false;
                    saveButton.setEnabled(true);
                });
            }
        });
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
        LogStore.append(line);
        logScroll.post(() -> logScroll.fullScroll(ScrollView.FOCUS_DOWN));
    }
}
