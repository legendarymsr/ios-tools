package com.macoskvm.launcher;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
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

    @Override
    protected void onCreate(@Nullable Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.activity_main);
        rootText = findViewById(R.id.rootText);
        logText = findViewById(R.id.logText);
        logScroll = findViewById(R.id.logScroll);
        buttons = findViewById(R.id.buttons);

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
        ScriptRunner.run(cmd, new ScriptRunner.Listener() {
            @Override public void onLine(String line) { main.post(() -> appendLog(line)); }
            @Override public void onFinished(int code) {
                main.post(() -> {
                    appendLog("[exit " + code + "]");
                    busy = false;
                    setButtonsEnabled(true);
                });
            }
        });
    }

    private void setButtonsEnabled(boolean en) {
        for (int i = 0; i < buttons.getChildCount(); i++) buttons.getChildAt(i).setEnabled(en);
    }

    private void appendLog(String line) {
        if (logText.getText().length() > 0) logText.append("\n");
        logText.append(line);
        logScroll.post(() -> logScroll.fullScroll(ScrollView.FOCUS_DOWN));
    }
}
