# Root Terminal (iOS)

UIKit terminal for [TrollStore](https://github.com/opa334/TrollStore): text view + input, commands
run as **root** via persona spawn (persona 99, uid/gid 0).

On first launch, copies into `/var/jb/usr/local/bin`:

- **fastfetch** — native iOS arm64 (sysctl); not upstream fastfetch-cli
- **dnf** — Fedora 40 aarch64 repo frontend (not apt, not Fedora libdnf)
- **rpm2cpio** / **rpm2cpio.py** — RPM extractors for `dnf`

```sh
sudo apt install clang lld curl zip xz-utils
./build.sh          # -> build/RootTerminal.tipa
```

Install with TrollStore yourself. Dead-simple label app: [`apps/hello-world`](../hello-world).
