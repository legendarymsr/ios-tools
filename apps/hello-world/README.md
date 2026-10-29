# Hello World (iOS)

The smallest possible UIKit app: one screen that says "Hello, world". One Objective-C file, no storyboard,
built on Linux without Xcode, fakesigned with `ldid` for [TrollStore](https://github.com/opa334/TrollStore).

```sh
sudo apt install clang lld curl zip xz-utils
./build.sh          # -> build/HelloWorld.tipa
```

`build.sh` downloads an iOS 16.5 SDK (theos/sdks) and `ldid` (ProcursusTeam) into `.cache/` on first run
(or set `SDK=` / `LDID=`). Targets arm64, iOS 14.0+. Bundle id `com.legendarymsr.helloworld`.
The iOS VM (`QEMU/ios-t8030`) installs the released `HelloWorld.tipa` through TrollStore at boot.
