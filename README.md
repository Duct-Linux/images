# Duct images

The bootstrap chain that turns a pinned Debian into a self-hosting Duct system,
and the two images that ship: `duct/base` and `duct/builder`.

```
duct/bootstrap   Debian, digest-pinned. Has Go (for tape) and a C toolchain.
      |          make build
      v
duct/toolchain   A cross toolchain targeting *-duct-linux-gnu, Duct's own glibc,
      |          and the temporary tools. LFS chapters 5 and 6.
      |          make toolchain
      v
duct/chroot      FROM scratch. Its own gcc, bash and libc; the cross toolchain
      |          is deleted, which is what proves it stands alone.
      |          make chroot && make chroot-test
      v
duct/base        Assembled by tape from the signed repository built in
duct/builder     ../packages.  make base builder && make images-test
      |
      v
duct-live.iso    The same package set plus a kernel and a bootloader, as a
                 bootable UEFI ISO.  make iso && make iso-test
```

`duct/rust` (`make rust`) exists only to build uutils-coreutils, the one package
written in a language Duct does not package.

## Two halves, very different costs

**Bootstrap** (`.github/workflows/bootstrap.yml`, manual) builds a toolchain from
nothing -- LFS chapters 5 to 7, about an hour per architecture, natively on its
own runner. It exists to bring up an architecture, and publishes `duct/bootstrap`
and `duct/chroot`.

**Assemble** (`.github/workflows/assemble.yml`) builds `duct/base` and
`duct/builder` by installing from the published repository at
repo.duct.dss-net.de. That takes about a minute, because it is downloading and
unpacking rather than compiling.

Assembling from the repository rather than a local build tree is deliberate: the
build fetches the same index, verifies the same signature against the same
public key and checks the same digests a user's machine would, so a broken
publish fails in CI rather than on someone's first `tape install`. The resulting
images carry the repo definition and the key, so they can update themselves from
the repository they came from.

This repo expects `tape`, `packages` and `images` checked out as siblings: the
Docker build context is their common parent, because the bootstrap image
compiles tape from source and the toolchain reads `packages/pkgs/versions.env`.

## The live ISO

```sh
make -C ../packages repo    # the packages, including linux, grub and duct-live
make iso                    # out/duct-live-<arch>.iso
make iso-test               # what can be checked without booting
make iso-run OVMF=/path/to/edk2-firmware.fd
```

`duct-live.iso` is `duct/builder`'s package set with the four things a
container image never needs — a kernel, a bootloader, an initramfs and a
PID 1 — and it boots on real hardware, from a disc or from a USB stick written
with `dd`.

Unlike `make base`, this installs from the repository in `../packages/out/repo`
rather than from `repo.duct.dss-net.de`. An ISO is normally built from packages
that have just been built and not yet published, and it should not need a
network at all. Building from the published set instead means moving both the
repository and the key that signed it:

```sh
make iso ISO_REPO_URL=https://repo.duct.dss-net.de ISO_KEY_DIR=$PWD/../packages/server
```

The key has to follow the repository. A local repo is signed with the key
`make -C ../packages key` generated; the published one is not, and mixing them
fails signature verification rather than producing a bad ISO.

### How it boots

```
firmware  ->  GRUB          from the ISO's EFI system partition; finds the
                            medium by searching every device for
                            /duct/.duct-live
    |
    v
GRUB      ->  kernel        /boot/vmlinuz, with /boot/initramfs.img
    |
    v
/init     ->  overlay       mounts the medium, mounts /duct/rootfs.squashfs
                            out of it through a loop device, stacks a tmpfs
                            over it with overlayfs, and switch_roots into it
    |
    v
busybox init                reads /etc/inittab, runs the sysinit script, and
                            keeps a shell on the console and on tty2 and tty3
```

The writable layer is a tmpfs. Everything written to a live system is gone at
the next boot, and that is the only reason it can afford to have no
installer, no partitioning step and no state.

### What ships and what only packs

This is the line the ISO build draws, and it is worth being explicit about
because it is the same question the whole bootstrap chain exists to answer.

| | built by | ships in the ISO |
|---|---|---|
| kernel, modules | Duct (`linux`) | yes |
| bootloader | Duct (`grub`) | yes |
| initramfs | Duct (`busybox`, `duct-live`) | yes |
| root filesystem | Duct (every package) | yes |
| `mksquashfs`, `xorriso`, `mtools`, `mkfs.vfat` | Debian | **no** |

Everything the firmware executes and everything the machine runs is Duct's.
The four tools that wrap it in a container are the build host's, exactly as
`docker buildx` is for every other image here — they read Duct's files and
write a container around them, and not a byte of their own code ends up on the
medium. Packaging them would mean recipes for libburn, libisofs, libisoburn,
mtools and dosfstools: five packages that would never run on a Duct machine.

The initramfs and the EFI binary are on the other side of that line and are
built inside a chroot of the rootfs itself, by Duct's own `busybox`, `gzip` and
`grub-mkimage`. A distribution that compiles its own libc and then boots
through somebody else's bootloader has not finished the job.

### Reproducible

Two builds of the same packages produce a byte-identical ISO. That took three
fixes, each of which had gone unnoticed because the difference was small and
intermittent:

- `mksquashfs` and `xorriso` both read `SOURCE_DATE_EPOCH` themselves. Passing
  `-mkfs-time` as well is not redundant but fatal — mksquashfs refuses to be
  told the same thing twice.
- ISO9660 records an mtime per directory entry, taken from the filesystem, so
  the squashfs written moments earlier carried the build time into the image.
  Every file in the ISO tree is flattened to `SOURCE_DATE_EPOCH` first.
- `mtools` honours `SOURCE_DATE_EPOCH` for a file's *modification* time and
  then writes the creation time and last-access date in every FAT directory
  entry from the real clock. That one is upstream's, and the ESP is built under
  `faketime` because the alternative — patching timestamp fields inside a FAT
  image by searching for directory entries — risks corrupting the bootloader to
  fix a cosmetic problem.

### UEFI only

There is no BIOS boot path, and there cannot be one until Duct has a 32-bit
compiler. GRUB's BIOS target is `i386-pc` — 32-bit objects — and Duct's gcc is
configured `--disable-multilib`. Building it would need either a multilib gcc
or a second cross toolchain.

What that costs: the ISO does not boot on a pre-2012 PC, and it does not boot
in a QEMU invocation without firmware. `make iso-run` requires `OVMF=`, and a
plain `qemu-system-x86_64 -cdrom` shows a blank screen — which is the expected
result, not a fault.

### Adding a desktop, or anything else

The package manifest is one variable:

```sh
make iso ISO_EXTRA_PACKAGES="wayland mesa gnome-shell"
```

`ISO_PACKAGES` is `ISO_BASE_PACKAGES` (the builder set) plus
`ISO_BOOT_PACKAGES` (kernel, bootloader, live wiring) plus
`ISO_EXTRA_PACKAGES`. Nothing else in the ISO build knows what is in the
manifest — the kernel already carries DRM/KMS drivers for Intel, AMD and
NVIDIA, `simpledrm` for everything else, and evdev, so a graphical session
needs no kernel change.

### The pieces

```
Dockerfile.iso        three stages: assemble, author, export
iso/post-install.sh   everything tape has no install hook for
iso/make-boot.sh      runs inside the rootfs: initramfs + EFI binary
iso/build-iso.sh      runs on the build host: squashfs + ESP + ISO
iso/early-grub.cfg    compiled into the EFI binary; finds the medium
iso/grub.cfg.in       the boot menu
iso/boot-test.sh      boots the result under QEMU, in a container
```

`post-install.sh` is where a larger package set gets extended. tape has no
install hooks at all: a package can put files in place and nothing else, so it
cannot run `ldconfig` and it cannot regenerate a cache that is keyed on which
*other* packages are installed. All of that happens once, there, between the
install and the squash. Every step is guarded on the program existing, so the
file is mostly a no-op for today's manifest and becomes live as packages that
need it arrive.

It also re-applies the sticky bit on `/tmp` and the setuid bits on `passwd` and
friends. Those are redundant — tape does carry setuid, setgid and sticky
through installation, which is worth stating because the documentation claimed
otherwise for a while — but they are idempotent and guarded, and the failure
they would catch is a world-writable `/tmp`.

It is also where `/etc/machine-id` is deliberately emptied. Baking one in would
give every machine that boots the ISO the same identity; `duct-live`'s boot
script generates a fresh one each time.

The kernel command line the initramfs understands:

| parameter | default | |
|---|---|---|
| `duct.live.label=` | `DUCT_LIVE` | filesystem label to boot from |
| `duct.live.device=` | — | skip the search, use this device |
| `duct.live.image=` | `/duct/rootfs.squashfs` | squashfs path on the medium |
| `duct.live.timeout=` | `30` | seconds to wait for the medium |
| `duct.live.debug` | off | `set -x` in the initramfs |

## The bootstrap image

The Debian host that bootstraps Duct. It builds the cross toolchain, and from
there the distribution builds itself — see `../distro`. The point is that what
it produces depends on nothing about the machine that ran the build: not the
distro, not the compiler version, not the day it happened.

It is deliberately *not* called the builder image. `duct/builder` is the
Duct-native image assembled from Duct packages; this one is the scaffolding that
makes that image possible.

```sh
make build                 # native platform, loaded into your daemon
make test                  # build one package twice, compare digests
make build-multi           # linux/amd64 + linux/arm64 -> OCI archive
```

## What is in it

The `tape` toolchain (`tape`, `taped`, `tape-builder`, `tape-repo`), compiled
from `../tape`, plus an autotools C/C++ toolchain: `gcc`, `g++`, `binutils`,
`make`, `libc6-dev`, `linux-libc-dev`, `autoconf`, `automake`, `libtool`,
`pkg-config`, `m4`, `bison`, `flex`, `gawk`, `patch`, `perl`, `python3`,
`texinfo`, `gettext`, the usual archive formats, and `wget`/`git`/`rsync`.

The package list is written out explicitly rather than pulled in via
`build-essential`, so what lands in the image is reviewable.

## What is pinned, and why

| Input | Pinned by | Where |
|---|---|---|
| `debian:bookworm-slim` | sha256 index digest | `DEBIAN_DIGEST` |
| `golang:1.24-bookworm` | sha256 index digest | `GOLANG_DIGEST` |
| every apt package | `snapshot.debian.org` date | `DEBIAN_SNAPSHOT` |
| timestamps | `SOURCE_DATE_EPOCH` | matches the snapshot date |
| locale / timezone | `LC_ALL=C`, `TZ=UTC` | `ENV` |
| file modes | `umask 022` in the entrypoint | — |
| build uid | non-root `builder`, uid 1000 | — |

Digests must be **index** digests, not per-architecture manifest digests, or the
arm64 build fails to resolve a base image.

Refresh the pins deliberately:

```sh
make pins            # prints the current digests
# paste them into the Makefile, bump DEBIAN_SNAPSHOT and SOURCE_DATE_EPOCH
make build test      # confirm the new environment still reproduces
```

`SOURCE_DATE_EPOCH` should be the same instant as `DEBIAN_SNAPSHOT`:

```sh
python3 -c "import datetime;print(int(datetime.datetime(2026,8,1,tzinfo=datetime.timezone.utc).timestamp()))"
```

## Building a package

The entrypoint is `tape-builder`, so arguments go straight to it:

```sh
docker run --rm \
  -v "$PWD/mypkg":/work/pkg \
  -v "$PWD/out":/out \
  duct/bootstrap:latest build /work/pkg -o /out
```

`/work` is the working directory and `/out` exists and is writable by the build
user (uid 1000 — a host directory it cannot write to will fail the build). For a
shell instead: `make shell`.

The package mount is **not** read-only, and cannot be: `tape-builder` stages
`work/` and `wrap/` inside the package directory and only moves the finished
archive to `-o`. It cleans up after itself unless `--no-clean` is passed. If you
want the source tree left untouched, copy it in rather than mounting it — which
is what `make test` does, and what a build pipeline should do anyway, so that
nothing survives from one build to the next.

## Cross-building

`TAPE_ARCH` is baked into the tape binaries at link time, mapped from the
target platform in the Dockerfile. That mapping is not a formality: `GOARCH` is
`arm` for both armv6 and armv7 and Go does not expose `GOARM` at runtime, so an
armv6 image whose binaries claimed `armv7h` would accept packages its hardware
cannot execute. Unrecognised platforms fail the build rather than guessing.

Multi-platform builds run the apt layer under emulation. On Docker Desktop that
works out of the box; elsewhere:

```sh
docker run --privileged --rm tonistiigi/binfmt --install all
```

## The honest limitations

- **This is a bootstrap host, not a self-hosted one.** Duct packages built here
  are compiled by Debian's gcc against Debian's glibc headers. Getting to a
  toolchain Duct builds itself is a later phase; this image is what makes that
  phase possible, because the starting point stops moving.
- **Upstream sources are still unverified.** The distro scripts in `../distro`
  check download-cache validity by asking whether a sidecar file mentions the
  URL. Pinning the toolchain closes one hole; a checksum file for every upstream
  tarball closes the other, and is the natural next step.
- **`make test` proves determinism for one trivial package.** It catches
  environment leakage — uid, umask, timestamps, locale — which is what it is
  for. It does not prove that a real autotools package with a build script
  reproduces; that needs a real package to test against.
