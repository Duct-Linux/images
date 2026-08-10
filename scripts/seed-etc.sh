#!/bin/sh
# Put the first copy of a mutable /etc file in place, and never touch it again.
#
#   seed-etc.sh <rootfs>
#
# Three files in /etc are REWRITTEN ON A RUNNING SYSTEM: passwd and group by
# useradd, and hosts by whatever sets a hostname. If a package owns them, the
# next upgrade of that package silently replaces them -- tape has no config-file
# handling at all, no conffile concept, no .rpmnew equivalent. Upgrade stages a
# temporary file and renames it over the target, with no path treated specially.
#
# So an installed machine that had accounts added would lose every one of them
# on a routine `tape upgrade duct-filesystem`, while /etc/shadow -- owned by
# nothing -- survived and went on describing users who no longer existed. That
# asymmetry is what made the bug bad: not a missing file, but two files that
# disagreed, with nothing to notice.
#
# The fix is to make those three paths UNOWNED, and to seed them once from
# templates the package does own. Unowning is not free and the set is
# deliberately three: an unowned file is a file no future package update can
# ever improve, so every path added here is a path that stops receiving fixes
# forever. os-release, nsswitch.conf, ld.so.conf, shells and profile stay owned
# precisely because nothing mutates them.
#
# WHY THIS IS A SHARED SCRIPT AND NOT A LINE IN post-install.sh, which is the
# obvious place and the wrong one: the symptom was noticed on the ISO, but the
# cause is in duct-filesystem, which is in EVERY image. Fixing it where the
# symptom was observed would leave duct/base and duct/builder with no
# /etc/passwd at all -- and duct/builder is the image every package build runs
# inside, where getpwnam failures would surface as unrelated-looking build
# breakage with no common cause.
#
# It is a no-op against a duct-filesystem that still ships the real files: the
# target exists, so nothing is seeded. That is what lets it land before the
# package change rather than after.

set -eu

rootfs=${1:?usage: seed-etc.sh <rootfs>}

log() { echo "seed-etc: $*"; }

templates=$rootfs/usr/share/duct-filesystem

# Only files that are rewritten in place on a running system. Adding to this
# list means giving up package updates for that file permanently -- see above.
for name in passwd group hosts; do
	template=$templates/$name.default
	target=$rootfs/etc/$name

	# No template means a duct-filesystem old enough to still ship the real
	# file. Nothing to do, and not an error.
	[ -f "$template" ] || continue

	# -e FOLLOWS SYMLINKS, so a dangling symlink at the target would report
	# false and the seed would write through the link or clobber it. Anything
	# occupying the path, of any type, counts as present: the whole point is
	# never to overwrite, and a broken symlink is still someone's decision.
	if [ -e "$target" ] || [ -L "$target" ]; then
		continue
	fi

	# An explicit mode rather than cp inheriting a umask. glibc reads these on
	# every name lookup, and /etc/passwd arriving 0600 because a build ran under
	# an unusual umask degrades every lookup on the system while saying nothing
	# about why.
	#
	# Not `install -D`: that flag is GNU-only and means something else entirely
	# to BSD install, so it fails on macOS -- where this is reproduced by hand
	# far more often than it is run. The directory is created separately, which
	# costs nothing and works on both.
	[ -d "$rootfs/etc" ] || install -d -m 0755 "$rootfs/etc"
	install -m 0644 "$template" "$target"
	log "seeded /etc/$name"
done
