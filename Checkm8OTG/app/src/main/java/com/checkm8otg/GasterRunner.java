// SPDX-License-Identifier: GPL-3.0-or-later
package com.checkm8otg;

import android.content.Context;

import java.io.File;

/**
 * Installs the bundled aarch64 gaster binary into the root-managed exec dir
 * (see {@link Installer}) and runs it as root with live output streaming (see
 * {@link NativeRunner}). gaster talks to the iPhone in DFU over usbfs
 * (/dev/bus/usb) via libusb; root is required for device-node access.
 */
public final class GasterRunner {
    private static final String ASSET_NAME = "gaster";
    private static final String BIN_NAME = "gaster";

    public interface Listener extends NativeRunner.Listener {}

    private GasterRunner() {}

    public static File ensureBinary(Context ctx) throws Exception {
        return ensureBinary(ctx, null);
    }

    /** Install gaster through root (hash-check/skip, no in-place overwrite). */
    public static File ensureBinary(Context ctx, Installer.Logger log) throws Exception {
        return Installer.install(ctx, ASSET_NAME, BIN_NAME, log);
    }

    public static NativeRunner.Handle run(Context ctx, String[] args, NativeRunner.Listener listener) {
        try {
            File bin = ensureBinary(ctx, listener::onLine);
            StringBuilder sb = new StringBuilder();
            sb.append("'").append(bin.getAbsolutePath()).append("'");
            if (args != null) {
                for (String a : args) sb.append(' ').append(a);
            }
            return NativeRunner.run(ctx, bin, null, sb.toString(), listener);
        } catch (Exception e) {
            listener.onLine("[exception] install gaster: " + e.getMessage());
            listener.onFinished(-1);
            return null;
        }
    }
}
