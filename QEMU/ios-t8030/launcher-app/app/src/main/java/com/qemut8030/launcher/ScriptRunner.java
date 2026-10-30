// SPDX-License-Identifier: GPL-3.0-or-later
package com.qemut8030.launcher;

import android.content.Context;
import android.content.res.AssetManager;
import com.topjohnwu.superuser.CallbackList;
import com.topjohnwu.superuser.Shell;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;

/** Extracts bundled payload (scripts + binaries) and runs steps as root. */
public final class ScriptRunner {

    public interface Listener {
        void onLine(String line);
        void onFinished(int exitCode);
    }

    /**
     * Copy assets/payload/ into filesDir/payload. Re-extracts whenever
     * {@link BuildConfig#VERSION_CODE} changes (or marker missing), so nested
     * assets added in a later APK are not skipped after an older install.
     */
    public static File extractPayload(Context ctx) throws IOException {
        File out = new File(ctx.getFilesDir(), "payload");
        File marker = new File(out, ".payload_version");
        String want = String.valueOf(BuildConfig.VERSION_CODE);
        boolean fresh = false;
        if (out.isDirectory() && marker.isFile()) {
            String have = readSmall(marker);
            if (want.equals(have.trim())) {
                // Still re-copy: cheap and repairs partial extracts. Marker only
                // gates wiping stale empty dirs from older extract bugs.
                fresh = true;
            }
        }
        if (!fresh) {
            deleteRecursive(out);
        }
        if (!out.exists() && !out.mkdirs()) throw new IOException("mkdir failed: " + out);
        copyAssetDir(ctx.getAssets(), "payload", out);
        writeSmall(marker, want);
        return out;
    }

    /**
     * Recursively copy an asset directory.
     * AssetManager.list(file) returns an empty array (not null) on modern
     * Android — treat length-0 as "try open as file", otherwise recurse.
     */
    private static void copyAssetDir(AssetManager am, String assetPath, File destDir) throws IOException {
        if (!destDir.exists() && !destDir.mkdirs()) {
            throw new IOException("mkdir failed: " + destDir);
        }
        String[] names = am.list(assetPath);
        if (names == null || names.length == 0) return;
        for (String n : names) {
            if (n == null || n.isEmpty() || n.equals(".") || n.equals("..")) continue;
            // Skip our runtime marker if somehow bundled
            if (n.equals(".payload_version")) continue;
            String childAsset = assetPath + "/" + n;
            File childDest = new File(destDir, n);
            String[] sub;
            try {
                sub = am.list(childAsset);
            } catch (IOException e) {
                sub = null;
            }
            if (sub != null && sub.length > 0) {
                // Directory with children
                copyAssetDir(am, childAsset, childDest);
                continue;
            }
            // File, or empty directory. Prefer open-as-file.
            try (InputStream is = am.open(childAsset)) {
                if (childDest.isDirectory()) deleteRecursive(childDest);
                try (OutputStream os = new FileOutputStream(childDest)) {
                    byte[] buf = new byte[8192];
                    int r;
                    while ((r = is.read(buf)) > 0) os.write(buf, 0, r);
                }
                //noinspection ResultOfMethodCallIgnored
                childDest.setReadable(true, false);
                //noinspection ResultOfMethodCallIgnored
                childDest.setExecutable(true, false);
            } catch (IOException openFail) {
                // Empty directory (or unreadable asset) — ensure dir exists
                if (!childDest.exists() && !childDest.mkdirs()) {
                    throw new IOException("cannot extract asset " + childAsset + ": " + openFail.getMessage());
                }
            }
        }
    }

    private static void deleteRecursive(File f) {
        if (f == null || !f.exists()) return;
        File[] kids = f.listFiles();
        if (kids != null) for (File k : kids) deleteRecursive(k);
        //noinspection ResultOfMethodCallIgnored
        f.delete();
    }

    private static String readSmall(File f) throws IOException {
        try (InputStream is = new java.io.FileInputStream(f)) {
            byte[] b = is.readAllBytes();
            return new String(b, StandardCharsets.UTF_8);
        }
    }

    private static void writeSmall(File f, String s) throws IOException {
        try (OutputStream os = new FileOutputStream(f)) {
            os.write(s.getBytes(StandardCharsets.UTF_8));
        }
    }

    /** Run a shell command as root, streaming stdout+stderr line by line. */
    public static void run(final String command, final Listener l) {
        new Thread(() -> {
            List<String> cb = new CallbackList<String>() {
                @Override public void onAddElement(String s) { l.onLine(s); }
            };
            Shell.Result res = Shell.cmd(command).to(cb, cb).exec();
            l.onFinished(res.getCode());
        }).start();
    }
}
