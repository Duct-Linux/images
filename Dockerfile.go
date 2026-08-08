# syntax=docker/dockerfile:1.7
#
# duct/go -- duct/builder plus a pinned Go, for building the go package.
#
# Go is the second language Duct does not package, and the reason tape cannot be
# rebuilt inside Duct: the binaries are copied out of the bootstrap image rather
# than compiled from a Duct toolchain. Packaging Go closes that -- after which
# duct/builder plus the go package can rebuild tape from source.
#
# Go is bootstrapped by Go. There is no C path any more: building the toolchain
# from source needs a working Go first, so a pinned upstream release is imported
# here exactly the way rustc is for uutils, and everything after that is built
# by Duct's own compiler against Duct's own glibc.
#
# The imported toolchain links against an older glibc than Duct ships, which is
# fine in that direction: glibc keeps backward compatibility.

ARG BUILDER=ghcr.io/duct-linux/builder:latest
ARG BOOTSTRAP=ghcr.io/duct-linux/bootstrap:latest

# Only for its CA bundle, below.
FROM ${BOOTSTRAP} AS certs

FROM ${BUILDER}

ARG GO_VERSION=1.26.5
ARG GO_SHA256_AARCH64=fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49
ARG GO_SHA256_X86_64=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053

# No GOFLAGS here: -mod=mod is rejected outright in workspace mode, and tape is
# a five-module workspace.
ENV PATH=/usr/local/go/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin \
    GOTOOLCHAIN=local

# Duct ships no curl and no wget, so the tarball arrives as a build context and
# is checked against the pin before anything is unpacked.
#
# GOROOT_BOOTSTRAP is what the source build looks for, so the imported release
# is kept in its own directory rather than installed over /usr: the packaged Go
# must not end up built against pieces of the toolchain that bootstrapped it.
RUN --mount=type=bind,from=ductgo,target=/gosrc,ro \
    set -eux; \
    arch=$(uname -m); \
    case "$arch" in \
      aarch64) goarch=arm64; want=${GO_SHA256_AARCH64} ;; \
      x86_64)  goarch=amd64; want=${GO_SHA256_X86_64}  ;; \
      *) echo "no pinned Go for $arch" >&2; exit 1 ;; \
    esac; \
    file=/gosrc/go${GO_VERSION}.linux-${goarch}.tar.gz; \
    [ -f "$file" ] || { echo "missing $file" >&2; exit 1; }; \
    got=$(sha256sum "$file" | cut -d' ' -f1); \
    [ "$got" = "$want" ] || { echo "go sha256 mismatch: want $want got $got" >&2; exit 1; }; \
    mkdir -p /usr/local; \
    tar -xf "$file" -C /usr/local; \
    go version

ENV GOROOT_BOOTSTRAP=/usr/local/go

# Go's own build fetches nothing, but `go build` of anything else may, and it
# needs a trust store to do it over TLS. duct/base ships ca-certificates now, so
# this is only for the case where the builder image predates it.
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

LABEL org.opencontainers.image.title="Duct Go environment" \
      org.opencontainers.image.description="duct/builder plus a pinned Go, for building the go package natively against Duct glibc" \
      org.opencontainers.image.source="https://github.com/Duct-Linux/images"
