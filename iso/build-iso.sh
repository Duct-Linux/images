#!/bin/bash
# Pack a prepared rootfs and boot tree into a bootable hybrid ISO.
#
#   build-iso.sh <rootfs> <isoroot> <boot.env> <output.iso>
#
# Unlike make-boot.sh, nothing here ends up inside the ISO. mksquashfs, xorriso
# and mtools are archivers: they read Duct's files and write a container around
# them, and not one byte of their own code ships. That is the line this build
# draws -- everything the ISO *executes* is built by Duct, and everything that
# merely packs it is whatever the build host has.
#
# It is the same line `docker buildx` sits on for every other image here, and
# it is why these three tools are installed from Debian rather than packaged:
# packaging xorriso means packaging libburn and libisofs, and packaging
# mkfs.vfat means packaging dosfstools, for four programs that never run on a
# Duct machine.

set -euo pipefail

rootfs=${1:?usage: build-iso.sh <rootfs> <isoroot> <boot.env> <output>}
isoroot=${2:?usage: build-iso.sh <rootfs> <isoroot> <boot.env> <output>}
bootenv=${3:?usage: build-iso.sh <rootfs> <isoroot> <boot.env> <output>}
output=${4:?usage: build-iso.sh <rootfs> <isoroot> <boot.env> <output>}

VOLID=${VOLID:-DUCT_LIVE}
COMPRESSION=${COMPRESSION:-zstd}
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-0}

die() { echo "build-iso: $*" >&2; exit 1; }
log() { echo "build-iso: $*"; }

# fake <cmd...> -- run a command with the clock pinned to SOURCE_DATE_EPOCH.
#
# This exists for mtools, and only for mtools. mksquashfs and xorriso both read
# SOURCE_DATE_EPOCH themselves; mtools does not -- or rather, it honours it for
# a file's modification time and then writes the *creation* time and last-access
# date in every FAT directory entry from the actual clock. Two builds of
# identical inputs therefore differ by a handful of bytes inside the EFI system
# partition, intermittently, depending on whether they happened to fall in the
# same two-second window.
#
# Interposing on the clock is a blunt instrument, but the alternative is
# patching timestamp fields inside a FAT image afterwards by searching for
# directory entries -- and a false match there would corrupt the bootloader,
# which is a catastrophic failure mode for a cosmetic gain.
#
# Degrades to running the command directly if faketime is not installed: the
# ISO is still correct, just not bit-identical between runs.
if command -v faketime >/dev/null 2>&1; then
	_faketime_at=$(date -u -d "@${SOURCE_DATE_EPOCH}" +"%Y-%m-%d %H:%M:%S")
	fake() { faketime -f "$_faketime_at" "$@"; }
else
	log "warning: no faketime; the EFI system partition will carry build-time timestamps"
	fake() { "$@"; }
fi

# shellcheck disable=SC1090
. "$bootenv"
: "${EFI_NAME:?boot.env has no EFI_NAME}"

# ---------------------------------------------------------------------------
# The root filesystem
# ---------------------------------------------------------------------------

# -noappend, because mksquashfs *adds to* an existing image by default rather
# than replacing it. A rebuild without it produces an image containing both the
# old tree and the new one, which is not obviously wrong until someone notices
# the ISO growing by 400 MB per build.
#
# Ownership is preserved from the assembled rootfs. Service accounts and the
# live desktop user need their state and home directories to retain the uid/gid
# assigned by post-install.sh.
#
# zstd rather than xz. xz produces an image about 8% smaller and decompresses
# roughly three times slower, and a live ISO decompresses its root filesystem
# continuously, for as long as it is running -- every binary that is started,
# every library that is paged in. The 8% is paid once at build time; the speed
# is paid by the person using it.
# The kernel image and the initramfs are excluded because the ISO already
# carries both, at /boot/vmlinuz and /boot/initramfs.img, where the bootloader
# reads them. Keeping a second copy inside the squashfs costs 40 MB on arm64,
# where the image is uncompressed by necessity -- GRUB's arm64 loader will not
# accept a gzipped one -- and buys nothing: the medium stays mounted at
# /run/live/medium for as long as the system runs, so the running kernel's own
# image is still there to be read.
#
# System.map, the config and the device trees are small and stay: they are what
# anything inspecting the running kernel wants, and /usr/lib/modules is in the
# squashfs regardless.
#
# The glob covers the /boot/vmlinuz symlink as well as its target. Excluding
# only the target would leave a dangling link behind.
#
# There is no -mkfs-time here and there must not be: mksquashfs reads
# SOURCE_DATE_EPOCH from the environment by itself and refuses outright --
# "SOURCE_DATE_EPOCH and command line options can't be used at the same time to
# set timestamp(s)" -- if it is also given the flag. The environment variable is
# the better of the two anyway, because it clamps every file's mtime rather
# than only the superblock's.
log "squashing the root filesystem with $COMPRESSION"
mkdir -p "$isoroot/duct"
mksquashfs "$rootfs" "$isoroot/duct/rootfs.squashfs" \
	-noappend \
	-comp "$COMPRESSION" \
	-b 1M \
	-no-progress \
	-wildcards \
	-e 'boot/vmlinuz*' 'boot/initramfs.img' ||
	die "mksquashfs failed"

# ---------------------------------------------------------------------------
# The EFI system partition
# ---------------------------------------------------------------------------

# UEFI cannot boot an EFI binary out of ISO9660. The specification requires the
# El Torito boot image to be a FAT filesystem, so the bootloader has to be
# wrapped in one -- which is what this is, and it is why dosfstools and mtools
# are here at all.
#
# The same image is appended to the ISO as a real partition further down, so
# that a stick written with `dd` presents a genuine EFI system partition to
# firmware that will not look at El Torito on a hard disk.
efi_src=$isoroot/EFI/BOOT/$EFI_NAME
[ -f "$efi_src" ] || die "$efi_src is missing; make-boot.sh did not run"

# Sized from the payload with a megabyte of slack, rounded up: a fixed size
# would either waste space or fail the first time GRUB grew.
#
# The 4 MB floor is what makes it FAT16 rather than FAT12. FAT16 needs at least
# 4085 clusters to be FAT16 at all, and while the UEFI specification permits
# FAT12, firmware that only looks for FAT16 and FAT32 on an EFI system
# partition is common enough that the four megabytes are not worth arguing
# about -- an ESP that a machine declines to read is an ISO that does not boot,
# with no diagnostic beyond a boot menu that never appears.
efi_bytes=$(stat -c %s "$efi_src")
esp_kb=$(( (efi_bytes / 1024) + 1024 ))
[ "$esp_kb" -lt 4096 ] && esp_kb=4096
esp_kb=$(( ((esp_kb + 31) / 32) * 32 ))

esp=$(mktemp -d)/esp.img
log "building a ${esp_kb} KB FAT16 EFI system partition"

# The FAT volume serial. Left alone, mkfs.vfat derives it from the current time
# and the ESP -- and therefore the whole ISO -- differs between two builds of
# identical inputs. It was the only thing that differed, which is exactly the
# sort of one-field drift that makes an image look unreproducible for no reason
# anyone can find.
fat_serial=$(printf '%08x' $(( SOURCE_DATE_EPOCH & 0xFFFFFFFF )))

# -s 1, one 512-byte sector per cluster, and it is required rather than a
# tuning choice. FAT16 is only FAT16 above 4085 clusters; at mkfs.vfat's
# default cluster size a 4 MB image has about 2000 of them, and mkfs.vfat
# refuses the whole request with "Attempting to create a too small or a too
# large filesystem" rather than quietly giving back FAT12.
fake mkfs.vfat -C -F 16 -s 1 -i "$fat_serial" -n DUCTEFI "$esp" "$esp_kb" >/dev/null ||
	die "mkfs.vfat failed"

# mtools reads /etc/mtools.conf and complains about the drive geometry of a
# file it has never seen; this tells it to trust the image.
export MTOOLS_SKIP_CHECK=1
fake mmd -i "$esp" ::/EFI ::/EFI/BOOT || die "cannot create ::/EFI/BOOT"
fake mcopy -i "$esp" "$efi_src" "::/EFI/BOOT/$EFI_NAME" || die "cannot copy the EFI binary"

# ---------------------------------------------------------------------------
# The ISO
# ---------------------------------------------------------------------------

# The invocation is grub-mkrescue's, minus the BIOS half.
#
#   -append_partition 2 0xef        the ESP, as partition 2
#   -appended_part_as_gpt           and described in a GPT, which is what a
#                                   UEFI machine reads from a USB stick
#   -e --interval:appended_partition_2:all::
#                                   the El Torito EFI boot entry, pointing at
#                                   that same appended partition rather than at
#                                   a second copy of it. One image, two ways of
#                                   finding it: optical firmware reads El
#                                   Torito, USB firmware reads the GPT.
#
# -iso-level 3 allows files over 4 GB. The squashfs is not that big today; a
# desktop package set on top of it could be.
#
# Timestamps come from SOURCE_DATE_EPOCH in the environment, which xorriso
# reads by itself -- exactly as mksquashfs does above. Without it the ISO9660
# volume descriptor records the moment the build ran, and two builds of
# identical packages differ in those bytes and in nothing else, which is the
# kind of difference that makes "is this the image we published?" unanswerable.
# There is no --modification-date here on purpose: it would be a second way of
# saying the same thing, and the two could drift apart.
# Every file's mtime, flattened, because ISO9660 records one per directory
# entry and xorriso takes them from the filesystem. SOURCE_DATE_EPOCH fixes the
# volume's own timestamps and nothing else -- so without this the squashfs that
# was written thirty seconds ago carries that moment into the image, and two
# builds of identical packages differ.
#
# -h so a symlink's own timestamp is set rather than its target's being set
# twice.
log "normalising timestamps in the ISO tree"
find "$isoroot" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + || \
	die "could not normalise timestamps"

log "authoring $output"
xorriso -as mkisofs \
	-iso-level 3 \
	-rational-rock \
	-joliet \
	-volid "$VOLID" \
	-append_partition 2 0xef "$esp" \
	-appended_part_as_gpt \
	-e --interval:appended_partition_2:all:: \
	-no-emul-boot \
	-o "$output" \
	"$isoroot" || die "xorriso failed"

rm -rf "$(dirname "$esp")"

log "wrote $output ($(stat -c %s "$output") bytes)"

# A label is not cosmetic here: the initramfs finds the medium by searching for
# it, so an ISO whose volume id does not match what grub.cfg passes on the
# kernel command line boots as far as the initramfs and no further.
xorriso -indev "$output" -toc 2>/dev/null | grep -i "volume id" || true
