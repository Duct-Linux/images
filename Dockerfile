# syntax=docker/dockerfile:1.7
#
# The Duct bootstrap image.
#
# This is the *bootstrap host* for Duct: a fixed, digest-pinned environment that
# compiles Duct packages so the result depends on nothing about the machine that
# ran the build. It is not self-hosted -- the toolchain here is Debian's, not
# Duct's. Self-hosting comes later, once enough of the distribution can rebuild
# itself.
#
# Everything that could drift is pinned:
#   * both base images by sha256 digest (index digests, so both platforms work)
#   * every apt package by snapshot.debian.org date
#   * SOURCE_DATE_EPOCH, TZ and LC_ALL, so timestamps and collation are fixed
#
# Build from the Duct root, not from this directory:
#   docker buildx build -f docker/Dockerfile .
# The image compiles tape from source, so the repository above is the context.

# Pinned base images. Refresh with `make pins`.
ARG GOLANG_DIGEST=sha256:1a6d4452c65dea36aac2e2d606b01b4a029ec90cc1ae53890540ce6173ea77ac
ARG DEBIAN_DIGEST=sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

# ---------------------------------------------------------------------------
# Stage 1 -- compile tape.
#
# Pinned to $BUILDPLATFORM rather than $TARGETPLATFORM on purpose. tape is
# CGO_ENABLED=0 all the way down (its sqlite driver is pure Go), so a native
# builder cross-compiles every target at full speed instead of running the Go
# toolchain under emulation.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.24-bookworm@${GOLANG_DIGEST} AS tape

ARG TARGETARCH
ARG TARGETVARIANT

WORKDIR /src
COPY tape/ ./

# TAPE_ARCH is baked in at link time and is not always derivable from GOARCH:
# GOARCH is "arm" for both armv6 and armv7, and Go does not expose GOARM at
# runtime, so an armv6 build would otherwise report itself as armv7h and accept
# packages its hardware cannot execute. Unknown platforms fail loudly rather
# than producing a mislabelled binary.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    goarm=; \
    case "${TARGETARCH}${TARGETVARIANT}" in \
      amd64)   tape_arch=x86_64  ;; \
      arm64*)  tape_arch=aarch64 ;; \
      386)     tape_arch=i686    ;; \
      riscv64) tape_arch=riscv64 ;; \
      armv7)   tape_arch=armv7h; goarm=7 ;; \
      armv6)   tape_arch=armv6h; goarm=6 ;; \
      *) echo "unsupported target: ${TARGETARCH}${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    make build GOOS=linux GOARCH="$TARGETARCH" GOARM="$goarm" TAPE_ARCH="$tape_arch"; \
    ./bin/tape --help >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Stage 2 -- the builder environment.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim@${DEBIAN_DIGEST}

ARG DEBIAN_SNAPSHOT=20260801T000000Z
ARG SOURCE_DATE_EPOCH=1785542400
ARG DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.title="Duct bootstrap" \
      org.opencontainers.image.description="Reproducible build environment for Duct packages, with the tape toolchain" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

# Point apt at a frozen snapshot. This is the difference between "repeatable"
# and "reproducible": without it, the same Dockerfile installs a different gcc
# next month. bookworm-slim ships the deb822 sources file, so remove it or it
# wins over sources.list and drags in current packages.
#
# http, not https, and deliberately: bookworm-slim carries no ca-certificates,
# so https here is a chicken-and-egg -- apt cannot fetch the package that would
# let it verify the certificate. Nothing is lost. apt authenticates the archive
# with the Debian archive keyring that is already in the image, and a snapshot
# Release file is immutable, so integrity comes from the signature rather than
# from the transport.
#
# Check-Valid-Until is off because a pinned snapshot is stale by definition.
# Error-Mode=any makes a failed index fetch fail the build: without it apt-get
# update exits 0 after every source errored, and the failure only surfaces
# later as a confusing "package is not available".
RUN set -eux; \
    rm -f /etc/apt/sources.list.d/debian.sources; \
    { \
      echo "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ bookworm main"; \
      echo "deb http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ bookworm-updates main"; \
      echo "deb http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}/ bookworm-security main"; \
    } > /etc/apt/sources.list; \
    { \
      echo 'Acquire::Check-Valid-Until "false";'; \
      echo 'Acquire::Retries "5";'; \
      echo 'APT::Update::Error-Mode "any";'; \
    } > /etc/apt/apt.conf.d/10duct-snapshot

# Listed explicitly rather than via build-essential so the contents of this
# image are reviewable. The set is what the Duct stage scripts actually invoke:
# an autotools C/C++ toolchain, the generators glibc and gcc need (bison, flex,
# m4, texinfo, python3), and the archive formats upstream tarballs arrive in.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        gcc g++ make binutils libc6-dev linux-libc-dev \
        autoconf automake libtool pkg-config m4 \
        bison flex gawk sed grep patch perl python3 texinfo gettext \
        file diffutils findutils coreutils \
        tar gzip bzip2 xz-utils zstd cpio \
        bc wget ca-certificates git rsync; \
    rm -rf /var/lib/apt/lists/*

COPY --from=tape /src/bin/tape          /usr/bin/tape
COPY --from=tape /src/bin/taped         /usr/bin/taped
COPY --from=tape /src/bin/tape-builder  /usr/bin/tape-builder
COPY --from=tape /src/bin/tape-repo     /usr/bin/tape-repo
COPY --from=tape /src/common/config/sample_config.toml /etc/tape/config.toml.sample

RUN set -eux; \
    install -d /etc/tape/repos /etc/tape/keys /var/cache/tape/repos /var/lib/tape; \
    groupadd -g 1000 builder; \
    useradd -u 1000 -g 1000 -m -d /home/builder -s /bin/bash builder; \
    install -d -o builder -g builder /work /out

# Builds install into a DESTDIR, so root buys nothing and costs reproducibility:
# the old distro tarballs record whatever uid happened to run the build.
USER builder

# TZ and LC_ALL fix anything that formats a date or sorts a list during a build.
#
# SOURCE_DATE_EPOCH is read by tape itself: common/tarUtils/tar.go stamps it
# into every archive entry, so a package records the release date rather than
# the moment the build happened to run. Upstream build systems read the same
# variable, which is why it is set for the whole environment and not just tape.
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    TZ=UTC \
    LC_ALL=C \
    LANG=C.UTF-8 \
    TAPE_CONFIG_DIR=/etc/tape \
    TAPE_CACHE_DIR=/var/cache/tape

# umask cannot be set with ENV, and a build that inherits 0002 produces
# group-writable files -- a difference that survives into the package.
COPY --chmod=0755 <<'EOF' /usr/local/bin/duct-build
#!/bin/sh
umask 022
exec tape-builder "$@"
EOF

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/duct-build"]
CMD ["--help"]
