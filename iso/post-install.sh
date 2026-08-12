#!/bin/sh
# Everything that has to happen after packages are extracted and before the
# rootfs is squashed.
#
#   post-install.sh <rootfs>
#
# This exists because tape has no install hooks. A package can put files in
# place and nothing else: it cannot run ldconfig and it cannot regenerate a
# cache keyed on what else is installed. Any of those has to be done once,
# here, by whoever assembles the image.
#
# It also, today, has to set the setuid and sticky bits -- see the long note
# below. That is a defect being fixed in tape, not a property of packaging:
# tape's archiver carries all three correctly, and the PUBLISH step throws them
# away. The previous wording here ("tape's archiver does not carry setuid,
# setgid or sticky bits at all") reached the right conclusion about the shipped
# payload by blaming the wrong component, which is why nobody went looking.
#
# Every step is guarded on the program existing. Today's ISO manifest has a
# compiler and a shell and none of the desktop libraries, so most of this is a
# no-op -- and stays correct the day a desktop package set is added to
# ISO_EXTRA_PACKAGES without anyone having to remember to come back here.
#
# The ordering is not arbitrary. ldconfig comes first because several of the
# programs below are dynamically linked against libraries that have just been
# installed, and will not start until the cache knows about them.

set -eu

rootfs=${1:?usage: post-install.sh <rootfs>}

log() { echo "post-install: $*"; }
die() { echo "post-install: $*" >&2; exit 1; }

# run_in <program> [args...] -- run a program inside the rootfs, if it is there.
#
# A missing program is a package that is not in this manifest, which is normal
# and not worth a warning. A program that is present and fails is worth
# knowing about, but is not worth failing the whole ISO for: a stale icon cache
# is a cosmetic problem, and a build that stops because of one is worse.
run_in() {
	prog=$1
	[ -x "$rootfs$prog" ] || return 0
	shift
	log "${prog##*/}"
	chroot "$rootfs" "$prog" "$@" >/dev/null 2>&1 || \
		log "warning: ${prog##*/} failed; continuing"
}

# ---------------------------------------------------------------------------
# The mutable /etc files
# ---------------------------------------------------------------------------

# Before everything, including ldconfig: the steps below run programs inside the
# rootfs, and a program that resolves a user needs /etc/passwd to already exist.
#
# Delegated rather than reimplemented. The same script runs in Dockerfile.base,
# because the reason those files are templates is a property of duct-filesystem
# and therefore of every image -- not of the ISO, which is merely where the
# consequence was first noticed.
"$(dirname "$0")/seed-etc.sh" "$rootfs"

# A passwd database using `x` without a shadow database fails inside pam_unix
# as "could not obtain user info". That breaks `login -f` too because its PAM
# account/session phases still run, and GDM cannot open its greeter session.
for account in root gdm duct; do
	grep -q "^$account:" "$rootfs/etc/passwd" || \
		die "/etc/passwd has no $account account; the live login path cannot start"
	grep -q "^$account:" "$rootfs/etc/shadow" || \
		die "/etc/shadow has no $account account; pam_unix would reject the live and GDM sessions"
done
[ "$(stat -c %a "$rootfs/etc/shadow")" = 600 ] || \
	die "/etc/shadow is not mode 600"

# The live desktop is an appliance, not an installed multi-user machine: it
# must arrive at a usable GNOME session without credentials that do not exist.
# Keep this policy in the ISO assembler rather than in the gdm package, so an
# installed system still presents the normal greeter.
if [ -x "$rootfs/usr/sbin/gdm" ]; then
	log "enabling GDM autologin for the live duct user"
	install -d -m 0755 "$rootfs/etc/gdm"
	cat >"$rootfs/etc/gdm/custom.conf" <<'EOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=duct
EOF
fi

# ---------------------------------------------------------------------------
# The linker cache
# ---------------------------------------------------------------------------

# First, and not optional. duct-filesystem ships an /etc/ld.so.conf listing the
# library directories so that the loader can find things by searching until
# this runs -- but searching is a fallback, and anything with an unusual
# soname path needs the cache.
run_in /usr/sbin/ldconfig

# ---------------------------------------------------------------------------
# The mode bits. THESE LINES ARE LOAD-BEARING -- they are not belt and braces.
#
# They used to say they were. The previous comment reported, correctly, that
# `tape install` carries setuid, setgid and sticky end to end: install.go sets
# PreserveSetuid on extraction and sanitizeMode() honours all three. It then
# concluded that everything below is a no-op on a correct extraction. That
# conclusion was wrong, and the reason is one step further out than anyone
# looked: a MEASURED CAPABILITY OF THE TRANSPORT WAS READ AS A PROPERTY OF THE
# PAYLOAD. tape install faithfully carries a bit the package does not have.
#
# Measured 2026-08-12 against the published index, not against a recipe: all
# 622 live payloads on both architectures were downloaded and listed -- 251,608
# entries, ZERO carrying a setuid, setgid or sticky bit, and zero owned by
# anything but root. Not one package has ever shipped one.
#
# The cause is in tape and not here: `tape-repo add-to-repo` extracts each
# incoming package with PreserveSetuid: false and re-tars the extraction into
# the file the repository serves (repo/utils/pkgOpen.go, repo/utils/pkgCopy.go).
# The builder is innocent -- duct-filesystem built end to end in both builder
# images produces 1777 on /tmp, and the published payload of the same
# subversion differs from it in exactly those two directories and nothing else.
# That is being fixed in tape separately.
#
# So until a FIXED tape has republished those packages, every line below is the
# only reason a Duct system has a sticky /tmp or a passwd a user can run. They
# stay after that too, as the guard they were always described as -- but nobody
# reading this should believe they are currently costing microseconds and doing
# nothing.
#
# Because these are the real thing rather than a backstop, the list has to be
# COMPLETE. It was eleven entries short when this was written, which is the
# predictable failure of a hand-maintained list nobody thought was carrying
# weight: it had drifted behind the package set with nothing to notice.
# ---------------------------------------------------------------------------

# if/then rather than `[ -d ] && chmod`: the AND-list is the last command in
# the loop body, so under `set -e` a rootfs without one of these two
# directories aborts the whole build on the guard that exists to skip it. It
# has never fired because duct-filesystem always ships both, which is what
# makes it worth writing down rather than leaving latent.
for d in tmp var/tmp; do
	if [ -d "$rootfs/$d" ]; then
		chmod 1777 "$rootfs/$d"
	fi
done

# Each entry is "<mode> <path>"; a path that is not there is skipped, because
# these belong to packages that may or may not be in the manifest.
#
# Nothing is added here lightly: a setuid root binary is a promise that its
# argument handling is correct. Every entry below is a program whose whole
# purpose requires the bit, and each was checked against the PUBLISHED payload
# of its package rather than against the recipe that was supposed to set it.
#
# EVERY MODE IS root:root, AND THE GROUP IS NOT AVAILABLE TO US. Two
# independent mechanisms take it away, so this is not a preference:
#   - tape's archiver zeroes header.Uid/Gid on purpose, so no package can ship
#     an owner other than root (measured: 0 of 251,608 published entries has a
#     non-zero owner);
# Package archives contain root-owned entries, so package payloads cannot ship
# an owner other than root. post-install.sh restores ownership for mutable
# service state and home directories before the squashfs preserves it.
# So upstream arrangements that restrict a helper by group -- dbus ships its
# launch helper 4750 root:messagebus -- cannot work on a Duct system: the file
# arrives 4750 root:root and the daemon, running as messagebus, cannot execute
# its own helper. The restriction has to come from the mode. Do not "correct"
# any 4755 below to an upstream 4750.
#
# util-linux's mount and umount are *not* here on purpose. The recipe builds
# them with --disable-makeinstall-setuid, so on a Duct system only root mounts
# things -- an intended restriction rather than an omission to repair. Same for
# bubblewrap's bwrap, which is deliberately unprivileged and uses user
# namespaces instead.
setuid_table="
4755 /usr/bin/passwd
4755 /usr/bin/chage
4755 /usr/bin/newgrp
4755 /usr/bin/gpasswd
4755 /usr/bin/su
4755 /usr/bin/expiry
4755 /usr/bin/chfn
4755 /usr/bin/chsh
4755 /usr/bin/newuidmap
4755 /usr/bin/newgidmap
4755 /usr/sbin/unix_chkpwd
4755 /usr/sbin/pam_timestamp_check
4755 /usr/bin/pkexec
4755 /usr/lib/polkit-1/polkit-agent-helper-1
4755 /usr/bin/fusermount3
4755 /usr/libexec/dbus-daemon-launch-helper
"
echo "$setuid_table" | while read -r mode path; do
	[ -n "$mode" ] || continue
	[ -f "$rootfs$path" ] || continue
	log "restoring $mode on $path"
	chmod "$mode" "$rootfs$path"
done

# ---------------------------------------------------------------------------
# Caches keyed on what is installed
#
# Every one of these is a file describing the *set* of installed packages, so
# no single package can own it and no single package can generate it. They are
# all no-ops until the packages that need them are in the manifest.
# ---------------------------------------------------------------------------

run_in /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas
run_in /usr/bin/gdk-pixbuf-query-loaders --update-cache
run_in /usr/bin/update-mime-database /usr/share/mime
run_in /usr/bin/update-desktop-database /usr/share/applications
run_in /usr/bin/fc-cache -f
run_in /usr/bin/udevadm hwdb --update

# GIO's module cache. glib-networking installs the TLS backend as a GIO module
# and nothing else names it: GIO finds it by scanning this directory, and the
# cache is what makes that a lookup rather than a dlopen of everything present.
if [ -d "$rootfs/usr/lib/gio/modules" ]; then
	run_in /usr/bin/gio-querymodules /usr/lib/gio/modules
fi

# dconf's binary databases, compiled from the .d fragments under /etc/dconf/db.
# This is where a greeter's own settings live -- gdm ships /etc/dconf/db/gdm.d
# and reads only the compiled result, so an uncompiled fragment is a setting
# that silently does not apply.
if [ -d "$rootfs/etc/dconf/db" ]; then
	run_in /usr/bin/dconf update
fi

# Icon caches, one per installed theme rather than for hicolor by name.
#
# hicolor was correct while it was the only theme; adwaita-icon-theme and
# anything else with an index.theme need their own, and a hardcoded list of
# theme names is a list that stops matching the moment a theme is added. The
# directory is the enumeration.
if [ -x "$rootfs/usr/bin/gtk4-update-icon-cache" ]; then
	for theme in "$rootfs"/usr/share/icons/*/; do
		[ -f "$theme/index.theme" ] || continue
		run_in /usr/bin/gtk4-update-icon-cache -f -t \
			"/usr/share/icons/$(basename "$theme")"
	done
fi

# ---------------------------------------------------------------------------
# State directories for the accounts daemons run as
#
# On a systemd distribution these are created by systemd-sysusers and
# systemd-tmpfiles, neither of which exists here, and tape has no install hook
# that could do it either. A daemon that drops privileges to its own account
# and then cannot write its state directory fails at run time, on the live
# medium, with nothing in the build having said anything.
#
# Derived from the rootfs's own /etc/passwd rather than from a list of daemon
# names: the accounts are duct-filesystem's decision, and a list here would be
# a second copy of it. Only homes under /var/lib are considered -- /run/dbus
# and friends are tmpfs paths that the boot script creates, and /nonexistent is
# nobody's, deliberately.
#
# Conservative on purpose: an existing directory is left alone unless it is
# still owned by root, because a package that shipped one chose its mode.
# ---------------------------------------------------------------------------

if [ -f "$rootfs/etc/passwd" ]; then
	while IFS=: read -r user _ uid gid _ home _; do
		case $home in
			/var/lib/*) ;;
			*) continue ;;
		esac
		# if/then, not `[ ... ] && continue`: under `set -e` a false test as
		# the last command of an AND-list is the script's exit status, so the
		# guard would kill the build precisely when it does NOT skip.
		if [ "$uid" = "0" ]; then
			continue
		fi
		if [ ! -d "$rootfs$home" ]; then
			log "creating $home for $user"
			install -d -m 0750 "$rootfs$home"
			chown "$uid:$gid" "$rootfs$home"
		elif [ "$(stat -c %u "$rootfs$home")" = "0" ]; then
			log "giving $home to $user"
			chown "$uid:$gid" "$rootfs$home"
		fi
	done <"$rootfs/etc/passwd"
fi

# Human home directories are outside the /var/lib service-account loop above.
# build-iso.sh preserves this ownership in the squashfs.
if [ ! -d "$rootfs/home/duct" ]; then
	log "creating /home/duct"
	install -d -m 0750 "$rootfs/home/duct"
fi
chown 1000:999 "$rootfs/home/duct"

# ---------------------------------------------------------------------------
# The one thing between a login and a Wayland socket
#
# pam_elogind.so is what creates /run/user/<uid>. Not the shell, not the
# kernel, not elogind on its own: the module, running in the SESSION stack of
# whatever service logged the user in. Without it a graphical login succeeds
# and has nowhere to put its socket, and the failure surfaces later as a
# compositor that will not start.
#
# So the check is on the STACK, not on the module file. A pam_elogind.so
# sitting in /usr/lib/security that no service reaches is exactly the state
# this is written to catch, and it is indistinguishable from a working system
# if you only ask whether the file is installed. `login` is resolved the way
# PAM resolves it, following `include` lines, because the module is named in
# system-session and reached from there.
#
# It runs only when elogind is installed. On the console manifest there is no
# module, no stack to check, and nothing to say.
# ---------------------------------------------------------------------------

pam_stack_reaches_elogind() {
	svc=$1
	depth=${2:-0}
	[ "$depth" -lt 5 ] || return 1
	f=$rootfs/etc/pam.d/$svc
	[ -f "$f" ] || return 1
	if grep -q 'pam_elogind' "$f"; then
		return 0
	fi
	for inc in $(awk '$2 == "include" { print $3 }' "$f"); do
		if pam_stack_reaches_elogind "$inc" $((depth + 1)); then
			return 0
		fi
	done
	return 1
}

if [ -f "$rootfs/usr/lib/security/pam_elogind.so" ]; then
	if pam_stack_reaches_elogind login; then
		log "login(1)'s PAM stack reaches pam_elogind; /run/user/<uid> will exist"
	else
		die "pam_elogind.so is installed but login(1)'s PAM stack never reaches it.
  A session would be registered with no XDG_RUNTIME_DIR, and the first thing
  to notice would be a compositor with nowhere to put its Wayland socket.
  Fix in the linux-pam recipe: /etc/pam.d/system-session must carry
  '-session optional pam_elogind.so', and /etc/pam.d/login must include it."
	fi
fi

# ---------------------------------------------------------------------------
# What must NOT be baked in
# ---------------------------------------------------------------------------

# The machine id. Every machine that boots this ISO would otherwise have the
# same one, which is not a cosmetic problem: it is what D-Bus, journald and
# anything doing per-machine state keys off, so two Duct live machines on one
# network would be indistinguishable to anything that asked.
#
# An empty file rather than no file. That is the documented "not yet set"
# state, it reserves the path so the read-only squashfs layer has something for
# the overlay to write over, and duct-live's boot script fills it in on first
# boot.
if [ -d "$rootfs/etc" ]; then
	log "clearing /etc/machine-id so each boot generates its own"
	: >"$rootfs/etc/machine-id"
	chmod 0444 "$rootfs/etc/machine-id"
fi

# Package manager scratch space, and the download cache in particular. A cached
# copy of every package on the ISO would roughly double its size, to no
# purpose: they are all installed already.
rm -rf "$rootfs/var/cache/tape/pkgs" "$rootfs/tmp/tape"

log "done"
