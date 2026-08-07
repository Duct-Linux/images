#!/bin/bash
# Temporary tools, cross-compiled into $DUCT. LFS chapter 6.
#
#   06-temp-tools.sh <package>
#
# Just enough of a userland to run a native build inside the target system:
# a shell, coreutils, make, and the compiler itself. Every one of these is
# thrown away and rebuilt as a real package later, so nothing here needs to be
# pretty -- it needs to work well enough to build its own replacement.
#
# One package per invocation so the Dockerfile can give each its own layer.
# These are cross builds: --host is the target, --build is the machine doing the
# work, and getting that pair wrong produces binaries for the wrong system that
# configure will cheerfully report as working.

STAGE=${1:?usage: 06-temp-tools.sh <package>}
. "$(dirname "$0")/common.sh"

# config.guess moves around between projects; find it rather than hardcoding a
# path per package.
guess_build() {
	local d
	for d in build-aux/config.guess config.guess support/config.guess; do
		if [ -f "$SRC_PATH/$d" ]; then
			( cd "$SRC_PATH" && sh "$d" )
			return 0
		fi
	done
	die "no config.guess in $SRC_PATH"
}

# The configure invocation almost every package here shares.
cross_configure() {
	./configure --prefix=/usr --host="$DUCT_TGT" --build="$(guess_build)" "$@"
}

case "$STAGE" in

m4)
	unpack M4; cd "$SRC_PATH"
	cross_configure
	make; make DESTDIR="$DUCT" install
	;;

ncurses)
	unpack NCURSES; cd "$SRC_PATH"
	# tic runs on the *build* machine to compile the terminfo database, so a
	# cross build needs a native one first. Without this the install silently
	# produces no terminfo and nothing that uses curses works in the chroot.
	mkdir -p build
	( cd build && ../configure AWK=gawk && make -C include && make -C progs tic )
	cross_configure \
		--mandir=/usr/share/man \
		--with-manpage-format=normal \
		--with-shared \
		--without-normal \
		--with-cxx-shared \
		--without-debug \
		--without-ada \
		--disable-stripping \
		AWK=gawk
	make
	make DESTDIR="$DUCT" TIC_PATH="$SRC_PATH/build/progs/tic" install
	ln -sfn libncursesw.so "$DUCT/usr/lib/libncurses.so"
	# Everything links against the wide-character build; make the plain header
	# expose it rather than shipping two incompatible sets of declarations.
	sed -e 's/^#if.*XOPEN.*$/#if 1/' -i "$DUCT/usr/include/curses.h"
	;;

bash)
	unpack BASH; cd "$SRC_PATH"
	# A cross build cannot run the target's strtold to find out whether it is
	# broken, and configure guesses "yes" when it cannot test.
	cross_configure --without-bash-malloc bash_cv_strtold_broken=no
	make; make DESTDIR="$DUCT" install
	ln -sfn bash "$DUCT/usr/bin/sh"
	;;

coreutils)
	unpack COREUTILS; cd "$SRC_PATH"
	# The gl_cv_/ac_cv_ overrides answer questions configure would normally
	# settle by running a test program -- impossible when the program is for a
	# different machine. Each one asserts a capability the target glibc has.
	cross_configure \
		--enable-install-program=hostname \
		--enable-no-install-program=kill,uptime \
		gl_cv_macro_MB_CUR_MAX_good=y \
		ac_cv_func_utimensat=yes \
		gl_cv_func_working_mkstemp=yes
	make; make DESTDIR="$DUCT" install
	# chroot is an administrative tool; FHS puts it in sbin.
	mv -f "$DUCT/usr/bin/chroot" "$DUCT/usr/sbin/chroot"
	mkdir -p "$DUCT/usr/share/man/man8"
	if [ -f "$DUCT/usr/share/man/man1/chroot.1" ]; then
		mv -f "$DUCT/usr/share/man/man1/chroot.1" "$DUCT/usr/share/man/man8/chroot.8"
		sed -i 's/"1"/"8"/' "$DUCT/usr/share/man/man8/chroot.8"
	fi
	;;

diffutils)
	unpack DIFFUTILS; cd "$SRC_PATH"
	# gnulib tests strcasecmp by running a program, and offers no answer for the
	# cross case -- so configure aborts rather than guessing. The target's glibc
	# strcasecmp is fine; say so.
	cross_configure gl_cv_func_strcasecmp_works=y
	make; make DESTDIR="$DUCT" install
	;;

file)
	unpack FILE; cd "$SRC_PATH"
	# file compiles its own magic database with a copy of itself, so as with
	# ncurses' tic a native build has to come first.
	mkdir -p build
	( cd build && ../configure --disable-bzlib --disable-libseccomp \
		--disable-xzlib --disable-zlib && make )
	cross_configure
	make FILE_COMPILE="$SRC_PATH/build/src/file"
	make DESTDIR="$DUCT" install
	rm -f "$DUCT/usr/lib/libmagic.la"
	;;

findutils)
	unpack FINDUTILS; cd "$SRC_PATH"
	cross_configure --localstatedir=/var/lib/locate
	make; make DESTDIR="$DUCT" install
	;;

gawk)
	unpack GAWK; cd "$SRC_PATH"
	# The extras are not wanted and do not cross-compile.
	sed -i 's/extras//' Makefile.in
	cross_configure
	make; make DESTDIR="$DUCT" install
	;;

grep)
	unpack GREP; cd "$SRC_PATH"
	cross_configure
	make; make DESTDIR="$DUCT" install
	;;

gzip)
	unpack GZIP; cd "$SRC_PATH"
	./configure --prefix=/usr --host="$DUCT_TGT"
	make; make DESTDIR="$DUCT" install
	;;

make)
	unpack MAKE; cd "$SRC_PATH"
	cross_configure --without-guile
	make; make DESTDIR="$DUCT" install
	;;

patch)
	unpack PATCH; cd "$SRC_PATH"
	cross_configure
	make; make DESTDIR="$DUCT" install
	;;

sed)
	unpack SED; cd "$SRC_PATH"
	cross_configure
	make; make DESTDIR="$DUCT" install
	;;

tar)
	unpack TAR; cd "$SRC_PATH"
	cross_configure
	make; make DESTDIR="$DUCT" install
	;;

xz)
	unpack XZ; cd "$SRC_PATH"
	cross_configure --disable-static --docdir="/usr/share/doc/xz-$XZ_VERSION"
	make; make DESTDIR="$DUCT" install
	rm -f "$DUCT/usr/lib/liblzma.la"
	;;

binutils-pass2)
	unpack BINUTILS; cd "$SRC_PATH"
	# libtool leaks a build-machine library path into the link line, which
	# makes the target binaries pick up the host's libraries.
	sed '6009s/$add_dir//' -i ltmain.sh
	mkdir -p build; cd build
	../configure \
		--prefix=/usr \
		--build="$(guess_build)" \
		--host="$DUCT_TGT" \
		--disable-nls \
		--enable-shared \
		--enable-gprofng=no \
		--disable-werror \
		--enable-64-bit-bfd \
		--enable-new-dtags \
		--enable-default-hash-style=gnu
	make; make DESTDIR="$DUCT" install
	rm -f "$DUCT"/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
	;;

gcc-pass2)
	unpack GCC; cd "$SRC_PATH"
	for dep in GMP MPFR MPC; do
		eval "depdir=\${${dep}_SRCDIR}"
		fetch "$dep"
		tar -xf "$FETCHED" -C "$SRC_PATH"
		mv "$SRC_PATH/$depdir" "$SRC_PATH/$(echo "$dep" | tr '[:upper:]' '[:lower:]')"
	done
	case "$HOST_ARCH" in
		x86_64) sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64 ;;
	esac
	# The generated thread header names a build-machine path; posix threads are
	# what the target has, so say so directly.
	sed '/thread_header =/s/@.*@/gthr-posix.h/' \
		-i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
	mkdir -p build; cd build
	../configure \
		--build="$(guess_build)" \
		--host="$DUCT_TGT" \
		--target="$DUCT_TGT" \
		LDFLAGS_FOR_TARGET="-L$PWD/$DUCT_TGT/libgcc" \
		--prefix=/usr \
		--with-build-sysroot="$DUCT" \
		--enable-default-pie \
		--enable-default-ssp \
		--disable-nls \
		--disable-multilib \
		--disable-libatomic \
		--disable-libgomp \
		--disable-libquadmath \
		--disable-libsanitizer \
		--disable-libssp \
		--disable-libvtv \
		--enable-languages=c,c++
	make; make DESTDIR="$DUCT" install
	ln -sfn gcc "$DUCT/usr/bin/cc"
	;;

*)
	die "unknown temp tool: $STAGE"
	;;
esac

log "done"
