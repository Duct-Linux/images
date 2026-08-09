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
kernel=$(ls "$rootfs"/boot/vmlinuz-* 2>/dev/null | head -1) || true
[ -n "${kernel:-}" ] || die "no /boot/vmlinuz-* in the rootfs; is the linux package in the manifest?"
release=${kernel##*/vmlinuz-}
log "kernel $release"

[ -x "$rootfs/usr/bin/duct-mkinitramfs" ] || die "duct-mkinitramfs is missing; is duct-live in the manifest?"
[ -x "$rootfs/usr/bin/grub-mkimage" ]     || die "grub-mkimage is missing; is grub in the manifest?"

# GRUB names its own target and there is exactly one, because the package is
# built --with-platform=efi. Reading it back beats hardcoding a table: if the
# grub package is ever built for another architecture, this keeps working.
grub_target=$(ls "$rootfs/usr/lib/grub" 2>/dev/null | head -1) || true
[ -n "${grub_target:-}" ] || die "no GRUB platform directory in $rootfs/usr/lib/grub"
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

sed -e "s/@SERIAL@/$serial/g" "$templates/grub.cfg.in" >"$isoroot/boot/grub/grub.cfg"
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
