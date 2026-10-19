# ios-tools

iOS tooling and ports.

A general home for iOS porting and jailbreak projects.

## Projects

### Checkm8OTG

A rooted Android app that runs `gaster`/checkm8 and `palera1n` against a
USB-connected iPhone directly from Android (no Termux needed). Put the iPhone
in DFU, connect it over OTG, grant root, then tap **Exploit** (pwned DFU) or
**Jailbreak** (palera1n, rootless or rootful).

- Engine: bundled aarch64 `gaster`, `palera1n` v2.2, and `checkra1n`.
- Support: gaster A5–A11 / T2; palera1n A8–A11 / T2, iOS 15–26. Not A12+.
- A prebuilt debug APK (`Checkm8OTG-debug.apk`) is included for direct testing.

See [`Checkm8OTG/README.md`](Checkm8OTG/README.md) for full docs and caveats.
