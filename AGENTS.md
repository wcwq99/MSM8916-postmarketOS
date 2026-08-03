# Repository Agent Guide

## Mission and acceptance boundary

This repository builds one postmarketOS split boot/root image for 19 MSM8916
boards. Every supported DTB must exist in `/dtbs/qcom` inside the ext2 boot
image, while `/extlinux/extlinux.conf` selects one DTB with a single `fdt`
line. CI success means compilation and structural validation; do not claim
hardware boot or peripheral support without evidence from a physical board.

## Repository ownership

- Root-owned files are the workflows, `config/`, `patches/`, `scripts/`, and
  documentation. Implement changes there.
- `pmos-example` and `debian-dtbs` are pinned provenance/reference submodules.
  Do not edit files inside either submodule. Update a gitlink only as an
  intentional, separately reviewed dependency change.
- `config/boards.conf` is the canonical 19-board public mapping. Its fields are
  `board-id|dtb-file|source|compatible|display-name`.
- `config/openstick-dtbs.list` is the kernel Makefile list for the 14
  source-ported boards. A board with source type `dts` must appear in both
  files; `native` and `dtb` entries must not appear in this list.

## Fixed upstream contract

- pmbootstrap: `b2bf3539cd92acce4ab187167581168e845f3e7e`
- pmaports: `1ce58c5ae1b7573c6471959c4ab406391eefb103`
- kernel tag: `v6.12.1-msm8916`
- pmOS reference: `fe4289d03aaf95fd2325e81b12ff02b55b70e868`
- Debian DT reference: `ef731fa31eefdf5730f87e31d9aecafe61159ed2`

Changing a pin requires reapplying the pmaports overlay, compiling all 19
DTBs, rebuilding the full image, and updating README provenance. Never make a
workflow clone a moving upstream branch.

## Build environment constraints

These are load-bearing; all three were paid for with failed builds.

- **QEMU must be >= 8.** The aarch64 rootfs is assembled under qemu-user
  emulation, and the 6.2 series shipped by Ubuntu 22.04 crashes the aarch64 Go
  binary of `postmarketos-mkinitfs` with a runtime dump. Keep the workflow on
  `ubuntu-24.04`; `scripts/build-local.sh` checks the interpreter that
  binfmt_misc actually registered.
- **Never call `pmbootstrap log` in an unattended build.** It runs `tail -F`
  and never returns. Dump `tail -n 500 "$PMB_WORK/log.txt"` instead, and keep
  the failure-artifact upload on `!success()` so a timed-out job still yields
  the log.
- **Retry the kernel source fetch.** `abuild checksum` pulls the pinned tarball
  through busybox wget inside the chroot with no retry; a transient DNS failure
  on `codeload.github.com` is enough to fail the run.

Do not hardcode values that can be read from an authoritative source:
`$PMB_WORK/version` comes from `pmb.config.work_version`, and upstream
subpackages such as `device-zhihe-generic-nonfree-firmware` must not appear in
`extra_packages` because `get_nonfree_packages()` discovers them from the
APKBUILD.

## Pinned source vs rolling binaries

Only the kernel is built locally; every other package comes from the rolling
edge mirror. The pmaports pin therefore describes *metadata* that the mirror has
already moved past, and pmbootstrap logs `about to install X (local pmaports:
Y)` for each drift. That is tolerable for version skew but fatal when a package
name disappears, because pmbootstrap reads the pinned APKBUILD to decide what to
request. `patches/pmaports-device-zhihe-nonfree.patch` reconciles exactly one
such case (upstream `e5536561` deleted the `-nonfree-firmware` subpackage).

Expect this class of break to recur. When it does, resolve the package closure
offline against the live APKINDEXes before touching anything — it takes seconds
and proves both the culprit and the absence of a second one. The procedure is in
`pmos-example/SKILLS.md` §3.

## Build entry points

- `.github/workflows/build.yml` is the only CI build path, GitHub-hosted.
- `scripts/build-local.sh` mirrors it step for step on a local x86_64 host.
  Keep the two in sync: a change to the package set, config, or verification
  in one belongs in the other.

## Device-tree porting rules

- Reuse the kernel-native `msm8916-ufi.dtsi`; do not stage the older copy from
  `debian-dtbs`.
- Reuse the kernel-native UFI001C, UF896, and UZ801 V3 DTS files.
- Stage the 14 board DTS files plus `msm8916-mifi.dtsi` and
  `msm8916-sp970.dtsi` from `debian-dtbs` with
  `scripts/stage-device-trees.sh`.
- Keep version-specific changes in `patches/device-trees-6.12.patch`. The
  current patch removes unavailable SP970 UART pinctrl labels, uses the modern
  `id-gpios` spelling, and adapts MF32 LED/USB references to the native 6.12.1
  UFI include.
- MF800 and JZ01-45-V33 are binary-only inputs. Validate their DTB syntax and
  root compatible strings, but do not describe them as source-rebuilt.

## Required checks

Before committing changes, run at minimum:

```sh
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck scripts/*.sh
git diff --check
```

For any device-tree, manifest, pmaports, or kernel change, also run:

```sh
bash scripts/validate-dtbs.sh /path/to/linux-v6.12.1-msm8916 /tmp/validated-dtbs
```

The command must produce exactly 19 DTBs and verify each first root compatible
against `config/boards.conf`. A full release is acceptable only after the build
workflow also verifies the boot image, `SHA256SUMS`, Actions Artifact, and
GitHub Release asset.

## Image and release invariants

- Keep one `zhihe-generic-boot.img` and one `zhihe-generic-root.img`; do not
  duplicate the rootfs per board.
- Default extlinux to
  `/dtbs/qcom/msm8916-thwc-ufi003.dtb`, an upstream-supported baseline.
- Preserve `boards.conf` and `README-BOARD-SELECTION.txt` in the boot image.
- The tarball must include 19 exported DTBs, source revision metadata, and
  checksums for every file.
- Releases remain prereleases until physical-device boot results justify a
  stable release. Never publish passwords, tokens, firmware backups, IMEI/NV
  data, or user-provided proprietary partitions.
- `scripts/flash-fastboot.bat` is an owner-authorized exception to the
  earlier "Do not automate flashing" rule. It is a one-click fastboot flasher
  for the multi-board release tarball, but it MUST keep:
  - EDL backup warning before any write
  - `tz`/`hyp` mismatch warning before bootloader flash
  - interactive `YES` confirmation before flashing hyp/tz/aboot
  - SHA256SUMS verification of all artifacts before flashing
  Any change that removes these guards violates the exception and must be
  reverted.
