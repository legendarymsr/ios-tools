package com.checkm8otg;

import android.content.Context;

import com.topjohnwu.superuser.Shell;

import java.io.File;

/**
 * Installs the bundled aarch64 palera1n (v2.2 musl-static) and checkra1n into
 * the root-managed exec dir (see {@link Installer}) and runs them as root with
 * live output streaming (see {@link NativeRunner}).
 */
public final class Palera1nRunner {
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

    public interface Listener extends NativeRunner.Listener {}

    private Palera1nRunner() {}

    public static File[] ensureBinaries(Context ctx) throws Exception {
        return ensureBinaries(ctx, null);
    }

    /** Install palera1n + checkra1n through root and prepare a root-owned TMPDIR. */
    public static File[] ensureBinaries(Context ctx, Installer.Logger log) throws Exception {
        File palera1n = Installer.install(ctx, ASSET_PALERA1N, "palera1n", log);
        File checkra1n = Installer.install(ctx, ASSET_CHECKRA1N, "checkra1n", log);
        File tmp = new File(Installer.EXEC_DIR, "tmp");
        Shell.cmd(
                "mkdir -p '" + tmp.getAbsolutePath() + "'; chmod 777 '" + tmp.getAbsolutePath() + "'; " +
                "chcon u:object_r:shell_data_file:s0 '" + tmp.getAbsolutePath() + "' 2>/dev/null || true"
        ).exec();
        if (log != null) log.log("[install] TMPDIR " + tmp.getAbsolutePath());
        return new File[]{palera1n, checkra1n, tmp};
    }

    public static NativeRunner.Handle run(Context ctx, Mode mode, NativeRunner.Listener listener) {
        try {
            File[] bins = ensureBinaries(ctx, listener::onLine);
            File palera1n = bins[0];
            File checkra1n = bins[1];
            File tmp = bins[2];

            StringBuilder sb = new StringBuilder();
            sb.append("'").append(palera1n.getAbsolutePath()).append("'");
            sb.append(' ').append(mode.flag);
            sb.append(" -S -v");
            sb.append(" -i '").append(checkra1n.getAbsolutePath()).append("'");

            listener.onLine("[mode] " + mode.label + " (" + mode.flag + ")");
            listener.onLine("[note] palera1n v2.2 linux-arm64 (musl-static); live USB untested on this build host");
            return NativeRunner.run(ctx, palera1n, tmp, sb.toString(), listener);
        } catch (Exception e) {
            listener.onLine("[exception] install palera1n: " + e.getMessage());
            listener.onFinished(-1);
            return null;
        }
    }
}
