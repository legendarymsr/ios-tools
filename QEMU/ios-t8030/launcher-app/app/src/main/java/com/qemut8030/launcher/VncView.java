package com.qemut8030.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.text.InputType;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

/**
 * Draws the remote framebuffer fit-to-screen, with pinch zoom and two-finger pan.
 * Touch is forwarded as an absolute pointer with button 1 = finger: press on
 * finger down, streamed (throttled) moves while dragging, release on finger up.
 * HackiOS's virtio tablet driver turns that into iOS touches. Two fingers
 * pinch-zoom / pan locally. Mouse wheel / hardware keyboard are passed through.
 */
public class VncView extends View {

    private volatile RfbClient client;
    private final Object bmpLock = new Object();
    private Bitmap bmp;
    private final Paint paint = new Paint(Paint.FILTER_BITMAP_FLAG);
    private final Matrix matrix = new Matrix();

    private float zoom = 1f;          // user zoom on top of fit scale
    private float panX = 0f, panY = 0f;
    private float scale = 1f, tx = 0f, ty = 0f;  // effective transform

    private final ScaleGestureDetector scaleDetector;
    private boolean dragging = false;
    private boolean multiTouch = false;
    private float lastFocusX, lastFocusY;
    private int lastRemoteX, lastRemoteY;
    private String composing = "";

    public VncView(Context ctx) {
        super(ctx);
        setBackgroundColor(Color.BLACK);
        setFocusable(true);
        setFocusableInTouchMode(true);

        scaleDetector = new ScaleGestureDetector(ctx, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScale(ScaleGestureDetector d) {
                float old = zoom;
                zoom = Math.max(1f, Math.min(8f, zoom * d.getScaleFactor()));
                // keep the remote point under the fingers fixed while zooming
                float f = zoom / old;
                float cx = d.getFocusX(), cy = d.getFocusY();
                float wantTx = cx - (cx - tx) * f, wantTy = cy - (cy - ty) * f;
                updateTransform();
                panX += wantTx - tx; panY += wantTy - ty;
                updateTransform();
                invalidate();
                return true;
            }
        });

    }

    public void setClient(RfbClient c) { this.client = c; }

    /** Called from the RFB reader thread. */
    public void onRemoteResize(int w, int h) {
        synchronized (bmpLock) {
            bmp = Bitmap.createBitmap(Math.max(1, w), Math.max(1, h), Bitmap.Config.ARGB_8888);
        }
        post(() -> { resetZoom(); });
    }

    /** Called from the RFB reader thread after each FramebufferUpdate. */
    public void onRemoteUpdate(int x, int y, int w, int h) {
        RfbClient c = client;
        if (c == null) return;
        synchronized (bmpLock) {
            Bitmap b = bmp;
            if (b == null) return;
            synchronized (c.lock) {
                int W = c.width;
                if (b.getWidth() != W || b.getHeight() != c.height) return;
                if (x + w > b.getWidth() || y + h > b.getHeight() || w <= 0 || h <= 0) return;
                b.setPixels(c.fb, y * W + x, W, x, y, w, h);
            }
        }
        postInvalidateOnAnimation();
    }

    public void resetZoom() {
        zoom = 1f; panX = 0f; panY = 0f;
        updateTransform();
        invalidate();
    }

    private void updateTransform() {
        int bw, bh;
        synchronized (bmpLock) {
            if (bmp == null) return;
            bw = bmp.getWidth(); bh = bmp.getHeight();
        }
        int vw = getWidth(), vh = getHeight();
        if (vw == 0 || vh == 0) return;
        float fit = Math.min(vw / (float) bw, vh / (float) bh);
        scale = fit * zoom;
        float dw = bw * scale, dh = bh * scale;
        // centre when smaller than the view, otherwise clamp pan to the edges
        float baseX = (vw - dw) / 2f, baseY = (vh - dh) / 2f;
        if (dw <= vw) panX = 0; else panX = Math.max(-(dw - vw) / 2f, Math.min((dw - vw) / 2f, panX));
        if (dh <= vh) panY = 0; else panY = Math.max(-(dh - vh) / 2f, Math.min((dh - vh) / 2f, panY));
        tx = baseX + panX; ty = baseY + panY;
        matrix.setScale(scale, scale);
        matrix.postTranslate(tx, ty);
    }

    @Override protected void onSizeChanged(int w, int h, int ow, int oh) {
        super.onSizeChanged(w, h, ow, oh);
        updateTransform();
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        synchronized (bmpLock) {
            if (bmp != null) canvas.drawBitmap(bmp, matrix, paint);
        }
    }

    private int[] toRemote(float vx, float vy) {
        RfbClient c = client;
        int w = c != null ? c.width : 1, h = c != null ? c.height : 1;
        int x = (int) ((vx - tx) / scale), y = (int) ((vy - ty) / scale);
        return new int[] { Math.max(0, Math.min(w - 1, x)), Math.max(0, Math.min(h - 1, y)) };
    }

    private void click(int x, int y, int buttonMask) {
        RfbClient c = client;
        if (c == null) return;
        c.sendPointer(x, y, 0);
        c.sendPointer(x, y, buttonMask);
        c.sendPointer(x, y, 0);
    }

    /** Minimum spacing between streamed move events (ms); mt-spi samples every 50 ms. */
    private static final long MOVE_INTERVAL_MS = 8;
    private long lastMoveSent;
    private volatile boolean gestureRunning = false;

    @Override public boolean onTouchEvent(MotionEvent e) {
        int action = e.getActionMasked();
        if (gestureRunning) return true;  // a toolbar swipe owns the pointer
        if (action == MotionEvent.ACTION_DOWN) {
            multiTouch = false; requestFocus();
            int[] p = toRemote(e.getX(), e.getY());
            press(p[0], p[1]);
        }
        if (action == MotionEvent.ACTION_POINTER_DOWN) {
            // second finger: lift the remote touch where it is and switch to pinch / pan
            multiTouch = true;
            releaseDrag();
            lastFocusX = focusX(e); lastFocusY = focusY(e);
        }
        scaleDetector.onTouchEvent(e);
        if (multiTouch && e.getPointerCount() >= 2 && action == MotionEvent.ACTION_MOVE) {
            float fx = focusX(e), fy = focusY(e);
            panX += fx - lastFocusX; panY += fy - lastFocusY;
            lastFocusX = fx; lastFocusY = fy;
            updateTransform();
            invalidate();
        }
        if (action == MotionEvent.ACTION_POINTER_UP && e.getPointerCount() == 2) {
            lastFocusX = focusX(e); lastFocusY = focusY(e);
        }
        if (!multiTouch && dragging && action == MotionEvent.ACTION_MOVE) {
            // include batched historical samples so fast swipes keep intermediate points
            int n = e.getHistorySize();
            for (int i = 0; i < n; i++) moveTo(e.getHistoricalX(i), e.getHistoricalY(i), e.getHistoricalEventTime(i), false);
            moveTo(e.getX(), e.getY(), e.getEventTime(), false);
        }
        if (action == MotionEvent.ACTION_UP) {
            if (!multiTouch && dragging) moveTo(e.getX(), e.getY(), e.getEventTime(), true);
            releaseDrag();
        }
        if (action == MotionEvent.ACTION_CANCEL) releaseDrag();
        return true;
    }

    private void press(int x, int y) {
        RfbClient c = client;
        if (c == null) return;
        c.sendPointer(x, y, 0);   // position first, then finger down at that spot
        c.sendPointer(x, y, 1);
        lastRemoteX = x; lastRemoteY = y;
        lastMoveSent = 0;
        dragging = true;
    }

    private void moveTo(float vx, float vy, long t, boolean force) {
        RfbClient c = client;
        if (c == null) return;
        int[] p = toRemote(vx, vy);
        if (p[0] == lastRemoteX && p[1] == lastRemoteY) return;
        if (!force && t - lastMoveSent < MOVE_INTERVAL_MS) return;
        lastMoveSent = t;
        lastRemoteX = p[0]; lastRemoteY = p[1];
        c.sendPointer(p[0], p[1], 1);
    }

    private void releaseDrag() {
        if (!dragging) return;
        dragging = false;
        RfbClient c = client;
        if (c != null) c.sendPointer(lastRemoteX, lastRemoteY, 0);
    }

    /**
     * Synthesised one-finger drag in framebuffer fractions (0..1), e.g. a swipe
     * up from the bottom edge. Runs off the UI thread; ~16 ms steps.
     */
    public void swipe(float fx0, float fy0, float fx1, float fy1, int durationMs) {
        final RfbClient c = client;
        if (c == null || gestureRunning || c.width <= 1) return;
        releaseDrag();
        gestureRunning = true;
        final int w = c.width, h = c.height;
        new Thread(() -> {
            try {
                int x0 = clampI(Math.round(fx0 * w), w), y0 = clampI(Math.round(fy0 * h), h);
                int x1 = clampI(Math.round(fx1 * w), w), y1 = clampI(Math.round(fy1 * h), h);
                c.sendPointer(x0, y0, 0);
                c.sendPointer(x0, y0, 1);
                Thread.sleep(60);  // let the touch begin before moving
                int steps = Math.max(2, durationMs / 16);
                for (int i = 1; i <= steps; i++) {
                    float t = i / (float) steps;
                    float k = t * t * (3 - 2 * t);  // ease in/out
                    c.sendPointer(Math.round(x0 + (x1 - x0) * k), Math.round(y0 + (y1 - y0) * k), 1);
                    Thread.sleep(durationMs / steps);
                }
                Thread.sleep(60);
                c.sendPointer(x1, y1, 0);
            } catch (InterruptedException ignored) {
            } finally {
                gestureRunning = false;
            }
        }, "vnc-swipe").start();
    }

    private static int clampI(int v, int n) { return Math.max(0, Math.min(n - 1, v)); }

    private static float focusX(MotionEvent e) {
        float s = 0; int n = e.getPointerCount();
        for (int i = 0; i < n; i++) s += e.getX(i);
        return s / n;
    }

    private static float focusY(MotionEvent e) {
        float s = 0; int n = e.getPointerCount();
        for (int i = 0; i < n; i++) s += e.getY(i);
        return s / n;
    }

    /** Hardware mouse: hover moves the pointer, wheel scrolls. */
    @Override public boolean onGenericMotionEvent(MotionEvent e) {
        RfbClient c = client;
        if (c != null && (e.getSource() & InputDevice.SOURCE_CLASS_POINTER) != 0) {
            int[] p = toRemote(e.getX(), e.getY());
            if (e.getActionMasked() == MotionEvent.ACTION_HOVER_MOVE) {
                c.sendPointer(p[0], p[1], 0);
                return true;
            }
            if (e.getActionMasked() == MotionEvent.ACTION_SCROLL) {
                float v = e.getAxisValue(MotionEvent.AXIS_VSCROLL);
                int btn = v > 0 ? 8 : 16;
                if (v != 0) { c.sendPointer(p[0], p[1], btn); c.sendPointer(p[0], p[1], 0); }
                return true;
            }
        }
        return super.onGenericMotionEvent(e);
    }

    // ---------------------------------------------------------------- keyboard

    @Override public boolean onCheckIsTextEditor() { return true; }

    @Override public InputConnection onCreateInputConnection(EditorInfo out) {
        out.inputType = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
        out.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN
                | EditorInfo.IME_ACTION_NONE;
        composing = "";
        return new BaseInputConnection(this, false) {
            @Override public boolean commitText(CharSequence text, int pos) {
                String t = text == null ? "" : text.toString();
                if (!composing.isEmpty()) { applyComposing(t); composing = ""; }
                else sendText(t);
                return true;
            }
            @Override public boolean setComposingText(CharSequence text, int pos) {
                applyComposing(text == null ? "" : text.toString());
                return true;
            }
            @Override public boolean finishComposingText() { composing = ""; return true; }
            @Override public boolean deleteSurroundingText(int before, int after) {
                for (int i = 0; i < before; i++) tap(Keysyms.BACKSPACE);
                for (int i = 0; i < after; i++) tap(Keysyms.DELETE);
                return true;
            }
            @Override public boolean sendKeyEvent(KeyEvent ev) {
                return ev.getAction() == KeyEvent.ACTION_DOWN
                        ? onKeyDown(ev.getKeyCode(), ev) : onKeyUp(ev.getKeyCode(), ev);
            }
        };
    }

    /** Turns an IME composing-text change into backspaces + new characters. */
    private void applyComposing(String t) {
        int p = 0, n = Math.min(composing.length(), t.length());
        while (p < n && composing.charAt(p) == t.charAt(p)) p++;
        for (int i = composing.length(); i > p; i--) tap(Keysyms.BACKSPACE);
        sendText(t.substring(p));
        composing = t;
    }

    private void sendText(String t) {
        for (int i = 0; i < t.length(); ) {
            int cp = t.codePointAt(i);
            i += Character.charCount(cp);
            tap(Keysyms.forCodePoint(cp));
        }
    }

    public void tap(int keysym) {
        RfbClient c = client;
        if (c != null && keysym != 0) c.tapKey(keysym);
    }

    @Override public boolean onKeyDown(int keyCode, KeyEvent ev) {
        if (keyCode == KeyEvent.KEYCODE_BACK) return super.onKeyDown(keyCode, ev);
        int ks = Keysyms.forKeyEvent(keyCode, ev);
        RfbClient c = client;
        if (ks == 0 || c == null) return super.onKeyDown(keyCode, ev);
        c.sendKey(ks, true);
        return true;
    }

    @Override public boolean onKeyUp(int keyCode, KeyEvent ev) {
        if (keyCode == KeyEvent.KEYCODE_BACK) return super.onKeyUp(keyCode, ev);
        int ks = Keysyms.forKeyEvent(keyCode, ev);
        RfbClient c = client;
        if (ks == 0 || c == null) return super.onKeyUp(keyCode, ev);
        c.sendKey(ks, false);
        return true;
    }
}
