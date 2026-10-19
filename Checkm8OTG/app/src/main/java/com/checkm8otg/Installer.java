package com.checkm8otg;

import android.content.Context;
import android.os.Process;

import com.topjohnwu.superuser.CallbackList;
import com.topjohnwu.superuser.Shell;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.List;

/**
 * Installs the bundled native tools into a root-managed exec directory.
 *
 * Why not extract into the app's filesDir: an earlier root run could leave the
 * target owned by root (mode 755 or a root SELinux label), after which the app
 * uid can no longer open it for writing -> EACCES. So we never write over an
 * existing tool in place from the app uid. Instead:
 *   1. copy the asset to the app cache as the app (always writable),
 *   2. hash it, and if the installed copy already matches, skip,
 *   3. otherwise, as root, rm -f the old copy, cp into a temp name and rename,
 *      chmod 755 and set an SELinux context, all in a root-owned exec dir.
 */
public final class Installer {
    /** Root-owned, executable-friendly location, outside the app sandbox. */
    public static final String EXEC_DIR = "/data/local/tmp/checkm8otg";

    public interface Logger { void log(String line); }

    private Installer() {}

    private static void say(Logger log, String s) {
        if (log != null) log.log(s);
    }

    /** Copy an asset to a file as the app uid. */
    private static void copyAsset(Context ctx, String assetName, File out) throws Exception {
        try (InputStream in = ctx.getAssets().open(assetName);
             FileOutputStream fos = new FileOutputStream(out)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) fos.write(buf, 0, n);
        }
    }

    private static String sha256(File f) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) md.update(buf, 0, n);
        }
        StringBuilder sb = new StringBuilder();
        for (byte b : md.digest()) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    /**
     * Ensure {@code assetName} is installed as {@code destName} in {@link #EXEC_DIR},
     * running the whole install through root. Returns the installed File.
     */
    public static File install(Context ctx, String assetName, String destName, Logger log) throws Exception {
        if (!Shell.getShell().isRoot()) {
            throw new IllegalStateException("root shell required to install " + destName);
        }
        File stage = new File(ctx.getCacheDir(), destName + ".stage");
        //noinspection ResultOfMethodCallIgnored
        stage.delete();
        copyAsset(ctx, assetName, stage);
        //noinspection ResultOfMethodCallIgnored
        stage.setReadable(true, false);
        String want = sha256(stage);
        String dest = EXEC_DIR + "/" + destName;
        say(log, "[install] " + destName + " asset sha256=" + want.substring(0, 12) + "…");

        List<String> out = new CallbackList<String>() {
            @Override public void onAddElement(String s) { say(log, s); }
        };
        String script =
                "set -e 2>/dev/null; " +
                "mkdir -p '" + EXEC_DIR + "'; chmod 755 '" + EXEC_DIR + "'; " +
                "chcon u:object_r:shell_data_file:s0 '" + EXEC_DIR + "' 2>/dev/null || true; " +
                "WANT='" + want + "'; DEST='" + dest + "'; STAGE='" + stage.getAbsolutePath() + "'; " +
                "CUR=''; [ -f \"$DEST\" ] && CUR=$(sha256sum \"$DEST\" 2>/dev/null | awk '{print $1}'); " +
                "if [ \"$CUR\" = \"$WANT\" ]; then echo \"[install] " + destName + " already current — skip\"; " +
                "else " +
                "  if [ -n \"$CUR\" ]; then echo \"[install] " + destName + " differs/old — replacing\"; else echo \"[install] " + destName + " not present — installing\"; fi; " +
                "  rm -f \"$DEST\" \"$DEST.tmp\" 2>/dev/null || true; " +
                "  cp \"$STAGE\" \"$DEST.tmp\"; mv -f \"$DEST.tmp\" \"$DEST\"; " +
                "fi; " +
                "chmod 755 \"$DEST\"; " +
                "chcon u:object_r:shell_data_file:s0 \"$DEST\" 2>/dev/null || chcon u:object_r:system_file:s0 \"$DEST\" 2>/dev/null || true; " +
                "rm -f \"$STAGE\" 2>/dev/null || true; " +
                "NOW=$(sha256sum \"$DEST\" 2>/dev/null | awk '{print $1}'); " +
                "[ \"$NOW\" = \"$WANT\" ] && echo \"[install] " + destName + " verified at $DEST\" || echo \"[install] " + destName + " VERIFY FAILED ($NOW)\"; " +
                "ls -lZ \"$DEST\" 2>/dev/null | sed 's/^/[install] /' || ls -l \"$DEST\" | sed 's/^/[install] /'";
        Shell.cmd(script).to(out).exec();
        //noinspection ResultOfMethodCallIgnored
        stage.delete();
        return new File(dest);
    }

    /** Repair ownership/labels of the app's files dir after any earlier root run. */
    public static void repairOwnership(Context ctx, Logger log) {
        try {
            if (!Shell.getShell().isRoot()) return;
            int uid = Process.myUid();
            File fdir = ctx.getFilesDir();
            List<String> out = new CallbackList<String>() {
                @Override public void onAddElement(String s) { say(log, s); }
            };
            Shell.cmd(
                    "U=" + uid + "; D='" + fdir.getAbsolutePath() + "'; " +
                    "chown -R $U:$U \"$D\" 2>/dev/null && echo \"[repair] chown $U $D ok\" || echo \"[repair] chown skipped\"; " +
                    "restorecon -R \"$D\" 2>/dev/null || true"
            ).to(out).exec();
        } catch (Throwable ignored) {}
    }
}
