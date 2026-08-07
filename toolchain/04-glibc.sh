#!/bin/bash
# glibc, cross-compiled with the pass-1 compiler.
#
# This is the point of the whole exercise. From here on, anything built with
# $DUCT_TGT-gcc links against *this* libc -- the one that will ship -- not the
# bootstrap image's. Everything before this stage existed only to make this
# build possible.

STAGE=glibc
. "$(dirname "$0")/common.sh"

unpack GLIBC
src=$SRC_PATH
log "building glibc $GLIBC_VERSION for $DUCT_TGT"

# The dynamic loader has to be findable under the name compiled into every
# binary. 00-prepare.sh has already made /lib a symlink to usr/lib, which is
# what makes the aarch64 loader path resolve with no further help.
#
# x86_64 needs one more hop: its binaries ask for /lib64/ld-linux-x86-64.so.2,
# and with lib64 -> usr/lib64 that lands in a directory glibc never installs
# into. So usr/lib64 gets a symlink pointing back at the real loader in
# usr/lib. Written into usr/lib64 rather than lib64 so it survives the symlink.
case "$HOST_ARCH" in
	i?86)
		ln -sfn "$LOADER" "$DUCT/usr/lib/ld-lsb.so.3" ;;
	x86_64)
		ln -sfn "../lib/$LOADER" "$DUCT/usr/lib64/$LOADER"
		ln -sfn "../lib/$LOADER" "$DUCT/usr/lib64/ld-lsb-x86-64.so.3" ;;
esac

# LFS's FHS patch: glibc still wants to put its runtime state in /var/db, which
# no filesystem hierarchy standard has blessed in decades.
fetch PATCH_GLIBC_FHS
patch -d "$src" -Np1 -i "$FETCHED"

mkdir -p "$src/build"
cd "$src/build"

# glibc's own build system, not ours, decides where sbin binaries go; it
# defaults to /sbin and there is no configure switch for it.
echo "rootsbindir=/usr/sbin" >configparms

# --host is the triple we are building *for*, --build the one we are on. Naming
# both is what makes this a cross build rather than a native one that happens to
# use a prefixed compiler.
../configure \
	--prefix=/usr \
	--host="$DUCT_TGT" \
	--build="$(../scripts/config.guess)" \
	--disable-nscd \
	libc_cv_slibdir=/usr/lib

make
make DESTDIR="$DUCT" install

# ldd's shebang hardcodes an absolute loader path that is wrong for a system
# whose real libraries live under /usr/lib.
sed '/RTLDLIST=/s@/usr@@g' -i "$DUCT/usr/bin/ldd"

# The sanity check that decides whether any of this worked. A binary compiled
# now must be linked against the loader we just installed -- if it names the
# host's, the sysroot is not being honoured and everything built later would be
# quietly wrong.
log "verifying the cross compiler produces correctly linked binaries"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo 'int main(void){return 0;}' >"$tmp/t.c"
"$DUCT_TGT-gcc" "$tmp/t.c" -o "$tmp/t" || die "cannot compile against the new glibc"

interp=$(readelf -l "$tmp/t" | grep 'Requesting program interpreter' | sed 's/.*: \(.*\)]/\1/')
log "program interpreter: $interp"
case "$interp" in
	/lib/$LOADER|/lib64/$LOADER) ;;
	*) die "wrong interpreter '$interp'; expected /lib/$LOADER" ;;
esac

log "done"
