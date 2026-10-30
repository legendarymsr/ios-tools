# kernel-patches/ — APSL-2.0 only

Nothing is vendored here yet. HakiOS's XNU kernel patch is fetched from
`oosexgang/hakios-xnu-kernel` at a pinned commit at build time.

Any XNU- or HakiOS-kernel-derived patch or file added to this repo later
**must go in this folder, under APSL-2.0** (`LICENSES/APSL-2.0.txt`), with
Apple's notices kept intact. APSL-2.0 is not GPL-compatible, so nothing in
this folder may be combined with GPL code in the same file, and GPL code
must not be copied in here.
