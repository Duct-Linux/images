#!/bin/bash
# Cross binutils. The assembler and linker that every later stage uses.
#
# This has to come first and it has to be a cross build: gcc pass 1 is
# configured with --target=$DUCT_TGT and will look for $DUCT_TGT-as and
# $DUCT_TGT-ld by name. Building the host's binutils instead would produce a
# compiler that silently assembles with the bootstrap image's tools.

STAGE=binutils-pass1
. "$(dirname "$0")/common.sh"

unpack BINUTILS
src=$SRC_PATH
log "building binutils $BINUTILS_VERSION for $DUCT_TGT"

mkdir -p "$src/build"
cd "$src/build"

# --with-sysroot tells the linker that "/" means $DUCT, so it resolves libraries
# out of the system being built rather than the one doing the building.
../configure \
	--prefix="$TOOLS" \
	--with-sysroot="$DUCT" \
	--target="$DUCT_TGT" \
	--disable-nls \
	--enable-gprofng=no \
	--disable-werror \
	--enable-new-dtags \
	--enable-default-hash-style=gnu

make
make install

command -v "$DUCT_TGT-ld" >/dev/null || die "$DUCT_TGT-ld was not installed"
log "done: $($DUCT_TGT-ld --version | head -1)"
