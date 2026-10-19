package com.checkm8otg;

import android.content.Context;
import android.util.Log;

import com.topjohnwu.superuser.Shell;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;

/**
 * Extracts the bundled aarch64 gaster binary and runs it as root.
 * gaster talks to the iPhone in DFU over usbfs (/dev/bus/usb) via libusb;
 * root is required for device node access on stock Android SELinux.
 */
public final class GasterRunner {
    private static final String TAG = "GasterRunner";
    private static final String ASSET_NAME = "gaster";
    private static final String BIN_NAME = "gaster";

    public interface Listener {
        void onLine(String line);
        void onFinished(int exitCode);
    }

    private GasterRunner() {}

    /** Copy asset → filesDir/bin/gaster and chmod 755 (as app + as root). */
    public static File ensureBinary(Context ctx) throws Exception {
        File dir = new File(ctx.getFilesDir(), "bin");
        if (!dir.exists() && !dir.mkdirs()) {
            throw new IllegalStateException("Cannot create " + dir);
        }
        File out = new File(dir, BIN_NAME);
        // Re-extract every launch so updates replace the binary
        try (InputStream in = ctx.getAssets().open(ASSET_NAME);
             FileOutputStream fos = new FileOutputStream(out)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                fos.write(buf, 0, n);
            }
        }
        // App-owned chmod
        //noinspection ResultOfMethodCallIgnored
        out.setExecutable(true, false);
        // Also force as root in case of noexec mounts / SELinux
        Shell.cmd("chmod 755 '" + out.getAbsolutePath() + "'").exec();
        // SELinux: allow execution from app data (best-effort)
        Shell.cmd("chcon u:object_r:shell_exec_file:s0 '" + out.getAbsolutePath() + "' 2>/dev/null || true").exec();
        Shell.cmd("chcon u:object_r:system_file:s0 '" + out.getAbsolutePath() + "' 2>/dev/null || true").exec();
        return out;
    }

    /** Best-effort: loosen USB device node perms so libusb can open DFU. */
    public static void fixUsbPerms() {
        // Apple VID 05ac appears as 05ac in usbfs path names sometimes as dir entries
        Shell.cmd(
                "for d in /dev/bus/usb/*/*; do " +
                "  [ -e \"$d\" ] || continue; " +
                "  chmod 666 \"$d\" 2>/dev/null || true; " +
                "done; " +
                "chmod 755 /dev/bus/usb /dev/bus/usb/* 2>/dev/null || true; " +
                "setenforce 0 2>/dev/null || true"
        ).exec();
    }

    public static void run(Context ctx, String[] args, Listener listener) {
        new Thread(() -> {
            try {
                File bin = ensureBinary(ctx);
                fixUsbPerms();
                List<String> cmd = new ArrayList<>();
                // Quote path; gaster args are simple tokens (pwn, reset, decrypt, ...)
                StringBuilder sb = new StringBuilder();
                sb.append("'").append(bin.getAbsolutePath()).append("'");
                if (args != null) {
                    for (String a : args) {
                        sb.append(' ').append(a);
                    }
                }
                String full = sb.toString();
                listener.onLine("$ su -c " + full);
                Shell.Result result = Shell.cmd(full).to(new ArrayList<>(), new ArrayList<>()).exec();
                for (String line : result.getOut()) {
                    listener.onLine(line);
                }
                for (String line : result.getErr()) {
                    listener.onLine("[err] " + line);
                }
                listener.onLine("[exit " + result.getCode() + "]");
                listener.onFinished(result.getCode());
            } catch (Exception e) {
                Log.e(TAG, "run failed", e);
                listener.onLine("[exception] " + e.getMessage());
                listener.onFinished(-1);
            }
        }, "gaster-runner").start();
    }
}
