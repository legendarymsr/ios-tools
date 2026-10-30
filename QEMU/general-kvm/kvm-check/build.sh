#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compile kvmcheck for Android aarch64 with the NDK.
# Usage: NDK=/path/to/android-ndk ./build.sh
set -euo pipefail
NDK="${NDK:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
if [ -z "$NDK" ]; then
  echo "Set NDK=/path/to/android-ndk (r25+) and re-run." >&2
  exit 1
fi
HOST_TAG="$(uname | tr '[:upper:]' '[:lower:]')-x86_64"
CC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/aarch64-linux-android24-clang"
STRIP="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/llvm-strip"
"$CC" -O2 -static -o kvmcheck-arm64 kvmcheck.c
"$STRIP" kvmcheck-arm64 || true
echo "Built: kvmcheck-arm64"
file kvmcheck-arm64 2>/dev/null || true
