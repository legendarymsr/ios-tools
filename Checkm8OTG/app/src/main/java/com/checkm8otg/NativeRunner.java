package com.checkm8otg;

import android.content.Context;
import android.util.Log;

import com.topjohnwu.superuser.CallbackList;
import com.topjohnwu.superuser.Shell;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Runs a bundled native tool (gaster / palera1n) as root with:
 *   - live line-by-line streaming of stdout AND stderr into the app log
 *   - an explicit root pre-check with a loud error if su is missing
 *   - a USB pre-flight that logs what /dev/bus/usb looks like to the tool
 *   - a cancellable child process (own session via setsid) so a stuck run can
 *     be stopped instead of freezing the UI for the 900s libsu timeout.
 *
 * The run script lives in the app cache (always writable by the app uid); the
 * transient pid file lives in the root-managed exec dir. The exit code is read
 * from the streamed "[exit N]" marker, so no app-owned exit file is needed.
 */
public final class NativeRunner {
    private static final String TAG = "NativeRunner";
    private static final Pattern EXIT_RE = Pattern.compile("^\\[exit (-?\\d+)\\]$");

    public interface Listener {
        void onLine(String line);
        void onFinished(int exitCode);
    }

    private NativeRunner() {}

    public static final class Handle {
        private final String pidFilePath;
        private volatile boolean cancelled = false;
        Handle(String pidFilePath) { this.pidFilePath = pidFilePath; }

        public void cancel() {
            cancelled = true;
            new Thread(() -> {
                Shell killer = null;
                try {
                    killer = Shell.Builder.create()
                            .setFlags(Shell.FLAG_MOUNT_MASTER)
                            .setTimeout(20)
                            .build();
                    killer.newJob().add(
                            "PID=$(cat '" + pidFilePath + "' 2>/dev/null); " +
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

    public static Handle run(Context ctx, File binary, File tmpDir,
                             String innerCmd, Listener listener) {
        File script = new File(ctx.getCacheDir(), "run.sh");
        String pidFilePath = Installer.EXEC_DIR + "/run.pid";
        Handle handle = new Handle(pidFilePath);

        new Thread(() -> {
            try {
                Shell shell = Shell.getShell();
                if (!shell.isRoot()) {
                    listener.onLine("[error] No root shell. KernelSU/Magisk did not grant this app su.");
                    listener.onLine("[error] Open KernelSU-Next and allow 'Checkm8 OTG', then retry.");
                    listener.onFinished(-1);
                    return;
                }
                if (binary == null || !binary.exists()) {
                    listener.onLine("[error] tool missing: " + (binary != null ? binary.getAbsolutePath() : "null"));
                    listener.onFinished(-1);
                    return;
                }

                // USB pre-flight.
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

                // Write the real command to a script in the app cache (app-writable).
                String body =
                        "#!/system/bin/sh\n" +
                        "export TERM=xterm\n" +
                        (tmpDir != null ? "export TMPDIR='" + tmpDir.getAbsolutePath() + "'\n" : "") +
                        innerCmd + "\n";
                try (FileOutputStream fos = new FileOutputStream(script)) {
                    fos.write(body.getBytes(StandardCharsets.UTF_8));
                }
                //noinspection ResultOfMethodCallIgnored
                script.setReadable(true, false);

                listener.onLine("$ su -c " + innerCmd);

                if (handle.isCancelled()) {
                    listener.onLine("[cancelled] before start");
                    listener.onFinished(-1);
                    return;
                }

                // Run detached (setsid) so cancel can kill the whole group.
                final AtomicInteger exit = new AtomicInteger(-1);
                List<String> live = new CallbackList<String>() {
                    @Override public void onAddElement(String s) {
                        Matcher m = EXIT_RE.matcher(s.trim());
                        if (m.matches()) {
                            try { exit.set(Integer.parseInt(m.group(1))); } catch (Exception ignored) {}
                        }
                        listener.onLine(s);
                    }
                };
                String wrapper =
                        "rm -f '" + pidFilePath + "' 2>/dev/null; " +
                        "setsid sh '" + script.getAbsolutePath() + "' 2>&1 & " +
                        "CHILD=$!; echo $CHILD > '" + pidFilePath + "'; " +
                        "wait $CHILD; RC=$?; " +
                        "rm -f '" + pidFilePath + "' 2>/dev/null; " +
                        "echo \"[exit $RC]\"";
                Shell.cmd(wrapper).to(live).exec();

                if (handle.isCancelled()) {
                    listener.onLine("[cancelled] process stopped by user");
                }
                listener.onFinished(exit.get());
            } catch (Throwable e) {
                Log.e(TAG, "run failed", e);
                listener.onLine("[exception] " + e.getClass().getSimpleName()
                        + ": " + e.getMessage());
                listener.onFinished(-1);
            }
        }, "native-runner").start();

        return handle;
    }
}
