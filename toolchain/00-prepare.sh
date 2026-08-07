#!/bin/bash
# Lay out the staging root before anything is built into it.
#
# $DUCT has to have the *final system's* directory layout from the start, not a
# convenient approximation, because the cross toolchain is configured with
# --with-sysroot=$DUCT: what the linker sees here is what a binary will look for
# at runtime.
#
# The specific trap is merged-/usr. glibc is configured with
# libc_cv_slibdir=/usr/lib, so the dynamic loader installs to /usr/lib -- but
# every binary the compiler produces asks for it at /lib (or /lib64). Unless
# /lib is a symlink into /usr/lib, that lookup fails, and it fails at the worst
# possible moment: everything compiles, and nothing runs.

STAGE=prepare
. "$(dirname "$0")/common.sh"

log "preparing the staging root at $DUCT"

mkdir -p \
	"$DUCT/usr/bin" \
	"$DUCT/usr/lib" \
	"$DUCT/usr/lib64" \
	"$DUCT/usr/sbin" \
	"$DUCT/usr/include" \
	"$DUCT/etc" \
	"$DUCT/var" \
	"$TOOLS"

# The same merged-/usr layout duct-filesystem ships, created the same way.
# Relative targets, so they stay correct however $DUCT is mounted or copied.
ln -sfn usr/bin "$DUCT/bin"
ln -sfn usr/lib "$DUCT/lib"
ln -sfn usr/lib64 "$DUCT/lib64"
ln -sfn usr/sbin "$DUCT/sbin"

for link in bin lib lib64 sbin; do
	[ -L "$DUCT/$link" ] || die "$DUCT/$link is not a symlink"
done

log "layout ready"
ls -l "$DUCT" >&2
