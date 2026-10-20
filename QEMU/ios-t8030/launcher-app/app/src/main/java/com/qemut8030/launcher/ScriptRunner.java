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
import java.util.List;

/** Extracts bundled payload (scripts + binaries) and runs steps as root. */
public final class ScriptRunner {

    public interface Listener {
        void onLine(String line);
        void onFinished(int exitCode);
    }

    /** Copy everything under assets/payload/ into filesDir/payload and chmod +x. */
    public static File extractPayload(Context ctx) throws IOException {
        File out = new File(ctx.getFilesDir(), "payload");
        if (!out.exists() && !out.mkdirs()) throw new IOException("mkdir failed: " + out);
        copyAssetDir(ctx.getAssets(), "payload", out);
        return out;
    }

    /**
     * Recursively copy an asset directory. AssetManager.list() returns null for a
     * file and a (possibly empty) array for a directory — so a nested folder like
     * vhci-bridge/ must be recursed; opening it as a file aborts the whole extract.
     */
    private static void copyAssetDir(AssetManager am, String assetPath, File destDir) throws IOException {
        if (!destDir.exists() && !destDir.mkdirs()) {
            throw new IOException("mkdir failed: " + destDir);
        }
        String[] names = am.list(assetPath);
        if (names == null) return;
        for (String n : names) {
            String childAsset = assetPath + "/" + n;
            File childDest = new File(destDir, n);
            String[] sub = am.list(childAsset);
            if (sub == null) {
                try (InputStream is = am.open(childAsset);
                     OutputStream os = new FileOutputStream(childDest)) {
                    byte[] buf = new byte[8192];
                    int r;
                    while ((r = is.read(buf)) > 0) os.write(buf, 0, r);
                }
                //noinspection ResultOfMethodCallIgnored
                childDest.setReadable(true, false);
                //noinspection ResultOfMethodCallIgnored
                childDest.setExecutable(true, false);
            } else {
                copyAssetDir(am, childAsset, childDest);
            }
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
