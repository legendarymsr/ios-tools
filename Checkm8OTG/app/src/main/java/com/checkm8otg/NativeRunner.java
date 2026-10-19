package com.checkm8otg;

import android.content.Context;
import android.util.Log;

import com.topjohnwu.superuser.CallbackList;
import com.topjohnwu.superuser.Shell;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;

/**
 * Runs a bundled native tool (gaster / palera1n) as root with:
 *   - live line-by-line streaming of stdout AND stderr into the app log
 *   - an explicit root pre-check with a loud error if su is missing
 *   - a USB pre-flight that logs what /dev/bus/usb looks like to the tool
 *   - a cancellable child process (own session via setsid) so a stuck
 *     run (e.g. gaster retrying against an unreachable device) can be
 *     stopped instead of freezing the UI for the 900s libsu timeout.
 *
 * Every path reports something: the command, each output line, and a
 * final [exit N] / [exception ...] / [cancelled] marker.
 */
public final class NativeRunner {
    private static final String TAG = "NativeRunner";

    public interface Listener {
        void onLine(String line);
        void onFinished(int exitCode);
    }

    private NativeRunner() {}

    /** Handle returned to the caller so a running job can be cancelled. */
    public static final class Handle {
        private final File pidFile;
        private volatile boolean cancelled = false;
        Handle(File pidFile) { this.pidFile = pidFile; }

        /** Kill the child process group from an independent root shell. */
        public void cancel() {
            cancelled = true;
            new Thread(() -> {
                Shell killer = null;
                try {
                    killer = Shell.Builder.create()
                            .setFlags(Shell.FLAG_MOUNT_MASTER)
                            .setTimeout(20)
                            .build();
                    String p = pidFile.getAbsolutePath();
                    // Negative PID targets the whole process group (setsid leader).
                    killer.newJob().add(
                            "PID=$(cat '" + p + "' 2>/dev/null); " +
                            "[ -n \"$PID\" ] && kill -TERM -\"$PID\" 2>/dev/null; " +
                            "sleep 1; " +
                            "[ -n \"$PID\" ] && kill -KILL -\"$PID\" 2>/dev/null; " +
                            "pkill -KILL gaster 2>/dev/null; " +
                            "pkill -KILL palera1n 2>/dev/null; true"
                    ).exec();
                } catch (Throwable t) {
                    Log.e(TAG, "cancel failed", t);
                } finally {
                    if (killer != null) { try { killer.close(); } catch (Exception ignored) {} }
                }
            }, "native-cancel").start();
        }

        public boolean isCancelled() { return cancelled; }
    }

    /**
     * @param ctx      context
     * @param binary   extracted, chmod'd tool to run
     * @param tmpDir   writable+exec TMPDIR (may be null)
     * @param innerCmd the full shell command line to execute (binary already quoted inside)
     * @param listener streaming callback
     * @return a Handle that can cancel the run
     */
    public static Handle run(Context ctx, File binary, File tmpDir,
                             String innerCmd, Listener listener) {
        File binDir = new File(ctx.getFilesDir(), "bin");
        //noinspection ResultOfMethodCallIgnored
        binDir.mkdirs();
        File script = new File(binDir, "run.sh");
        File pidFile = new File(binDir, "run.pid");
        File doneFile = new File(binDir, "run.exit");
        Handle handle = new Handle(pidFile);

        new Thread(() -> {
            try {
                // 0) Root pre-check — fail loudly instead of running non-root silently.
                Shell shell = Shell.getShell();
                if (!shell.isRoot()) {
                    listener.onLine("[error] No root shell. KernelSU/Magisk did not grant this app su.");
                    listener.onLine("[error] Open KernelSU-Next and allow 'Checkm8 OTG', then retry.");
                    listener.onFinished(-1);
                    return;
                }

                // 1) Binary sanity.
                if (binary == null || !binary.exists()) {
                    listener.onLine("[error] tool missing: " + (binary != null ? binary.getAbsolutePath() : "null"));
                    listener.onFinished(-1);
                    return;
                }

                // 2) USB pre-flight: show the tool what it will (or won't) see.
                listener.onLine("[usb] preparing /dev/bus/usb access…");
                List<String> pre = new CallbackList<String>() {
                    @Override public void onAddElement(String s) { listener.onLine(s); }
                };
                Shell.cmd(
                        "setenforce 0 2>/dev/null; " +
                        "echo \"[usb] selinux=$(getenforce 2>/dev/null)\"; " +
                        "chmod 755 /dev/bus/usb /dev/bus/usb/* 2>/dev/null || true; " +
                        "for d in /dev/bus/usb/*/*; do [ -e \"$d\" ] && chmod 666 \"$d\" 2>/dev/null || true; done; " +
                        "echo \"[usb] nodes:\"; ls -l /dev/bus/usb/*/* 2>/dev/null || echo '[usb] (no device nodes)'; " +
                        "if command -v lsusb >/dev/null 2>&1; then lsusb 2>/dev/null | sed 's/^/[usb] /'; fi; " +
                        "D=$(ls -d /sys/bus/usb/devices/* 2>/dev/null | xargs -r -n1 sh -c 'grep -qi 05ac \"$0/idVendor\" 2>/dev/null && echo $0' 2>/dev/null); " +
                        "[ -n \"$D\" ] && echo \"[usb] apple device present in sysfs\" || echo \"[usb] no apple VID (05ac) in sysfs — tool will not find the iPhone\""
                ).to(pre).exec();

                // 3) Write the real command to a script so quoting stays sane.
                String body =
                        "#!/system/bin/sh\n" +
                        "export TERM=xterm\n" +
                        (tmpDir != null ? "export TMPDIR='" + tmpDir.getAbsolutePath() + "'\n" : "") +
                        innerCmd + "\n";
                try (FileOutputStream fos = new FileOutputStream(script)) {
                    fos.write(body.getBytes(StandardCharsets.UTF_8));
                }
                Shell.cmd("chmod 755 '" + script.getAbsolutePath() + "'").exec();

                listener.onLine("$ su -c " + innerCmd);

                if (handle.isCancelled()) {
                    listener.onLine("[cancelled] before start");
                    listener.onFinished(-1);
                    return;
                }

                // 4) Run detached in its own session (setsid) so we can kill the
                //    whole group on cancel, stream output live, and capture exit.
                //noinspection ResultOfMethodCallIgnored
                pidFile.delete();
                //noinspection ResultOfMethodCallIgnored
                doneFile.delete();
                List<String> live = new CallbackList<String>() {
                    @Override public void onAddElement(String s) { listener.onLine(s); }
                };
                String wrapper =
                        "setsid sh '" + script.getAbsolutePath() + "' 2>&1 & " +
                        "CHILD=$!; echo $CHILD > '" + pidFile.getAbsolutePath() + "'; " +
                        "wait $CHILD; RC=$?; echo $RC > '" + doneFile.getAbsolutePath() + "'; " +
                        "echo \"[exit $RC]\"";

                // Single combined stream (stdout+stderr already merged via 2>&1).
                Shell.cmd(wrapper).to(live).exec();

                int rc = -1;
                try {
                    if (doneFile.exists()) {
                        String s = readTrim(doneFile);
                        if (s != null && !s.isEmpty()) rc = Integer.parseInt(s);
                    }
                } catch (Exception ignored) {}

                if (handle.isCancelled()) {
                    listener.onLine("[cancelled] process stopped by user");
                }
                listener.onFinished(rc);
            } catch (Throwable e) {
                Log.e(TAG, "run failed", e);
                listener.onLine("[exception] " + e.getClass().getSimpleName()
                        + ": " + e.getMessage());
                listener.onFinished(-1);
            }
        }, "native-runner").start();

        return handle;
    }

    private static String readTrim(File f) {
        try {
            byte[] b = new byte[16];
            try (java.io.FileInputStream in = new java.io.FileInputStream(f)) {
                int n = in.read(b);
                if (n <= 0) return "";
                return new String(b, 0, n, StandardCharsets.UTF_8).trim();
            }
        } catch (Exception e) {
            return "";
        }
    }
}
