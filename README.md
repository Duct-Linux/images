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

`duct/rust` (`make rust`) builds the packages written in a language Duct does not
package -- uutils-coreutils, and `rust` itself, which bootstraps from it.

### Building `duct/rust`

`.github/workflows/rust.yml` builds and publishes it for both architectures, on
native runners. It triggers on a change to `Dockerfile.rust` and on
`workflow_dispatch`, fetches the pinned rustc tarball itself and checks it
against the sha256 in `Dockerfile.rust` before building.

It reads that pin rather than repeating it. A version and a hash written in two
files are a version and a hash that will eventually disagree, and the resulting
error names a checksum mismatch rather than the stale duplicate that caused it.

**Both architectures or neither.** Each architecture pushes only a run-scoped
`rust:ci-<arch>-<run_id>` tag; a `promote` job that runs only when *every* matrix
leg succeeded moves both to `rust:<arch>` and assembles `rust:latest`. This
matters because of how the consumer behaves: `build.yml` in the packages repo
probes `ghcr.io/duct-linux/rust:<arch>` and schedules the package for whichever
architectures resolve. A tag that exists but is a rebuild behind is therefore
worse than a missing one -- the probe passes, the job runs, and it fails on a
tool the image does not have yet. Publishing one architecture at a time would
manufacture exactly that state.

For the same reason this workflow **fails** on a missing base image where
`assemble.yml` and `bootstrap.yml` skip with a notice. Skipping is right for
them: an architecture that has never been bootstrapped has nothing to assemble.
Here it would half-publish.

The local path is unchanged: `make rust` still builds from
`$(RUST_SOURCES)` (`~/.cache/duct/rust`), which is what a from-scratch local
build uses and what CI is not a substitute for.

### What this image deliberately does not carry

The C libraries a Rust package links against, and the Rust *build tools* a
package needs.

Both build paths install every previously-built Duct package into the container
before `tape-builder` runs -- `BUILD_IN_CONTAINER` in `packages/Makefile`
locally, the `/deps` copy in `build-level.yml` in CI. Neither is conditional on
which image the job uses: in CI every seeding step is gated only on the build
cache, and the copy itself is gated on being root and on `/deps` having content.
`duct/rust` runs as root, so it is seeded like any other image.

Duct has no `-dev` split, so headers and `.pc` files arrive with the package.
That covers the C libraries. It also covers build tools written in Rust: one
built as a package here and published is seeded into whatever job needs it, and
`find_program` resolves it at configure time. `meson` itself arrives this way.

So a Rust package with C dependencies needs nothing from this image but the
toolchain. Adding a GTK stack, or a cargo subcommand, would be a second copy of
something the seed already provides -- and if it landed in `/usr/local/bin` it
would *shadow* the seeded package, since that directory precedes `/usr/bin` on
this image's `PATH`. Two versions, the wrong one winning, and nothing saying so.

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

**Rust** (`.github/workflows/rust.yml`) builds `duct/rust`, sitting between the
two on cost: it compiles, but only a toolchain's worth rather than a system's.
It runs on a `Dockerfile.rust` change and on demand, not on every push.

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

### The coreutils are uutils, and they do not behave like GNU's

Duct ships `uutils-coreutils`, a Rust reimplementation. It is a drop-in
replacement for what the commands *do*, and not always for how they behave when
something goes wrong.

The instance that cost real time: `cp -a` copying a tree over a live root
filesystem hit `/usr/bin/bash` — the shell running the command — and failed with
`ETXTBSY`. GNU `cp` reports such an error and carries on with the remaining
files. uutils' `cp` **stops**. So one busy file silently abandoned everything
after it, and the build failed several minutes later on a missing program that
had been copied successfully in every earlier test.

The tell is the error text: `Device or resource busy (os error 16)` is a Rust
errno, not a GNU one.

Assume this generalises. `mv`, `rm`, `install` and the rest are the same
implementation, and any reasoning that starts "GNU coreutils would carry on
here" is unsafe in this tree. Where a command's partial success matters, assert
the result rather than trusting the exit status.

### Known absences, so they are not filed as bugs

**There is no `libGL.so`.** Mesa is built `-Dglx=disabled`, so desktop GL is
reachable only through EGL. That is correct for the target — a Wayland session
renders through EGL and GLES — but anything that links `-lGL` directly will not
run until Xwayland or libglvnd is packaged. A consequence of the Wayland-first
decision rather than a defect, and the answer to the bug report about a missing
libGL before it is written.

**No BIOS boot.** See below.

**The default image starts GDM.** The live boot wiring starts udev, the D-Bus
system bus and elogind in that order, then starts GDM on tty1. GDM opens the
greeter through PAM and launches the packaged GNOME session. `DESKTOP=0` is the
explicit console/rescue profile; it keeps login shells on the virtual terminals
and starts none of the optional graphical services.

### Customizing the package set

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

### The desktop set

```sh
make iso                     # full GNOME live image (the default)
make iso-manifest            # what that resolves to, sorted
make iso-preflight           # is every package installable right now?
make iso DESKTOP=0           # smaller console/rescue image
```

The default `DESKTOP=1` adds everything the packages tree builds that a console
ISO does not already carry, and **there is no list of package names in this
repository** to make that happen. The set is derived, at build time, from the
packages tree's own `ALL_PKGS`:

```
ISO_DESKTOP_PACKAGES = (ALL_PKGS + RUST_LATE_PKGS) − ISO_BASE − ISO_BOOT
```

read by running `make` on `../packages/Makefile` with a one-rule makefile
(`scripts/print-vars.mk`) added to it. The predecessor of this was 69 package
names written out here; it was accurate for a day and 110 packages short of the
tree ten days later. A list of *tier* names would fail the same way one level
up, because an enumeration only ever matches what its author could see, and the
day a chain adds a list nobody here knows about the ISO silently stops shipping
it. `ALL_PKGS` is the one line every chain already edits when a tier lands.

`RUST_LATE_PKGS` is unioned in explicitly: `ALL_PKGS` does not contain it, and
`librsvg` is the SVG loader without which the icon theme is a directory of
files nothing can decode.

**Absent packages are not filtered out, ever.** A package that has merged but
not yet published makes `tape install` fail and the build stop, which is
correct — silently dropping names that do not resolve produces a green ISO with
no shell on it. `make iso-preflight` is the diagnosis: it fetches the published
index and names every manifest entry as installable, single-architecture,
withdrawn or absent.

#### How the graphical boot is wired

The desktop image contains GDM, GNOME Shell, Mutter, the GTK stack, elogind,
eudev and D-Bus. The `duct-live` package starts the system side and GDM starts
the user session:

| what | where it belongs |
|---|---|
| `udevd` started and `udevadm trigger` run | `duct-live`'s `rc` |
| `dbus-daemon --system` started | `duct-live`'s `rc` |
| `elogind` started before GDM reads the seat state | `duct-live` + the elogind recipe |
| `bluetoothd` started — bluez ships no activation file without systemd | `duct-live`'s `rc` |
| GDM started on tty1; Weston retained as a diagnostic fallback | `duct-live` |
| `pipewire` and `wireplumber` autostart for the session | those two recipes |
| `/run/user/<uid>` | already works: `pam_elogind`, asserted below |

The order is load-bearing and not obvious: **udevd, then D-Bus, then elogind,
then anything graphical.** libinput enumerates through libudev, mutter finds
DRM nodes the same way, and elogind assigns devices to a seat from udev's tags
— so an elogind started before udevd has tagged anything owns a seat with no
master device, and a compositor then fails to take the DRM node in a way that
reads as a compositor bug.

#### What the ISO build does for a desktop

`post-install.sh` grew four things, all guarded, all no-ops for the console
manifest:

- an icon cache per installed theme, rather than for `hicolor` by name
- `dconf update` and `gio-querymodules`, the two caches a desktop reads and a
  console never does
- state directories under `/var/lib` for the accounts daemons drop privileges
  to, created from the rootfs's own `/etc/passwd` — on a systemd distribution
  `systemd-sysusers` and `systemd-tmpfiles` do this, and here nothing did
- an assertion that `login(1)`'s PAM stack **reaches** `pam_elogind`, following
  `include` lines the way PAM does

That last one is a check on the stack rather than on the module file, because a
`pam_elogind.so` no service reaches is indistinguishable from a working system
if you only ask whether the file is installed — and it is the module that
creates `/run/user/<uid>`, which is where a Wayland socket lives. Both arms
were watched: with the module reachable it says so, with it unreachable it
fails and names the recipe to fix, and with elogind absent it says nothing at
all.

To boot one under QEMU, the guest needs a DRM device:

```sh
make iso-boot-test BOOT_GPU=1
```

QEMU's arm64 `virt` machine has no display device unless one is asked for, and
the emulated x86 VGA has no KMS driver in this kernel's configuration — so
without that flag a compositor reports "no DRM device found", which reads as a
driver problem and is a missing `-device`.

### The pieces

```
Dockerfile.iso        three stages: assemble, author, export
iso/post-install.sh   everything tape has no install hook for
iso/make-boot.sh      runs inside the rootfs: initramfs + EFI binary
iso/build-iso.sh      runs on the build host: squashfs + ESP + ISO
iso/early-grub.cfg    compiled into the EFI binary; finds the medium
iso/grub.cfg.in       the boot menu
iso/boot-test.sh      boots the result under QEMU, in a container
iso/preflight.sh      is every package in the manifest installable right now?
scripts/print-vars.mk lets this Makefile ask packages/Makefile a question
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

## Refreshing duct/builder

`duct/base` and `duct/builder` are not compiled. `Dockerfile.base` builds both —
they differ only in the `PACKAGES` build argument — and what it does is run
`tape install` against the *published* repository over HTTPS, verified against
`duct.key.pub`, into `/rootfs`, then `COPY --from` that into `FROM scratch`. A
refresh is therefore an assembly and not a rebuild: minutes, and no compiler
runs. `.github/workflows/assemble.yml` does it for both architectures and a
final job retags `:latest`.

That matters because CI builds every package *inside* the published image, so
the image is a second, slower-moving copy of the repository — and it drifts. As
of this writing the live `ghcr.io/duct-linux/builder:latest` contains:

| checked in the running image | result |
|---|---|
| `/usr/bin/pkgconf` | present |
| `/usr/bin/pkg-config` | **absent**, though published `pkgconf-2.5.1-3` ships it |
| `/usr/include/openssl` | absent, and `openssl` is in neither package list |
| `/usr/bin/python3`, `/usr/bin/msgfmt` | present |

The first row is why `pkgs/_scripts/common.sh` carries a `pkg-config` shim: the
alias exists in the repository and only the image is behind. The shim is
conditional and disables itself the moment a refreshed image lands, so it costs
nothing while it waits.

The third row kills a plausible theory before anyone acts on it: refreshing does
**not** give Python its `ssl` module, because `openssl` is not in either image.
That gap belongs to dependency seeding and to the version the recipe pins.

### One list, not two

`images/Makefile` and `assemble.yml` both define `BASE_PACKAGES` and the builder
additions, and they disagree — CI carries `ca-certificates`, `python` and
`gettext`; the Makefile does not. The running image has `python3` and `msgfmt`,
which settles which list is real: CI's. So `make builder` locally does not
reproduce the image CI uses, and because `ISO_BASE_PACKAGES` derives from the
Makefile's `BUILDER_PACKAGES`, the ISO manifest inherits the stale base too.

Refreshing is the moment to collapse these to a single source rather than to
sync them. A synced pair drifts again; that is what produced this.

### Order of operations

The risk is not the assembly, it is the retag. Every CI job pulls
`builder:latest`, so publishing one mid-flight changes the toolchain underneath
running builds.

1. `workflow_dispatch` with `push: false` — builds and tests both architectures
   and pushes nothing. The push step and the manifest job are both gated on it,
   so the dry run already exists and needs no new code.
2. Wait for other repositories' CI to be idle. Not before.
3. Collapse the two package lists to one source.
4. Push, and retag `:latest`.
5. One full green run against the refreshed image.
6. *Then* delete the `pkg-config` shim — never in the same change. Deleting it
   while any job can still pull a cached older image breaks those jobs for no
   gain.

### If the refresh turns builds red

**Assume it exposed something. Do not assume it broke something.**

A refreshed image is closer to the declared truth than a stale one, so a new
failure is far more likely to be a pre-existing gap becoming visible than a
regression introduced by the refresh. Reverting would restore the silence, not
the correctness.

The precedent is concrete: for a long time no dependencies were seeded into
builder-image jobs at all, so Python compiled with no OpenSSL headers, silently
omitted `_ssl` as an "optional module", and **succeeded**. Fixing the seeding
turned that into a hard compile error. The build did not get worse; the
reporting got honest, and a package that had already shipped without `ssl` was
finally visible. Diagnose first, and revert only with a named cause.

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
