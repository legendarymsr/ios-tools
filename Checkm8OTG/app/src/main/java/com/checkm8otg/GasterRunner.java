package com.checkm8otg;

import android.content.Context;

import com.topjohnwu.superuser.Shell;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;

/**
 * Extracts the bundled aarch64 gaster binary and runs it as root with live
 * output streaming (see {@link NativeRunner}). gaster talks to the iPhone in
 * DFU over usbfs (/dev/bus/usb) via libusb; root is required for device-node
 * access on stock Android SELinux.
 */
public final class GasterRunner {
    private static final String ASSET_NAME = "gaster";
    private static final String BIN_NAME = "gaster";

    public interface Listener extends NativeRunner.Listener {}

    private GasterRunner() {}

    /** Copy asset -> filesDir/bin/gaster and chmod 755 (as app + as root). */
    public static File ensureBinary(Context ctx) throws Exception {
        File dir = new File(ctx.getFilesDir(), "bin");
        if (!dir.exists() && !dir.mkdirs()) {
            throw new IllegalStateException("Cannot create " + dir);
        }
        File out = new File(dir, BIN_NAME);
        try (InputStream in = ctx.getAssets().open(ASSET_NAME);
             FileOutputStream fos = new FileOutputStream(out)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                fos.write(buf, 0, n);
            }
        }
        //noinspection ResultOfMethodCallIgnored
        out.setExecutable(true, false);
        Shell.cmd("chmod 755 '" + out.getAbsolutePath() + "'").exec();
        Shell.cmd("chcon u:object_r:shell_exec_file:s0 '" + out.getAbsolutePath() + "' 2>/dev/null || true").exec();
        Shell.cmd("chcon u:object_r:system_file:s0 '" + out.getAbsolutePath() + "' 2>/dev/null || true").exec();
        return out;
    }

    /**
     * Extract (always, so updates land) and run gaster with the given args.
     * Returns a Handle that can cancel a stuck run.
     */
    public static NativeRunner.Handle run(Context ctx, String[] args, NativeRunner.Listener listener) {
        try {
            File bin = ensureBinary(ctx);
            StringBuilder sb = new StringBuilder();
            sb.append("'").append(bin.getAbsolutePath()).append("'");
            if (args != null) {
                for (String a : args) {
                    sb.append(' ').append(a);
                }
            }
            return NativeRunner.run(ctx, bin, null, sb.toString(), listener);
        } catch (Exception e) {
            listener.onLine("[exception] extract gaster: " + e.getMessage());
            listener.onFinished(-1);
            return null;
        }
    }
}
