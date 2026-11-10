# SPDX-License-Identifier: GPL-3.0-or-later
#
# macos-versions.sh: sourced by fetch-macos.sh and boot-macos.sh.
# MACOS_VERSION picks the macOS release: tahoe (default), sequoia or sonoma.
#
# Board IDs, MLB and os type are the ones kholia/OSX-KVM's fetch-macOS-v2.py
# (commit 4c378a4, "Support for macOS Tahoe") and acidanthera's
# macrecovery/recovery_urls.txt use for each release. CPU models follow
# OSX-KVM's OpenCore-Boot.sh: Skylake-Client,-hle,-rtm for Sequoia and
# Tahoe, Haswell-noTSX for Sonoma.

MACOS_VERSION="${MACOS_VERSION:-tahoe}"
case "$MACOS_VERSION" in
  tahoe|26)
    MACOS_VERSION=tahoe
    MACOS_NAME="macOS 26 (Tahoe)"
    MACOS_BOARD="Mac-CFF7D910A743CAAF"
    MACOS_OS_TYPE="latest"
    MACOS_CPU_DEFAULT="Skylake-Client,-hle,-rtm"
    ;;
  sequoia|15)
    MACOS_VERSION=sequoia
    MACOS_NAME="macOS 15 (Sequoia)"
    MACOS_BOARD="Mac-7BA5B2D9E42DDD94"
    MACOS_OS_TYPE="default"
    MACOS_CPU_DEFAULT="Skylake-Client,-hle,-rtm"
    ;;
  sonoma|14)
    MACOS_VERSION=sonoma
    MACOS_NAME="macOS 14 (Sonoma)"
    MACOS_BOARD="Mac-827FAC58A8FDFA22"
    MACOS_OS_TYPE="default"
    MACOS_CPU_DEFAULT="Haswell-noTSX"
    ;;
  *)
    echo "ERROR: unknown MACOS_VERSION '$MACOS_VERSION' (use tahoe, sequoia or sonoma)" >&2
    exit 2
    ;;
esac
MACOS_MLB="00000000000000000"
# Each release keeps its own recovery image, so switching back and forth
# does not re-download.
MACOS_IMG="BaseSystem-${MACOS_VERSION}.img"
