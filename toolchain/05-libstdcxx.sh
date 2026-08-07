#!/bin/bash
# libstdc++, from the pass-1 gcc source.
#
# gcc pass 1 was built --disable-libstdcxx because a C++ standard library needs
# a libc to link against and there was none yet. There is now, so it can be
# built separately from the same source tree. It is needed before pass 2,
# because parts of the gcc build are themselves C++.

STAGE=libstdc++
. "$(dirname "$0")/common.sh"

unpack GCC
src=$SRC_PATH
log "building libstdc++ $GCC_VERSION for $DUCT_TGT"

mkdir -p "$src/build"
cd "$src/build"

# Configured from the libstdc++-v3 subdirectory rather than the gcc top level:
# this is deliberately not a gcc build, only the library.
#
# --with-gxx-include-dir names where the *pass-1* compiler looks for its C++
# headers, which is under /tools rather than /usr.
#
# The path is written relative to the install root, not as "$TOOLS/...", and the
# difference is not cosmetic: the install below runs with DESTDIR=$DUCT, which
# prepends $DUCT to it. Passing the already-absolute $TOOLS produced
# /duct/duct/tools/... -- everything compiled and installed happily, and then
# gcc pass 2 failed with "fatal error: memory: No such file or directory",
# because the headers were sitting one directory deeper than any compiler looks.
../libstdc++-v3/configure \
	--host="$DUCT_TGT" \
	--build="$(../config.guess)" \
	--prefix=/usr \
	--disable-multilib \
	--disable-nls \
	--disable-libstdcxx-pch \
	--with-gxx-include-dir="/tools/$DUCT_TGT/include/c++/$GCC_VERSION"

make
make DESTDIR="$DUCT" install

# libtool archives record build-time paths and confuse anything that reads them
# from a different prefix later.
rm -f "$DUCT"/usr/lib/lib{stdc++{,exp,fs},supc++}.la

# Confirm the headers are where the compiler will actually look for them, and
# confirm it by compiling rather than by checking a path. gcc pass 2 is the
# first thing that needs C++ and it is twenty minutes away; a misplaced include
# directory should fail here, in seconds, with an obvious message.
log "verifying the C++ headers are on the compiler's search path"
hdr=$TOOLS/$DUCT_TGT/include/c++/$GCC_VERSION
[ -f "$hdr/memory" ] || die "libstdc++ headers are not at $hdr (DESTDIR path doubled?)"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '#include <memory>\n#include <string>\nint main(){ return 0; }\n' >"$tmp/t.cc"
"$DUCT_TGT-g++" -c "$tmp/t.cc" -o "$tmp/t.o" \
	|| die "the cross g++ cannot find its own standard headers"

log "done"
