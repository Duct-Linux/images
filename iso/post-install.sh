#!/bin/sh
# Everything that has to happen after packages are extracted and before the
# rootfs is squashed.
#
#   post-install.sh <rootfs>
#
# This exists because tape has no install hooks. A package can put files in
# place and nothing else: it cannot run ldconfig, it cannot regenerate a cache
# keyed on what else is installed, and it cannot set a setuid bit -- tape's
# archiver does not carry setuid, setgid or sticky bits at all. Any of those
# has to be done once, here, by whoever assembles the image.
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

# ---------------------------------------------------------------------------
# The linker cache
# ---------------------------------------------------------------------------

# First, and not optional. duct-filesystem ships an /etc/ld.so.conf listing the
# library directories so that the loader can find things by searching until
# this runs -- but searching is a fallback, and anything with an unusual
# soname path needs the cache.
run_in /usr/sbin/ldconfig

# ---------------------------------------------------------------------------
# Belt and braces on the mode bits
#
# These were written when packages/README.md said tape could not represent
# setuid, setgid or sticky bits at all. That turned out to be wrong, and it was
# worth measuring rather than believing: install.go sets PreserveSetuid on
# extraction and sanitizeMode() in tarUtils honours setuid, setgid and sticky
# when it is set, so `tape install` carries all three end to end.
#
# Kept anyway, and deliberately. Every line below is idempotent and guarded on
# the path existing, so on a correct extraction they are no-ops that cost
# microseconds -- and if tape's extraction path ever changes, the failure they
# prevent is a world-writable /tmp with no sticky bit and a passwd that cannot
# change a password. That is a poor thing to find out from a user.
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
# argument handling is correct. The list is short and every entry is a program
# whose whole purpose requires the bit.
#
# util-linux's mount and umount are *not* here on purpose. The recipe builds
# them with --disable-makeinstall-setuid, so on a Duct system only root mounts
# things -- an intended restriction rather than an omission to repair.
setuid_table="
4755 /usr/bin/passwd
4755 /usr/bin/chage
4755 /usr/bin/newgrp
4755 /usr/bin/gpasswd
4755 /usr/bin/su
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
