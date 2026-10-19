# OSX-KVM assets

The actual OVMF firmware, OpenCore.qcow2, `fetch-macOS-v2.py`, and CREDITS from
[kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) are **bundled inside**
`../macos-kvm-launcher-v1.0.0.zip` under `payload/assets/`.

They are staged on-device to `/data/local/osx-kvm/assets` by the module's
`customize.sh`. They are not duplicated here to keep the git tree lean.

To refresh them from upstream:

```sh
git clone --depth 1 https://github.com/kholia/OSX-KVM.git
# then re-run the module packaging step
```

No Apple macOS images (BaseSystem.dmg / .img / IPSW) are ever committed.
