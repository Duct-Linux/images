#!/bin/bash
# Additional temporary tools, built natively. LFS chapter 7.
#
#   07-chroot-tools.sh <package>
#
# Chapter 6 cross-compiled just enough to make the target system self-hosting.
# These are the tools that the *final* builds need but which nothing so far has
# provided -- most pointedly bison and python, without which glibc's own
# configure refuses to run:
#
#     configure: error:
#     *** These critical programs are missing or too old: bison python
#
# Unlike chapter 6 these are native builds: the compiler, the libc and the host
# are all Duct's now, so there is no --host/--build pair and no cross-compile
# guesswork. They are still temporary, and every one of them is replaced by a
# real package later.

STAGE=${1:?usage: 07-chroot-tools.sh <package>}
. "$(dirname "$0")/common.sh"

# common.sh is written for the cross build: it puts $DUCT/tools first on PATH
# and stages into $DUCT. Neither applies here -- this runs inside the target
# system, where /duct does not exist and the compiler is simply gcc. Overriding
# after sourcing keeps the fetch and unpack helpers without editing common.sh,
# which every cross stage depends on and which would rebuild the whole toolchain
# if touched.
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
BUILD_ROOT=${BUILD_ROOT:-/build}
mkdir -p "$BUILD_ROOT"

command -v gcc >/dev/null || die "no gcc: this stage runs inside duct/chroot"

# Native, so everything installs straight into the system rather than into a
# staged $DUCT. Chapter 6 built the compiler that makes this possible.
native_configure() {
	./configure --prefix=/usr "$@"
}

case "$STAGE" in

gettext)
	unpack GETTEXT; cd "$SRC_PATH"
	native_configure --disable-shared
	make
	# Only the three programs later builds actually invoke. The libraries are
	# deliberately not installed: this is scaffolding, and a temporary
	# libintl on the library path would shadow the real one later.
	cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
	;;

bison)
	unpack BISON; cd "$SRC_PATH"
	native_configure --docdir="/usr/share/doc/bison-$BISON_VERSION"
	make
	make install
	;;

perl)
	unpack PERL; cd "$SRC_PATH"
	# Perl's Configure is not autoconf. -des accepts every default; the paths
	# are spelled out so the temporary perl looks for its modules where the
	# real package will later put them.
	perl_ver=$(echo "$PERL_VERSION" | cut -d. -f1,2)
	sh Configure -des \
		-D prefix=/usr \
		-D vendorprefix=/usr \
		-D useshrplib \
		-D privlib="/usr/lib/perl5/$perl_ver/core_perl" \
		-D archlib="/usr/lib/perl5/$perl_ver/core_perl" \
		-D sitelib="/usr/lib/perl5/$perl_ver/site_perl" \
		-D sitearch="/usr/lib/perl5/$perl_ver/site_perl" \
		-D vendorlib="/usr/lib/perl5/$perl_ver/vendor_perl" \
		-D vendorarch="/usr/lib/perl5/$perl_ver/vendor_perl"
	make
	make install
	;;

python)
	unpack PYTHON; cd "$SRC_PATH"
	# --without-ensurepip because pip would try to reach the network, and
	# nothing here needs it: python is present only so glibc's build scripts
	# have an interpreter.
	native_configure --enable-shared --without-ensurepip --without-static-libpython
	make
	make install
	;;

texinfo)
	unpack TEXINFO; cd "$SRC_PATH"
	native_configure
	make
	make install
	;;

util-linux)
	unpack UTIL_LINUX; cd "$SRC_PATH"
	mkdir -p /var/lib/hwclock
	# A long list of disables: this is a temporary util-linux that exists for
	# the libraries a few later configure scripts probe for, not for its
	# programs -- several of which want setuid bits that tape cannot express
	# anyway.
	native_configure \
		--libdir=/usr/lib \
		--runstatedir=/run \
		--disable-chfn-chsh \
		--disable-login \
		--disable-nologin \
		--disable-su \
		--disable-setpriv \
		--disable-runuser \
		--disable-pylibmount \
		--disable-static \
		--disable-liblastlog2 \
		--without-python \
		ADJTIME_PATH=/var/lib/hwclock/adjtime
	make
	make install
	;;

*)
	die "unknown chroot tool: $STAGE"
	;;
esac

log "done"
