package com.checkm8otg;

import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.Button;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.content.ContextCompat;

import com.topjohnwu.superuser.Shell;

import java.util.HashMap;
import java.util.Locale;

public class MainActivity extends AppCompatActivity {
    static {
        Shell.enableVerboseLogging = BuildConfig.DEBUG;
        // palera1n can take many minutes (checkm8 retries + Pongo + boot)
        Shell.setDefaultBuilder(Shell.Builder.create()
                .setFlags(Shell.FLAG_MOUNT_MASTER)
                .setTimeout(900));
    }

    private static final String ACTION_USB_PERMISSION = "com.checkm8otg.USB_PERMISSION";
    private static final int APPLE_VID = 0x05AC;
    private static final int DFU_PID = 0x1227;
    private static final int RECOVERY_PID = 0x1281;

    private TextView statusText;
    private TextView usbText;
    private TextView rootText;
    private TextView logText;
    private ScrollView logScroll;
    private Button btnExploit;
    private Button btnReset;
    private Button btnJailbreak;
    private Button btnCancel;
    private RadioGroup modeGroup;
    private RadioButton modeRootless;
    private RadioButton modeRootful;

    private UsbManager usbManager;
    private final Handler main = new Handler(Looper.getMainLooper());
    private boolean busy = false;
    private NativeRunner.Handle currentJob = null;

    private final BroadcastReceiver usbReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String action = intent.getAction();
            if (ACTION_USB_PERMISSION.equals(action)) {
                UsbDevice device = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
                boolean granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false);
                appendLog("USB permission " + (granted ? "granted" : "denied")
                        + (device != null ? " for " + describe(device) : ""));
                refreshUsb();
            } else if (UsbManager.ACTION_USB_DEVICE_ATTACHED.equals(action)) {
                UsbDevice device = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
                appendLog("Attached: " + (device != null ? describe(device) : "?"));
                if (device != null) requestUsbPermission(device);
                refreshUsb();
            } else if (UsbManager.ACTION_USB_DEVICE_DETACHED.equals(action)) {
                UsbDevice device = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE);
                appendLog("Detached: " + (device != null ? describe(device) : "?"));
                refreshUsb();
            }
        }
    };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        statusText = findViewById(R.id.statusText);
        usbText = findViewById(R.id.usbText);
        rootText = findViewById(R.id.rootText);
        logText = findViewById(R.id.logText);
        logScroll = findViewById(R.id.logScroll);
        btnExploit = findViewById(R.id.btnExploit);
        btnReset = findViewById(R.id.btnReset);
        btnJailbreak = findViewById(R.id.btnJailbreak);
        btnCancel = findViewById(R.id.btnCancel);
        modeGroup = findViewById(R.id.modeGroup);
        modeRootless = findViewById(R.id.modeRootless);
        modeRootful = findViewById(R.id.modeRootful);

        usbManager = (UsbManager) getSystemService(USB_SERVICE);

        btnExploit.setOnClickListener(v -> runGaster(new String[]{"pwn"}, "Exploit (gaster pwn)"));
        btnReset.setOnClickListener(v -> runGaster(new String[]{"reset"}, "Reset (gaster reset)"));
        btnJailbreak.setOnClickListener(v -> runPalera1n());
        btnCancel.setOnClickListener(v -> cancelCurrent());
        btnCancel.setEnabled(false);

        IntentFilter filter = new IntentFilter();
        filter.addAction(ACTION_USB_PERMISSION);
        filter.addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED);
        filter.addAction(UsbManager.ACTION_USB_DEVICE_DETACHED);
        ContextCompat.registerReceiver(this, usbReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED);

        appendLog("Checkm8 OTG — gaster + palera1n v2.2 bundled.");
        appendLog("gaster: A5–A11 / T2 → pwned DFU.");
        appendLog("palera1n: A8–A11 / T2, iOS 15–26 (rootless or rootful/fakefs).");
        appendLog("A12+ is not vulnerable. Live USB path not tested on this build host.");
        appendLog("Tip: every button streams its command + output below; use Cancel to stop a stuck run.");
        checkRoot();
        refreshUsb();

        UsbDevice launched = getIntent() != null
                ? getIntent().getParcelableExtra(UsbManager.EXTRA_DEVICE) : null;
        if (launched != null) {
            requestUsbPermission(launched);
        }
    }

    @Override
    protected void onDestroy() {
        try { unregisterReceiver(usbReceiver); } catch (Exception ignored) {}
        super.onDestroy();
    }

    private void checkRoot() {
        rootText.setText("Root: checking…");
        Shell.getShell(shell -> main.post(() -> {
            boolean ok = shell.isRoot();
            rootText.setText(ok ? "Root: granted (KernelSU/Magisk)" : "Root: NOT available — needs su");
            rootText.setTextColor(ContextCompat.getColor(this, ok ? R.color.ok : R.color.err));
            if (!ok) {
                appendLog("No root shell. Install KernelSU or Magisk and grant this app.");
            } else {
                appendLog("Root shell ready (timeout 900s).");
                new Thread(() -> {
                    Installer.Logger lg = this::postLog;
                    Installer.repairOwnership(this, lg);
                    try {
                        java.io.File f = GasterRunner.ensureBinary(this, lg);
                        postLog("gaster ready at " + f.getAbsolutePath());
                    } catch (Exception e) {
                        postLog("Failed to install gaster: " + e.getMessage());
                    }
                    try {
                        java.io.File[] bins = Palera1nRunner.ensureBinaries(this, lg);
                        postLog("palera1n ready at " + bins[0].getAbsolutePath());
                        postLog("checkra1n ready at " + bins[1].getAbsolutePath());
                    } catch (Exception e) {
                        postLog("Failed to install palera1n: " + e.getMessage());
                    }
                }, "extract-bins").start();
            }
        }));
    }

    private void refreshUsb() {
        HashMap<String, UsbDevice> map = usbManager.getDeviceList();
        UsbDevice dfu = null;
        UsbDevice recovery = null;
        StringBuilder sb = new StringBuilder();
        if (map == null || map.isEmpty()) {
            sb.append("USB: no devices");
        } else {
            sb.append("USB (").append(map.size()).append("): ");
            boolean first = true;
            for (UsbDevice d : map.values()) {
                if (!first) sb.append(" | ");
                first = false;
                sb.append(describe(d));
                if (d.getVendorId() == APPLE_VID && d.getProductId() == DFU_PID) dfu = d;
                if (d.getVendorId() == APPLE_VID && d.getProductId() == RECOVERY_PID) recovery = d;
            }
        }
        usbText.setText(sb.toString());

        if (busy) return; // don't clobber the running status line

        if (dfu != null) {
            statusText.setText("DFU device detected — ready");
            statusText.setTextColor(ContextCompat.getColor(this, R.color.ok));
            if (!usbManager.hasPermission(dfu)) requestUsbPermission(dfu);
        } else if (recovery != null) {
            statusText.setText("Recovery mode detected — need DFU, not Recovery");
            statusText.setTextColor(ContextCompat.getColor(this, R.color.warn));
        } else {
            statusText.setText(getString(R.string.status_idle));
            statusText.setTextColor(ContextCompat.getColor(this, R.color.accent));
        }
    }

    private void requestUsbPermission(UsbDevice device) {
        if (usbManager.hasPermission(device)) return;
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent pi = PendingIntent.getBroadcast(this, 0,
                new Intent(ACTION_USB_PERMISSION), flags);
        usbManager.requestPermission(device, pi);
    }

    private void setBusy(boolean value) {
        busy = value;
        btnExploit.setEnabled(!value);
        btnReset.setEnabled(!value);
        btnJailbreak.setEnabled(!value);
        modeRootless.setEnabled(!value);
        modeRootful.setEnabled(!value);
        btnCancel.setEnabled(value);
    }

    private void cancelCurrent() {
        if (currentJob != null) {
            appendLog("[cancel] stopping current run…");
            statusText.setText("Cancelling…");
            statusText.setTextColor(ContextCompat.getColor(this, R.color.warn));
            currentJob.cancel();
            btnCancel.setEnabled(false);
        } else {
            appendLog("[cancel] nothing is running");
        }
    }

    private void runGaster(String[] args, String label) {
        // Immediate, synchronous feedback on the UI thread so a tap is never silent.
        if (busy) {
            appendLog("Busy — a run is in progress. Use Cancel to stop it first.");
            return;
        }
        appendLog("── " + label + " ──");
        setBusy(true);
        statusText.setText("Running gaster " + (args.length > 0 ? args[0] : "") + "…");
        statusText.setTextColor(ContextCompat.getColor(this, R.color.warn));

        currentJob = GasterRunner.run(this, args, new NativeRunner.Listener() {
            @Override
            public void onLine(String line) {
                main.post(() -> appendLog(line));
            }

            @Override
            public void onFinished(int exitCode) {
                main.post(() -> {
                    currentJob = null;
                    setBusy(false);
                    if (exitCode == 0) {
                        statusText.setText("gaster OK — device should be in pwned DFU");
                        statusText.setTextColor(ContextCompat.getColor(MainActivity.this, R.color.ok));
                    } else {
                        statusText.setText("gaster failed (exit " + exitCode + ") — see log");
                        statusText.setTextColor(ContextCompat.getColor(MainActivity.this, R.color.err));
                    }
                    refreshUsb();
                });
            }
        });
    }

    private void runPalera1n() {
        if (busy) {
            appendLog("Busy — a run is in progress. Use Cancel to stop it first.");
            return;
        }
        Palera1nRunner.Mode mode = modeRootful.isChecked()
                ? Palera1nRunner.Mode.ROOTFUL
                : Palera1nRunner.Mode.ROOTLESS;
        appendLog("── Jailbreak (palera1n " + mode.label + ") ──");
        setBusy(true);
        statusText.setText("Running palera1n (" + mode.label + ")…");
        statusText.setTextColor(ContextCompat.getColor(this, R.color.warn));
        appendLog("Starting palera1n " + mode.label + " — keep the cable seated; this can take several minutes.");

        currentJob = Palera1nRunner.run(this, mode, new NativeRunner.Listener() {
            @Override
            public void onLine(String line) {
                main.post(() -> appendLog(line));
            }

            @Override
            public void onFinished(int exitCode) {
                main.post(() -> {
                    currentJob = null;
                    setBusy(false);
                    if (exitCode == 0) {
                        statusText.setText("palera1n finished OK (exit 0)");
                        statusText.setTextColor(ContextCompat.getColor(MainActivity.this, R.color.ok));
                    } else {
                        statusText.setText("palera1n failed (exit " + exitCode + ") — see log");
                        statusText.setTextColor(ContextCompat.getColor(MainActivity.this, R.color.err));
                    }
                    refreshUsb();
                });
            }
        });
    }

    private void postLog(String line) {
        main.post(() -> appendLog(line));
    }

    private void appendLog(String line) {
        if (logText.getText().length() > 0) {
            logText.append("\n");
        }
        logText.append(line);
        logScroll.post(() -> logScroll.fullScroll(ScrollView.FOCUS_DOWN));
    }

    private static String describe(UsbDevice d) {
        return String.format(Locale.US, "%04x:%04x %s",
                d.getVendorId(), d.getProductId(),
                d.getDeviceName() != null ? d.getDeviceName() : "");
    }
}
