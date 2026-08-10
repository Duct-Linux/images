#!/bin/sh
# Link the GRUB EFI binary for an *installed* system, as opposed to the live
# medium.
#
#   make-disk-boot.sh <rootfs> <outdir> <root-partuuid>
#
# This exists to test one claim: that an installed Duct system needs no
# initramfs. The live path cannot test it, because the live path is the thing
# an installed system does differently -- it finds its root by filesystem
# label, mounts a squashfs, stacks an overlay and switch_roots, and none of
# that happens on a disk.
#
# The difference from make-boot.sh is deliberately small, because the claim
# being tested is that it *is* small:
#
#   - no iso9660, no udf: the medium is a partition, not a disc
#   - the config is embedded whole rather than chaining to /boot/grub/grub.cfg,
#     since a test has one entry and no menu
#   - root=PARTUUID= instead of a duct.live.* label search
#
# Everything else -- the same grub-mkimage from the same package, run under
# chroot so it is Duct's own linker and not the build host's -- is unchanged.

set -eu

rootfs=${1:?usage: make-disk-boot.sh <rootfs> <outdir> <root-partuuid>}
outdir=${2:?usage: make-disk-boot.sh <rootfs> <outdir> <root-partuuid>}
partuuid=${3:?usage: make-disk-boot.sh <rootfs> <outdir> <root-partuuid>}

die() { echo "make-disk-boot: $*" >&2; exit 1; }
log() { echo "make-disk-boot: $*"; }

kernel=$(ls "$rootfs"/boot/vmlinuz-* 2>/dev/null | head -1) || true
[ -n "${kernel:-}" ] || die "no /boot/vmlinuz-* in the rootfs"
release=${kernel##*/vmlinuz-}

grub_target=$(ls "$rootfs/usr/lib/grub" 2>/dev/null | head -1) || true
[ -n "${grub_target:-}" ] || die "no GRUB platform directory"

case "$grub_target" in
	arm64-efi)   efi_name=BOOTAA64.EFI;    serial=ttyAMA0 ;;
	x86_64-efi)  efi_name=BOOTX64.EFI;     serial=ttyS0   ;;
	i386-efi)    efi_name=BOOTIA32.EFI;    serial=ttyS0   ;;
	riscv64-efi) efi_name=BOOTRISCV64.EFI; serial=ttyS0   ;;
	*) die "no removable-media EFI name known for $grub_target" ;;
esac

log "kernel $release, platform $grub_target"

# The live list minus iso9660 and udf. ext2 is not a typo: GRUB's ext2 module
# reads ext3 and ext4 as well, and there is no separate ext4 module to load.
#
# search_fs_uuid and part_gpt earn their place here in a way they do not on the
# ISO -- this is the path that has to find one partition among several on a
# disk that may also carry other operating systems.
grub_modules="part_gpt part_msdos fat ext2 \
	search search_fs_file search_fs_uuid search_label \
	configfile normal linux boot echo test true \
	loadenv minicmd reboot halt sleep ls cat help \
	gzio all_video video video_fb efi_gop terminal"

# Embedded whole, rather than a prefix plus a grub.cfg to be found later. On
# the ISO that indirection buys a menu and a rescue path; here it would only
# add a second thing that can fail to be found, in a test whose subject is
# whether the *first* one can be found at all.
#
# `search --file` rather than --fs-uuid: the marker is written by this build, so
# it is known to exist, whereas a filesystem UUID would have to be read back out
# of the image after mkfs and threaded through two more stages.
#
# console=tty0 before the serial console and not after: CONFIG_VT=y always
# registers tty0, the last console= wins for /dev/console, and getting this
# backwards means every message goes to a virtual terminal nobody is watching.
# NO menuentry HERE, AND THAT IS NOT A SIMPLIFICATION. A config passed to
# grub-mkimage with -c is executed by GRUB's *minimal* shell, which is what runs
# before the `normal` module takes over. `menuentry` is defined BY `normal`, so
# in an embedded config it is not a command at all: GRUB reports
#
#   error: no menuentry definition.
#   Unknown command `}'.
#
# and drops to a prompt -- having loaded every module correctly, which makes it
# read like a module problem when it is a syntax-context problem.
#
# The live ISO never meets this because its embedded config only does `search`
# then `configfile`, and `configfile` enters `normal`, where menus are legal.
# Here there is one entry and no menu to present, so the commands are simply
# run in order: find the partition, load the kernel, boot it.
mkdir -p "$rootfs/tmp/diskgrub"
cat >"$rootfs/tmp/diskgrub/grub.cfg" <<EOF
search --no-floppy --file --set=root /boot/.duct-disk
linux /boot/vmlinuz root=PARTUUID=$partuuid ro console=tty0 console=$serial,115200
boot
EOF

log "linking $efi_name with root=PARTUUID=$partuuid"
# shellcheck disable=SC2086
chroot "$rootfs" /usr/bin/grub-mkimage \
	-O "$grub_target" \
	-o "/tmp/diskgrub/$efi_name" \
	-p /boot/grub \
	-c /tmp/diskgrub/grub.cfg \
	$grub_modules || die "grub-mkimage failed"

mkdir -p "$outdir/esp/EFI/BOOT" "$outdir/root/boot" "$outdir/root/bin" \
         "$outdir/root/sbin" "$outdir/root/dev" "$outdir/root/proc" \
         "$outdir/root/sys"

install -m 0644 "$rootfs/tmp/diskgrub/$efi_name" "$outdir/esp/EFI/BOOT/$efi_name"

# No initramfs is copied, and that absence is the entire point of the test.
install -m 0644 "$kernel" "$outdir/root/boot/vmlinuz"
echo "Duct installed-system boot test, kernel $release" >"$outdir/root/boot/.duct-disk"

# busybox is the only binary on the test root. It is the static one Duct builds
# for the initramfs, reused here because a statically linked shell removes the
# loader from a test that is not about the loader.
busybox=
for cand in "$rootfs/usr/bin/busybox" "$rootfs/bin/busybox"; do
	[ -x "$cand" ] && { busybox=$cand; break; }
done
[ -n "$busybox" ] || die "no busybox in the rootfs; is the busybox package in the manifest?"
install -m 0755 "$busybox" "$outdir/root/bin/busybox"

# What the kernel executes when it has mounted root and has no initramfs to
# hand over to. /sbin/init is the first path it tries.
#
# The marker is printed only after /proc is readable, so it cannot be produced
# by a kernel that reached init without a working root -- there would be no
# /proc to mount and no cmdline to read.
cat >"$outdir/root/sbin/init" <<'EOF'
#!/bin/busybox sh
/bin/busybox mount -t proc  proc /proc
/bin/busybox mount -t sysfs sys  /sys

echo "duct-disk-test: init is PID $$"
echo "duct-disk-test: cmdline: $(/bin/busybox cat /proc/cmdline)"
echo "duct-disk-test: root:    $(/bin/busybox awk '$2=="/" {print $1, $3}' /proc/mounts)"
echo "duct-disk-test: DISK BOOT OK"

/bin/busybox sync
/bin/busybox poweroff -f
EOF
chmod 0755 "$outdir/root/sbin/init"

cat >"$outdir/boot.env" <<EOF
EFI_NAME=$efi_name
GRUB_TARGET=$grub_target
KERNEL_RELEASE=$release
SERIAL=$serial
ROOT_PARTUUID=$partuuid
EOF

rm -rf "$rootfs/tmp/diskgrub"
log "boot tree ready in $outdir"
