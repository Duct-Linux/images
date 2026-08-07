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
```

`duct/rust` (`make rust`) exists only to build uutils-coreutils, which is the
one package written in a language Duct does not package.

This repo expects `tape`, `packages` and `images` checked out as siblings: the
Docker build context is their common parent, because the bootstrap image
compiles tape from source and the toolchain reads `packages/pkgs/versions.env`.

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
