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
 * Extracts the bundled aarch64 palera1n (Linux musl-static v2.2) and optional
 * checkra1n override, then runs them as root. Assets are embedded inside
 * palera1n (Pongo.bin, ramdisk, binpack, kpf, checkra1n); we also ship a
 * standalone checkra1n and pass -i so TMPDIR exec / SELinux is under our control.
 */
public final class Palera1nRunner {
    private static final String TAG = "Palera1nRunner";
    private static final String ASSET_PALERA1N = "palera1n";
    private static final String ASSET_CHECKRA1N = "checkra1n";

    public enum Mode {
        ROOTLESS("-l", "rootless"),
        ROOTFUL("-f", "rootful/fakefs");

        final String flag;
        final String label;
        Mode(String flag, String label) {
            this.flag = flag;
            this.label = label;
        }
    }

    public interface Listener {
        void onLine(String line);
        void onFinished(int exitCode);
    }

    private Palera1nRunner() {}

    private static File extractAsset(Context ctx, String assetName, File out) throws Exception {
        try (InputStream in = ctx.getAssets().open(assetName);
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

    /** Extract palera1n + checkra1n and prepare TMPDIR. */
    public static File[] ensureBinaries(Context ctx) throws Exception {
        File dir = new File(ctx.getFilesDir(), "bin");
        if (!dir.exists() && !dir.mkdirs()) {
            throw new IllegalStateException("Cannot create " + dir);
        }
        File tmp = new File(ctx.getFilesDir(), "tmp");
        if (!tmp.exists() && !tmp.mkdirs()) {
            throw new IllegalStateException("Cannot create " + tmp);
        }
        Shell.cmd("chmod 777 '" + tmp.getAbsolutePath() + "'").exec();
        Shell.cmd("chcon u:object_r:shell_data_file:s0 '" + tmp.getAbsolutePath() + "' 2>/dev/null || true").exec();

        File palera1n = extractAsset(ctx, ASSET_PALERA1N, new File(dir, "palera1n"));
        File checkra1n = extractAsset(ctx, ASSET_CHECKRA1N, new File(dir, "checkra1n"));
        return new File[]{palera1n, checkra1n, tmp};
    }

    /**
     * Run palera1n in the given mode.
     * Always passes -S (no colors), -v (debug log), -i checkra1n (bundled override).
     */
    public static void run(Context ctx, Mode mode, Listener listener) {
        new Thread(() -> {
            try {
                File[] bins = ensureBinaries(ctx);
                File palera1n = bins[0];
                File checkra1n = bins[1];
                File tmp = bins[2];
                GasterRunner.fixUsbPerms();

                // TMPDIR must be writable+executable; palera1n extracts embedded
                // blobs here if -i/-k/-r etc. are not all overridden. We override
                // checkra1n with -i; other assets stay embedded in the binary.
                StringBuilder sb = new StringBuilder();
                sb.append("export TMPDIR='").append(tmp.getAbsolutePath()).append("'; ");
                sb.append("export TERM=xterm; ");
                sb.append("'").append(palera1n.getAbsolutePath()).append("'");
                sb.append(' ').append(mode.flag);
                sb.append(" -S -v");
                sb.append(" -i '").append(checkra1n.getAbsolutePath()).append("'");

                String full = sb.toString();
                listener.onLine("$ su -c " + full);
                listener.onLine("[mode] " + mode.label + " (" + mode.flag + ")");
                listener.onLine("[note] palera1n v2.2 linux-arm64 (musl-static); live USB untested on this build host");

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
        }, "palera1n-runner").start();
    }
}
