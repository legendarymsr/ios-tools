package com.qemukvm.launcher;

import android.content.Context;
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
        if (!out.exists() && !out.mkdirs()) throw new IOException("mkdir failed");
        String[] names = ctx.getAssets().list("payload");
        if (names != null) {
            for (String n : names) {
                File f = new File(out, n);
                try (InputStream is = ctx.getAssets().open("payload/" + n);
                     OutputStream os = new FileOutputStream(f)) {
                    byte[] buf = new byte[8192];
                    int r;
                    while ((r = is.read(buf)) > 0) os.write(buf, 0, r);
                }
                //noinspection ResultOfMethodCallIgnored
                f.setReadable(true, false);
                //noinspection ResultOfMethodCallIgnored
                f.setExecutable(true, false);
            }
        }
        return out;
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
