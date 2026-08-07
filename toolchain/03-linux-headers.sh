#!/bin/bash
# Linux API headers.
#
# glibc is the interface between userspace and the kernel, so it needs the
# kernel's own headers to build against. These are the sanitised, userspace-safe
# subset the kernel exports -- not the kernel's internal headers, which are not
# usable outside the tree.

STAGE=linux-headers
. "$(dirname "$0")/common.sh"

unpack LINUX
src=$SRC_PATH
log "installing Linux $LINUX_VERSION API headers"

cd "$src"

# mrproper guarantees no stale generated file from the tarball leaks in.
make mrproper
make headers

# The headers target leaves behind dotfiles and a couple of non-header artefacts
# that must not be installed.
find usr/include -type f ! -name '*.h' -delete

mkdir -p "$DUCT/usr"
cp -r usr/include "$DUCT/usr"

[ -f "$DUCT/usr/include/linux/version.h" ] || die "headers were not installed"
log "done"
