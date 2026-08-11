#!/bin/sh
# Build the boot tree of the live ISO -- everything except the squashfs.
#
#   make-boot.sh <rootfs> <isoroot> <template-dir>
#
# Every artefact this produces is made by Duct's own programs, running inside
# the Duct root filesystem that is about to be shipped. The initramfs is packed
# by Duct's busybox and compressed by Duct's gzip; the EFI binary is linked by
# Duct's grub-mkimage out of Duct's GRUB modules. That is the whole reason this
# runs under chroot rather than using the build host's tools, which are right
# there and would be much easier to call.
#
# It matters because this is the part of the ISO that firmware executes. A
# distribution that compiles its own libc and then boots through somebody
# else's bootloader has not really bootstrapped anything.

set -eu

rootfs=${1:?usage: make-boot.sh <rootfs> <isoroot> <template-dir>}
isoroot=${2:?usage: make-boot.sh <rootfs> <isoroot> <template-dir>}
templates=${3:?usage: make-boot.sh <rootfs> <isoroot> <template-dir>}

die() { echo "make-boot: $*" >&2; exit 1; }
log() { echo "make-boot: $*"; }

# ---------------------------------------------------------------------------
# What is in the rootfs
# ---------------------------------------------------------------------------

# The kernel package installs /boot/vmlinuz-<release> and a /boot/vmlinuz
# symlink to it. The release is read back from the real name rather than from
# `uname -r`, which would report the *build host's* kernel -- a Docker daemon's
# kernel, on a machine that may not even be running Linux.
# Count first, assert the count, THEN take the value.
#
# This was `ls ... | head -1` with an is-it-empty check, which has two faults.
# It SILENTLY PICKS ONE of several kernels -- and the comment above says there
# is exactly one, so the code was checking something weaker than the invariant
# it was written against. And the 2>/dev/null discarded the reason: a
# permission error or a broken mount produced the message below, which names
# the manifest confidently and sends the reader to a file that is fine.
if ! kernel_list=$(find "$rootfs/boot" -maxdepth 1 -name 'vmlinuz-*' -type f 2>&1); then
	die "cannot list $rootfs/boot: $kernel_list"
fi
kernel_n=$(printf '%s' "$kernel_list" | grep -c . || true)
[ "$kernel_n" -eq 1 ] || die "expected exactly one /boot/vmlinuz-* in the rootfs, found $kernel_n${kernel_list:+ -- $kernel_list}; is the linux package in the manifest?"
kernel=$kernel_list
release=${kernel##*/vmlinuz-}
log "kernel $release"

[ -x "$rootfs/usr/bin/duct-mkinitramfs" ] || die "duct-mkinitramfs is missing; is duct-live in the manifest?"
[ -x "$rootfs/usr/bin/grub-mkimage" ]     || die "grub-mkimage is missing; is grub in the manifest?"

# GRUB names its own target and there is exactly one, because the package is
# built --with-platform=efi. Reading it back beats hardcoding a table: if the
# grub package is ever built for another architecture, this keeps working.
# Exactly one, as the comment above states. Taking head -1 of several would
# link the EFI binary for the WRONG ARCHITECTURE and produce an ISO that
# builds, passes iso-test, and does not boot.
if ! grub_dirs=$(find "$rootfs/usr/lib/grub" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>&1); then
	die "cannot list $rootfs/usr/lib/grub: $grub_dirs"
fi
grub_n=$(printf '%s' "$grub_dirs" | grep -c . || true)
[ "$grub_n" -eq 1 ] || die "expected exactly one GRUB platform directory, found $grub_n${grub_dirs:+ -- $grub_dirs}"
grub_target=$grub_dirs
log "GRUB platform $grub_target"

# The name firmware looks for on the removable-media path. This is fixed by the
# UEFI specification, not by us -- \EFI\BOOT\BOOT<MACHINE>.EFI is the only path
# a machine will boot without an NVRAM entry, and an ISO has no NVRAM entry.
case "$grub_target" in
	arm64-efi)   efi_name=BOOTAA64.EFI;   serial=ttyAMA0 ;;
	x86_64-efi)  efi_name=BOOTX64.EFI;    serial=ttyS0   ;;
	i386-efi)    efi_name=BOOTIA32.EFI;   serial=ttyS0   ;;
	riscv64-efi) efi_name=BOOTRISCV64.EFI; serial=ttyS0  ;;
	*) die "no removable-media EFI name known for $grub_target" ;;
esac

# ---------------------------------------------------------------------------
# The initramfs
# ---------------------------------------------------------------------------

# duct-mkinitramfs redirects to /dev/null, and a chroot with no /dev has none.
# These three exist for the duration of the chroot and are removed again below
# -- they must not survive into the image. Nothing needs them at boot, because
# the initramfs mounts devtmpfs on /dev and moves it into the new root before
# init runs, and a device node does not reliably survive a `COPY --from`
# between build stages anyway.
#
# A real device node if the filesystem will take one, an empty regular file if
# it will not. mknod fails on more build hosts than one would expect -- a
# bind-mounted directory on Docker Desktop refuses it outright, whatever
# capabilities the container has -- and for the two things that happen inside
# this chroot, a regular file is indistinguishable: `2>/dev/null` truncates and
# writes a few bytes to it, and then it is deleted.
created_nodes=
for spec in "null c 1 3 666" "zero c 1 5 666" "console c 5 1 600"; do
	# shellcheck disable=SC2086
	set -- $spec
	name=$1
	[ -e "$rootfs/dev/$name" ] && continue
	if ! mknod -m "$5" "$rootfs/dev/$name" "$2" "$3" "$4" 2>/dev/null; then
		: >"$rootfs/dev/$name" || die "cannot create a stand-in for /dev/$name"
		chmod "$5" "$rootfs/dev/$name"
	fi
	created_nodes="$created_nodes $name"
done

log "building the initramfs"
chroot "$rootfs" /usr/bin/duct-mkinitramfs -o /boot/initramfs.img -r "$release" ||
	die "duct-mkinitramfs failed"

# ---------------------------------------------------------------------------
# The GRUB EFI binary
# ---------------------------------------------------------------------------

# What gets linked into the binary, as opposed to loaded from /boot/grub later.
# The rule is simple: everything needed to find the medium and read the menu
# has to be embedded, because until the menu is read GRUB does not know where
# its module directory is.
#
#   part_gpt, part_msdos    the ISO is written with both partition tables, so
#                           that dd'ing it to a USB stick produces something a
#                           firmware will recognise
#   iso9660, fat, udf       the medium, as a disc and as a stick
#   search*, configfile     what early-grub.cfg calls
#   linux, gzio            loading and decompressing the kernel
#   all_video, efi_gop      output, before any menu has said anything about it
#   normal, echo, test, ls  a usable prompt if the search fails
grub_modules="part_gpt part_msdos fat iso9660 udf ext2 \
	search search_fs_file search_fs_uuid search_label \
	configfile normal linux boot echo test true \
	loadenv minicmd reboot halt sleep ls cat help \
	gzio all_video video video_fb efi_gop terminal"

install -m 0644 "$templates/early-grub.cfg" "$rootfs/tmp/early-grub.cfg"

log "linking $efi_name"
# -p is the fallback prefix, used only if early-grub.cfg's search fails; -c is
# the configuration compiled into the image.
# shellcheck disable=SC2086
chroot "$rootfs" /usr/bin/grub-mkimage \
	-O "$grub_target" \
	-o "/tmp/$efi_name" \
	-p /boot/grub \
	-c /tmp/early-grub.cfg \
	$grub_modules || die "grub-mkimage failed"

# ---------------------------------------------------------------------------
# Lay out the ISO tree
# ---------------------------------------------------------------------------

install -d "$isoroot/boot/grub/$grub_target" "$isoroot/EFI/BOOT" "$isoroot/duct"

install -m 0644 "$rootfs/boot/vmlinuz-$release" "$isoroot/boot/vmlinuz"
install -m 0644 "$rootfs/boot/initramfs.img"    "$isoroot/boot/initramfs.img"

install -m 0644 "$rootfs/tmp/$efi_name" "$isoroot/EFI/BOOT/$efi_name"

# The modules GRUB did not get embedded. Nothing in the menu needs them, but a
# GRUB prompt without its module directory can barely do anything, and this is
# the state someone lands in when a boot has already gone wrong.
cp "$rootfs/usr/lib/grub/$grub_target"/*.mod "$isoroot/boot/grub/$grub_target/" 2>/dev/null || true
cp "$rootfs/usr/lib/grub/$grub_target"/*.lst "$isoroot/boot/grub/$grub_target/" 2>/dev/null || true

# Both copies tolerate failure, because the .lst glob legitimately matches
# nothing on some GRUB builds -- but "tolerates failure" and "produced nothing"
# have to be told apart. A module directory that silently came out empty gives
# an ISO that builds, boots, and then strands anyone who reaches the GRUB
# prompt with a shell that can barely do anything.
#
# The count is the assertion. GRUB ships over two hundred modules; zero means
# the copy did not happen, whatever the reason.
# A PLAUSIBLE COUNT, not "at least one".
#
# The comment above already knew the right number -- "GRUB ships over two
# hundred modules" -- while the check accepted ONE. A copy that moved a single
# module out of two hundred strands someone at a GRUB prompt exactly as an
# empty directory does, and `-gt 0` calls it a success. "At least one" is a
# positive control wearing an assertion's clothes: it proves the copy HAPPENED,
# not that it COMPLETED.
#
# The real number is 220, measured from three separate ISO builds of this
# tree ("copied 220 GRUB modules"), so the comment's "over two hundred" is
# accurate rather than remembered.
#
# The floor is 100 rather than 220 because it guards against a PARTIAL COPY
# and is not a specification of GRUB's module set -- a future GRUB shipping
# somewhat fewer should not fail an ISO that boots.
mods=$(find "$isoroot/boot/grub/$grub_target" -name '*.mod' | wc -l)
[ "$mods" -ge 100 ] || die "only $mods GRUB modules were copied from $rootfs/usr/lib/grub/$grub_target; GRUB ships over two hundred, so this copy did not complete"
log "copied $mods GRUB modules"

# Extra kernel parameters, baked into every live menu entry.
#
# This exists because a kernel command line CANNOT be supplied from outside the
# ISO. QEMU's -append only applies with -kernel, and an ISO boots through
# firmware and GRUB rather than a kernel QEMU loaded -- so -append is accepted
# and silently ignored, and the parameter never reaches the kernel. The command
# line lives here, in the menu entries, and nowhere else.
#
# The immediate use is automated testing: an installer test needs to trigger a
# run without typing on a serial console, and a parameter the boot script acts
# on is the only way in.
#
#   make iso ISO_CMDLINE_EXTRA="duct.install=1"
#
# The placeholder in grub.cfg.in is written as " @CMDLINE_EXTRA@" INCLUDING the
# leading space, and the space is part of what is replaced. An empty value then
# produces a line byte-identical to one built before this existed, rather than
# one with a trailing space -- which matters because two builds of the same
# packages are meant to produce the same ISO, and a stray space would be a
# difference with no cause anyone could see.
#
# & and | and \ are escaped because kernel parameters contain paths --
# duct.install.disk=/dev/vdb is an ordinary value -- and an unescaped one would
# either break the substitution or be silently mangled by sed.
cmdline_extra=${CMDLINE_EXTRA:-}
if [ -n "$cmdline_extra" ]; then
	log "extra kernel parameters: $cmdline_extra"
	esc=$(printf '%s' "$cmdline_extra" | sed -e 's/[&|\\]/\\&/g')
	cmdline_repl=" $esc"
else
	cmdline_repl=
fi

sed -e "s|@SERIAL@|$serial|g" \
    -e "s| @CMDLINE_EXTRA@|$cmdline_repl|g" \
    "$templates/grub.cfg.in" >"$isoroot/boot/grub/grub.cfg"

# The placeholder must be gone whether or not a value was given. A leftover
# @CMDLINE_EXTRA@ would be passed to the kernel as an unrecognised parameter,
# which the kernel tolerates silently -- so this would not fail, it would just
# quietly not work.
! grep -q '@CMDLINE_EXTRA@' "$isoroot/boot/grub/grub.cfg" ||
	die "the CMDLINE_EXTRA placeholder survived substitution"
chmod 0644 "$isoroot/boot/grub/grub.cfg"

# The marker early-grub.cfg searches for, and the only thing that distinguishes
# this medium from any other filesystem the firmware can see.
cat >"$isoroot/duct/.duct-live" <<EOF
Duct live medium.
kernel $release
grub $grub_target
EOF
chmod 0644 "$isoroot/duct/.duct-live"

# Handed to the authoring stage, which needs the EFI binary's name to build the
# EFI system partition and has no other way to know it.
cat >"$isoroot/../boot.env" <<EOF
EFI_NAME=$efi_name
GRUB_TARGET=$grub_target
KERNEL_RELEASE=$release
SERIAL=$serial
EOF

rm -f "$rootfs/tmp/$efi_name" "$rootfs/tmp/early-grub.cfg"

# The chroot is finished with, so the device nodes go. See above for why they
# were never meant to ship.
for node in $created_nodes; do
	rm -f "$rootfs/dev/$node"
done

log "boot tree ready"
