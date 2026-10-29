#!/usr/bin/env bash
# Build HelloWorld.tipa on Linux, no Xcode: clang + ld64.lld against an iOS SDK, ldid fakesign.
#   ./build.sh            -> build/HelloWorld.tipa (install it with TrollStore)
# Needs: clang, ld64.lld (Debian: apt install clang lld), curl, zip, xz.
# The iOS SDK (theos/sdks) and ldid (ProcursusTeam/ldid) are downloaded into ./.cache on first
# run; nothing Apple-made is kept in the repo. Override with SDK=/path/iPhoneOS*.sdk, LDID=/path/ldid.
set -euo pipefail
cd "$(dirname "$0")"
CACHE=${CACHE:-$PWD/.cache}; OUT=$PWD/build
SDK_URL=https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS16.5.sdk.tar.xz
LDID_URL=https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_linux_$(uname -m)
mkdir -p "$CACHE"
if [ -z "${SDK:-}" ]; then
  SDK=$CACHE/iPhoneOS16.5.sdk
  [ -d "$SDK" ] || curl -fL "$SDK_URL" | xz -dc | tar -x -C "$CACHE"
fi
if [ -z "${LDID:-}" ]; then
  LDID=$CACHE/ldid
  [ -x "$LDID" ] || { curl -fL -o "$LDID" "$LDID_URL"; chmod +x "$LDID"; }
fi
CLANG=$(command -v clang || ls /usr/lib/llvm-*/bin/clang 2>/dev/null | tail -1)
LLD=$(command -v ld64.lld || ls /usr/lib/llvm-*/bin/ld64.lld 2>/dev/null | tail -1)

rm -rf "$OUT"; APP=$OUT/Payload/HelloWorld.app; mkdir -p "$APP"
"$CLANG" -target arm64-apple-ios14.0 -isysroot "$SDK" -fobjc-arc -O2 \
  -fuse-ld="$LLD" -Wl,-platform_version,ios,14.0,16.5 \
  -framework UIKit -framework Foundation main.m -o "$APP/HelloWorld"
"$CLANG" -target arm64-apple-ios14.0 -isysroot "$SDK" -O2 -fuse-ld="$LLD" \
  -Wl,-platform_version,ios,14.0,16.5 roothelper.c -o "$APP/roothelper"
cp Info.plist "$APP/"
"$LDID" -Sentitlements.plist "$APP/roothelper"
"$CLANG" -target arm64-apple-ios14.0 -isysroot "$SDK" -O2 -fuse-ld="$LLD" \
  -Wl,-platform_version,ios,14.0,16.5 tools/fastfetch.c -o tools/fastfetch
"$CLANG" -target arm64-apple-ios14.0 -isysroot "$SDK" -O2 -fuse-ld="$LLD" \
  -Wl,-platform_version,ios,14.0,16.5 tools/rpm2cpio.c -o tools/rpm2cpio
cp -f tools/fastfetch tools/rpm2cpio "$APP/"
"$LDID" -Sentitlements.plist "$APP/fastfetch"
"$LDID" -Sentitlements.plist "$APP/rpm2cpio"
cp -f tools/dnf tools/rpm2cpio.py "$APP/"; chmod 755 "$APP/dnf" "$APP/rpm2cpio.py"
"$LDID" -Sentitlements.plist "$APP/HelloWorld"
( cd "$OUT" && zip -qr HelloWorld.tipa Payload )
echo "built $OUT/HelloWorld.tipa"
