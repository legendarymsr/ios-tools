# Hello World (iOS)

The smallest possible UIKit app: one screen with a label, plus one line from a helper
TrollStore lets us run as root (`uid=0`). One Objective-C file, no storyboard, built on
Linux without Xcode, fakesigned with `ldid` for [TrollStore](https://github.com/opa334/TrollStore).

```sh
sudo apt install clang lld curl zip xz-utils
./build.sh          # -> build/HelloWorld.tipa
```

Install the `.tipa` yourself with TrollStore (the qemu-t8030 module does **not** preinstall it).
For a root terminal with `dnf` / `fastfetch`, see [`apps/root-terminal`](../root-terminal).

Entitlements: `platform-application`, `no-sandbox`, `persona-mgmt` (no `get-task-allow`).
