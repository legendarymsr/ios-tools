# Hello World (iOS terminal)

A small UIKit terminal for [TrollStore](https://github.com/opa334/TrollStore): one text view, one input
line, commands run as **root** via TrollStore's persona spawn (persona 99, uid/gid 0).

```sh
sudo apt install clang lld curl zip xz-utils
./build.sh          # -> build/HelloWorld.tipa
```

Install the `.tipa` yourself with TrollStore (the qemu-t8030 module does **not** preinstall it).

## Bundled tools

On first launch the app copies these into `/var/jb/usr/local/bin`:

| Tool | What it is |
|------|------------|
| `fastfetch` | Native arm64 iOS binary (sysctl/uname). **Not** upstream fastfetch-cli (that needs macOS frameworks). Preinstalled / on `PATH`. |
| `dnf` | Shell frontend against **Fedora 40 aarch64** repos (metalink/dl.fedoraproject.org). Speaks `install` / `remove` / `search` / `list installed` / `--version`. Downloads RPMs and extracts payloads into `/var/jb/dnfroot` with bundled `rpm2cpio` + host `cpio`. **Not** Fedora's libdnf (Linux ELF); Darwin/iOS cannot load that. Named `dnf` because the user asked for dnf, not apt. |
| `rpm2cpio` | Minimal native helper used by `dnf`. |

A full Fedora 40 aarch64 rootfs with real `/usr/bin/dnf` + upstream `fastfetch` was built on the
host under qemu-user for reference (`dnf --installroot`, ~356M); shipping and running those Linux
ELFs on Darwin/iOS would need a user-mode Linux emulator, which this release does not include.

Entitlements: `platform-application`, `no-sandbox`, `persona-mgmt` (no `get-task-allow`).
