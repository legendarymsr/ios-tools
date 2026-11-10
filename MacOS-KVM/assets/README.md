# OSX-KVM assets

The actual OVMF firmware, OpenCore.qcow2, `fetch-macOS-v2.py`, and CREDITS from
[kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) are **bundled inside**
the module zip (`macos-kvm-launcher-vX.Y.Z.zip`) under `payload/assets/`.

They are staged on-device to `/data/local/osx-kvm/assets` by the module's
`customize.sh`. They are not duplicated here to keep the git tree lean.

To refresh them from upstream:

```sh
git clone https://github.com/kholia/OSX-KVM.git
git -C OSX-KVM checkout 4c378a4b5e0b219783683012bec680325eb40719
OSXKVM=$PWD/OSX-KVM ../pack-release.sh
```

`pack-release.sh` pins that commit ("Support for macOS Tahoe").

No Apple macOS images (BaseSystem.dmg / .img / IPSW) are ever committed.
