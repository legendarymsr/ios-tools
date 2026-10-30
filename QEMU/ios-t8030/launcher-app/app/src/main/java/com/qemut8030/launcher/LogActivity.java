// SPDX-License-Identifier: GPL-3.0-or-later
package com.qemut8030.launcher;

import android.content.ClipData;
import android.content.ClipboardManager;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.TextUtils;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.google.android.material.button.MaterialButton;

/**
 * "iOS Emu Logs": its own launcher icon and task, showing only the log
 * (LogStore) full screen, live while steps run, plus earlier runs from the file.
 */
public class LogActivity extends AppCompatActivity {
    private static final int SHOW_CHARS = 300_000;   // keep the TextView responsive

    private final Handler main = new Handler(Looper.getMainLooper());
    private TextView logText;
    private ScrollView logScroll;
    private boolean follow = true;

    private final LogStore.Listener onTail = tail -> main.post(() -> {
        logText.setText(tail, TextView.BufferType.EDITABLE);
        scrollToEnd();
    });

    private final LogStore.Listener onLine = line -> main.post(() -> {
        Editable e = logText.getEditableText();
        if (e == null) return;
        e.append(line).append('\n');
        if (e.length() > SHOW_CHARS) {
            int cut = e.length() - SHOW_CHARS;
            int nl = TextUtils.indexOf(e, '\n', cut);
            e.delete(0, nl >= 0 ? nl + 1 : cut);
        }
        if (follow) scrollToEnd();
    });

    @Override
    protected void onCreate(@Nullable Bundle b) {
        super.onCreate(b);
        setContentView(R.layout.activity_log);
        LogStore.init(this);
        logText = findViewById(R.id.logText);
        logScroll = findViewById(R.id.logScroll);
        logText.setText("", TextView.BufferType.EDITABLE);

        // Follow new lines only while the view is at the bottom.
        logScroll.getViewTreeObserver().addOnScrollChangedListener(() -> {
            int bottom = logText.getHeight() - logScroll.getHeight() - logScroll.getScrollY();
            follow = bottom < 200;
        });

        MaterialButton copy = findViewById(R.id.copyButton);
        copy.setOnClickListener(v -> {
            ClipboardManager cm = getSystemService(ClipboardManager.class);
            cm.setPrimaryClip(ClipData.newPlainText("iOS Emu log", logText.getText()));
            Toast.makeText(this, "Log copied", Toast.LENGTH_SHORT).show();
        });
        MaterialButton clear = findViewById(R.id.clearButton);
        clear.setOnClickListener(v -> {
            LogStore.clear();
            logText.setText("", TextView.BufferType.EDITABLE);
        });

        LogStore.subscribe(SHOW_CHARS, onTail, onLine);
    }

    @Override
    protected void onDestroy() {
        LogStore.unsubscribe(onLine);
        super.onDestroy();
    }

    private void scrollToEnd() {
        logScroll.post(() -> logScroll.fullScroll(ScrollView.FOCUS_DOWN));
    }
}
