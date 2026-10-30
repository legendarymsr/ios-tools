// SPDX-License-Identifier: GPL-3.0-or-later
package com.macoskvm.launcher;

import android.view.KeyEvent;

/** Maps Android key events and Unicode code points to X11 keysyms for RFB. */
public final class Keysyms {
    public static final int BACKSPACE = 0xFF08;
    public static final int TAB = 0xFF09;
    public static final int RETURN = 0xFF0D;
    public static final int ESCAPE = 0xFF1B;
    public static final int DELETE = 0xFFFF;
    public static final int HOME = 0xFF50;
    public static final int LEFT = 0xFF51, UP = 0xFF52, RIGHT = 0xFF53, DOWN = 0xFF54;
    public static final int PAGE_UP = 0xFF55, PAGE_DOWN = 0xFF56, END = 0xFF57;
    public static final int SHIFT = 0xFFE1, CONTROL = 0xFFE3, ALT = 0xFFE9, SUPER = 0xFFEB;

    private Keysyms() {}

    /** X11 keysym for a Unicode code point (Latin-1 is identity; others use the 0x01000000 plane). */
    public static int forCodePoint(int cp) {
        if (cp == '\n' || cp == '\r') return RETURN;
        if (cp == '\t') return TAB;
        if (cp >= 0x20 && cp <= 0xFF) return cp;      // Latin-1 == keysym
        if (cp >= 0x100) return 0x01000000 + cp;      // Unicode plane
        return 0;
    }

    /** X11 keysym for a hardware/soft key event; prefers the produced Unicode char. */
    public static int forKeyEvent(int keyCode, KeyEvent ev) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_DEL: return BACKSPACE;
            case KeyEvent.KEYCODE_FORWARD_DEL: return DELETE;
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER: return RETURN;
            case KeyEvent.KEYCODE_TAB: return TAB;
            case KeyEvent.KEYCODE_ESCAPE: return ESCAPE;
            case KeyEvent.KEYCODE_DPAD_LEFT: return LEFT;
            case KeyEvent.KEYCODE_DPAD_RIGHT: return RIGHT;
            case KeyEvent.KEYCODE_DPAD_UP: return UP;
            case KeyEvent.KEYCODE_DPAD_DOWN: return DOWN;
            case KeyEvent.KEYCODE_MOVE_HOME: return HOME;
            case KeyEvent.KEYCODE_MOVE_END: return END;
            case KeyEvent.KEYCODE_PAGE_UP: return PAGE_UP;
            case KeyEvent.KEYCODE_PAGE_DOWN: return PAGE_DOWN;
            case KeyEvent.KEYCODE_SPACE: return ' ';
            case KeyEvent.KEYCODE_SHIFT_LEFT:
            case KeyEvent.KEYCODE_SHIFT_RIGHT: return SHIFT;
            case KeyEvent.KEYCODE_CTRL_LEFT:
            case KeyEvent.KEYCODE_CTRL_RIGHT: return CONTROL;
            case KeyEvent.KEYCODE_ALT_LEFT:
            case KeyEvent.KEYCODE_ALT_RIGHT: return ALT;
            default:
                int u = ev != null ? ev.getUnicodeChar() : 0;
                if (u != 0) return forCodePoint(u);
                return 0;
        }
    }
}
