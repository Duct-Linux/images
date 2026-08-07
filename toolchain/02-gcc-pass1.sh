#!/bin/bash
# Cross gcc, pass 1. Just enough compiler to build glibc.
#
# It cannot be a complete compiler yet: a full gcc links against libc, and libc
# does not exist for $DUCT_TGT until the next stage but one. So this is built
# --without-headers and --disable-shared, produces no usable libstdc++, and
# exists only to compile glibc. Pass 2 replaces it once there is a libc to link
# against.

STAGE=gcc-pass1
. "$(dirname "$0")/common.sh"

unpack GCC
src=$SRC_PATH
log "building gcc $GCC_VERSION for $DUCT_TGT"

# gcc builds gmp, mpfr and mpc in-tree when it finds them under these exact
# names. Doing it this way rather than installing them on the host keeps three
# more libraries out of the final compiler's dependency set.
for dep in GMP MPFR MPC; do
	eval "depdir=\${${dep}_SRCDIR}"
	fetch "$dep"
	tar -xf "$FETCHED" -C "$src"
	mv "$src/$depdir" "$src/$(echo "$dep" | tr '[:upper:]' '[:lower:]')"
done

# On x86_64 gcc defaults its 64-bit libraries to lib64. Duct is merged-/usr with
# everything in lib, so redirect it before configuring; getting this wrong sends
# glibc to $DUCT/usr/lib64 and leaves the linker unable to find it.
case "$HOST_ARCH" in
	x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig "$src/gcc/config/i386/t-linux64" ;;
esac

mkdir -p "$src/build"
cd "$src/build"

../configure \
	--target="$DUCT_TGT" \
	--prefix="$TOOLS" \
	--with-glibc-version="$GLIBC_VERSION" \
	--with-sysroot="$DUCT" \
	--with-newlib \
	--without-headers \
	--enable-default-pie \
	--enable-default-ssp \
	--disable-nls \
	--disable-shared \
	--disable-multilib \
	--disable-threads \
	--disable-libatomic \
	--disable-libgomp \
	--disable-libquadmath \
	--disable-libssp \
	--disable-libvtv \
	--disable-libstdcxx \
	--enable-languages=c,c++

make
make install

# gcc ships a limits.h that defers to the system one, which does not exist yet.
# glibc's build reads it, so assemble the complete header by hand from the three
# fragments gcc keeps for exactly this bootstrap case.
cd "$src"
limits_dir=$(dirname "$("$DUCT_TGT-gcc" -print-libgcc-file-name)")/include
cat gcc/limitx.h gcc/glimits.h gcc/limity.h >"$limits_dir/limits.h"

log "done: $($DUCT_TGT-gcc --version | head -1)"
