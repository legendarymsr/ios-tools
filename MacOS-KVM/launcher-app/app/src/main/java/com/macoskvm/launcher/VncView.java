// SPDX-License-Identifier: GPL-3.0-or-later
package com.macoskvm.launcher;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.text.InputType;
import android.view.GestureDetector;
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
 * Touch: tap = left click, one-finger drag = move with left button held,
 * long press = right click. Mouse wheel / hardware keyboard are passed through.
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
    private final GestureDetector gestures;
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

        gestures = new GestureDetector(ctx, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent e) { return true; }

            @Override public boolean onSingleTapUp(MotionEvent e) {
                if (multiTouch) return false;
                int[] p = toRemote(e.getX(), e.getY());
                click(p[0], p[1], 1);
                return true;
            }

            @Override public void onLongPress(MotionEvent e) {
                if (multiTouch || dragging) return;
                int[] p = toRemote(e.getX(), e.getY());
                click(p[0], p[1], 4);
                performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS);
            }

            @Override public boolean onScroll(MotionEvent e1, MotionEvent e2, float dx, float dy) {
                if (multiTouch || e2.getPointerCount() > 1) return false;
                RfbClient c = client;
                if (c == null) return true;
                if (!dragging && e1 != null) {
                    int[] s = toRemote(e1.getX(), e1.getY());
                    c.sendPointer(s[0], s[1], 0);
                    c.sendPointer(s[0], s[1], 1);
                    dragging = true;
                }
                int[] p = toRemote(e2.getX(), e2.getY());
                lastRemoteX = p[0]; lastRemoteY = p[1];
                c.sendPointer(p[0], p[1], 1);
                return true;
            }
        });
        gestures.setIsLongpressEnabled(true);
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

    @Override public boolean onTouchEvent(MotionEvent e) {
        int action = e.getActionMasked();
        if (action == MotionEvent.ACTION_DOWN) { multiTouch = false; requestFocus(); }
        if (action == MotionEvent.ACTION_POINTER_DOWN) {
            multiTouch = true;
            releaseDrag();
            // cancel any pending long-press so a pinch never right-clicks
            MotionEvent cancel = MotionEvent.obtain(e);
            cancel.setAction(MotionEvent.ACTION_CANCEL);
            gestures.onTouchEvent(cancel);
            cancel.recycle();
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
            // remaining finger: refresh focus so a later second finger doesn't jump
            lastFocusX = focusX(e); lastFocusY = focusY(e);
        }
        if (!multiTouch) gestures.onTouchEvent(e);
        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            releaseDrag();
        }
        return true;
    }

    private void releaseDrag() {
        if (!dragging) return;
        dragging = false;
        RfbClient c = client;
        if (c != null) c.sendPointer(lastRemoteX, lastRemoteY, 0);
    }

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
