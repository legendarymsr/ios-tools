# qemu-patches/ — QEMU-derived code

Patches against upstream QEMU (not forks) go here and keep the license of
the file they modify: usually **GPL-2.0-or-later**, or GPL-2.0-only where the
upstream file says so (`LICENSES/GPL-2.0-or-later.txt`).

The existing `QEMU/ios-t8030/inferno-*.patch` files modify ChefKissInc/Inferno,
whose touched files are **AGPL-3.0-or-later**; they are annotated as such in
`REUSE.toml`. If you ship modified QEMU/Inferno binaries, ship the
corresponding source too.
