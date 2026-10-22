package com.qemut8030.launcher;

import android.content.Context;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.io.RandomAccessFile;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Process-wide log shared by MainActivity and the separate "iOS Emu Logs"
 * launcher entry (LogActivity). Mirrored to filesDir/launcher.log so earlier
 * runs survive the app being closed. File writes and listener calls all run
 * on one IO thread, so a reader that snapshots the file and then subscribes
 * there sees every line exactly once.
 */
public final class LogStore {

    public interface Listener {
        /** Called on the IO thread. */
        void onLine(String line);
    }

    private static final long MAX_FILE = 4L << 20;   // rotate at 4 MB, keep the last 2 MB
    private static final ExecutorService io = Executors.newSingleThreadExecutor();
    private static final List<Listener> listeners = new CopyOnWriteArrayList<>();
    private static File file;
    private static Writer writer;

    public static synchronized void init(Context ctx) {
        if (file == null) file = new File(ctx.getApplicationContext().getFilesDir(), "launcher.log");
    }

    public static void append(final String line) {
        io.execute(() -> {
            write(line);
            for (Listener l : listeners) l.onLine(line);
        });
    }

    /** Read up to {@code maxChars} from the end of the file, then subscribe; {@code onTail} gets the snapshot. */
    public static void subscribe(final int maxChars, final Listener onTail, final Listener l) {
        io.execute(() -> {
            onTail.onLine(readTail(maxChars));
            listeners.add(l);
        });
    }

    public static void unsubscribe(Listener l) { listeners.remove(l); }

    public static void clear() {
        io.execute(() -> {
            closeWriter();
            if (file != null) //noinspection ResultOfMethodCallIgnored
                file.delete();
        });
    }

    private static void write(String line) {
        if (file == null) return;
        try {
            if (file.length() > MAX_FILE) rotate();
            if (writer == null) {
                writer = new BufferedWriter(new OutputStreamWriter(
                        new FileOutputStream(file, true), StandardCharsets.UTF_8));
            }
            writer.write(line);
            writer.write('\n');
            writer.flush();
        } catch (IOException e) {
            closeWriter();
        }
    }

    private static void rotate() throws IOException {
        closeWriter();
        String keep = readTail((int) (MAX_FILE / 2));
        try (Writer w = new OutputStreamWriter(new FileOutputStream(file, false), StandardCharsets.UTF_8)) {
            w.write(keep);
        }
    }

    private static String readTail(int maxChars) {
        if (file == null || !file.isFile()) return "";
        try (RandomAccessFile raf = new RandomAccessFile(file, "r")) {
            long len = raf.length();
            long start = Math.max(0, len - maxChars);
            byte[] b = new byte[(int) (len - start)];
            raf.seek(start);
            raf.readFully(b);
            String s = new String(b, StandardCharsets.UTF_8);
            if (start > 0) {
                // drop the partial first line
                int nl = s.indexOf('\n');
                if (nl >= 0) s = s.substring(nl + 1);
            }
            return s;
        } catch (IOException e) {
            return "";
        }
    }

    private static void closeWriter() {
        if (writer == null) return;
        try { writer.close(); } catch (IOException ignored) { }
        writer = null;
    }

    private LogStore() {}
}
