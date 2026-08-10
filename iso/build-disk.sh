#!/bin/sh
# Author a bootable GPT disk image from a boot tree, without a loop device.
#
#   build-disk.sh <indir> <boot.env> <out.img>
#
# Every filesystem here is built as a standalone file and then written into the
# disk image at its partition offset. Nothing is mounted, no loop device is
# attached, and no privileged operation is performed -- which is what makes this
# runnable inside an unprivileged container, and on a build host whose kernel is
# not the one being tested.
#
# The two tools that make it possible:
#
#   mkfs.ext4 -d DIR   populates the filesystem from a directory at mkfs time.
#                      Without it, putting files into an ext4 image means
#                      mounting it, which means a loop device and root.
#   mkfs.vfat -C       creates the image file itself; mtools then writes into
#                      it, which is what mtools has always been for.
#
# sfdisk operates on the image file directly, so the partition table is just
# bytes written at the front of a file. `dd ... conv=notrunc` places each
# filesystem at its partition's first sector.

set -eu

indir=${1:?usage: build-disk.sh <indir> <boot.env> <out.img>}
envfile=${2:?usage: build-disk.sh <indir> <boot.env> <out.img>}
out=${3:?usage: build-disk.sh <indir> <boot.env> <out.img>}

die() { echo "build-disk: $*" >&2; exit 1; }
log() { echo "build-disk: $*"; }

# shellcheck disable=SC1090
. "$envfile"
: "${EFI_NAME:?boot.env has no EFI_NAME}"
: "${ROOT_PARTUUID:?boot.env has no ROOT_PARTUUID}"

# A fixed GUID for the ESP as well, so two builds of the same tree produce the
# same bytes. sfdisk would otherwise invent one per run.
ESP_PARTUUID=${ESP_PARTUUID:-11111111-1111-4111-8111-111111111111}
DISK_GUID=${DISK_GUID:-22222222-2222-4222-8222-222222222222}

sector=512
align=2048			# 1 MiB, in sectors

# ---------------------------------------------------------------------------
# Sizes
# ---------------------------------------------------------------------------

# Both filesystems get generous slack. This is a test image, not a shipped one,
# and an ext4 that is a few blocks too small fails at mkfs time with an error
# that reads like a corruption bug.
esp_kb=$(( $(du -sk "$indir/esp" | cut -f1) + 8192 ))
esp_kb=$(( ((esp_kb + 1023) / 1024) * 1024 ))
[ "$esp_kb" -lt 16384 ] && esp_kb=16384

root_kb=$(( $(du -sk "$indir/root" | cut -f1) * 2 + 65536 ))
root_kb=$(( ((root_kb + 1023) / 1024) * 1024 ))

esp_sectors=$(( esp_kb * 1024 / sector ))
root_sectors=$(( root_kb * 1024 / sector ))

esp_start=$align
root_start=$(( esp_start + esp_sectors ))
root_start=$(( ((root_start + align - 1) / align) * align ))

# The backup GPT lives in the last 33 sectors; 1 MiB of tail is plenty and
# keeps the total aligned.
total_sectors=$(( root_start + root_sectors + align ))

log "ESP ${esp_kb} KB at sector $esp_start, root ${root_kb} KB at sector $root_start"

# ---------------------------------------------------------------------------
# The EFI system partition
# ---------------------------------------------------------------------------

esp_img=$(mktemp -d)/esp.img

# FAT16 with 512-byte clusters, not FAT32, and this is the second time the same
# trap has been walked into -- build-iso.sh has the same flags for the same
# reason. A FAT is only valid if its cluster COUNT falls in the band for its
# type: FAT32 wants at least 65525 clusters, and an ESP this small cannot
# provide them at any cluster size. mkfs.vfat warns rather than refusing, and
# the failure surfaces one command later as mtools reporting "Error reading
# FAT" against an image it was just handed -- which reads like a corrupt image
# rather than an impossible geometry.
#
# UEFI accepts FAT12, FAT16 and FAT32 on the ESP, and the ISO's FAT16 ESP is
# proven to boot, so there is nothing to buy here by insisting on FAT32.
mkfs.vfat -C -F 16 -s 1 -n DUCTESP "$esp_img" "$esp_kb" >/dev/null ||
	die "mkfs.vfat failed"

mmd -i "$esp_img" ::/EFI ::/EFI/BOOT || die "cannot create ::/EFI/BOOT"
mcopy -i "$esp_img" "$indir/esp/EFI/BOOT/$EFI_NAME" "::/EFI/BOOT/$EFI_NAME" ||
	die "cannot copy $EFI_NAME into the ESP"

# ---------------------------------------------------------------------------
# The root filesystem
# ---------------------------------------------------------------------------

root_img=$(mktemp -d)/root.img
truncate -s "${root_kb}K" "$root_img"

# -d populates from the staged directory; -U fixes the filesystem UUID so the
# image is reproducible. The PARTUUID the kernel is told to use is a property of
# the partition table, not of this filesystem -- they are different identifiers
# and only the former is resolvable without an initramfs.
mkfs.ext4 -q -F -L DUCTROOT \
	-U 33333333-3333-4333-8333-333333333333 \
	-d "$indir/root" "$root_img" >/dev/null ||
	die "mkfs.ext4 failed"

# ---------------------------------------------------------------------------
# The disk
# ---------------------------------------------------------------------------

rm -f "$out"
truncate -s "$(( total_sectors * sector ))" "$out"

# type= takes GPT type GUIDs by shortcut: U is the EFI System Partition, L is
# "Linux filesystem". uuid= is the *partition* GUID -- the thing the kernel
# resolves root=PARTUUID= against, and the reason this test can name its root
# device before the filesystem on it exists.
sfdisk --quiet --no-tell-kernel "$out" <<EOF
label: gpt
label-id: $DISK_GUID
unit: sectors
first-lba: $align

start=$esp_start,  size=$esp_sectors,  type=U, name="EFI System", uuid=$ESP_PARTUUID
start=$root_start, size=$root_sectors, type=L, name="Duct root",  uuid=$ROOT_PARTUUID
EOF

dd if="$esp_img"  of="$out" bs=$sector seek="$esp_start"  conv=notrunc status=none
dd if="$root_img" of="$out" bs=$sector seek="$root_start" conv=notrunc status=none

rm -rf "$(dirname "$esp_img")" "$(dirname "$root_img")"

# Read the table back rather than trusting the write. sfdisk is being handed a
# script it generated the offsets for, so a mismatch here means the arithmetic
# above is wrong -- which would otherwise surface as a firmware that finds no
# bootable device, an error with no useful detail in it.
log "partition table as written:"
sfdisk --list "$out" | sed 's/^/  /'

# --list prints types and sizes but not partition GUIDs, so the identifier the
# kernel will actually resolve has to be asked for by name.
got=$(sfdisk --part-uuid "$out" 2 2>/dev/null || true)
[ "$(echo "$got" | tr 'A-Z' 'a-z')" = "$(echo "$ROOT_PARTUUID" | tr 'A-Z' 'a-z')" ] ||
	die "partition 2 GUID is '$got', expected '$ROOT_PARTUUID' -- root=PARTUUID= would not resolve"

log "root partition GUID verified: $got"
log "wrote $out ($(( total_sectors * sector / 1048576 )) MiB)"
