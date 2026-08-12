#!/usr/bin/env bash
# Boot the ISO under QEMU and wait for the live system to say it is up.
#
#   boot-test.sh <iso> <arch>
#
# Every other check on an ISO is a proxy. This one is not: it runs the
# bootloader the build linked, the kernel the build compiled, the initramfs the
# build packed, and PID 1 -- and it only passes when the boot script on the
# other side of switch_root prints that it finished. Each of those five things
# has its own way of failing silently, and none of them are visible in the
# image's headers.
#
# QEMU runs in a container rather than on the host: this needs qemu-system and
# an EDK2 firmware image, and requiring both to be installed on whatever
# machine builds an ISO is a worse trade than a 400 MB image that is built once
# and cached.
#
# There is no KVM here -- the Docker daemon this runs under is itself a virtual
# machine on macOS -- so the guest is emulated and slow. That is why the
# timeout is generous.

set -euo pipefail

iso=${1:?usage: boot-test.sh <iso> <arch>}
arch=${2:?usage: boot-test.sh <iso> <arch>}
timeout_s=${BOOT_TIMEOUT:-900}

# The line the live system's sysinit script prints last. Reaching it means the
# overlay is mounted, switch_root succeeded, and busybox init ran the boot
# script -- which is the whole boot path.
marker=${BOOT_MARKER:-"Duct live system ready"}

# BOOT_GPU=1 gives the guest a DRM device.
#
# Not the default, because the console ISO does not need one and every device
# added to the invocation is another thing that can fail to initialise on a
# runner. It is not optional for anything graphical: a compositor opens a DRM
# node, and on QEMU's arm64 `virt` machine there is no display device at all
# unless one is asked for -- so a session would fail with "no DRM device
# found", which reads as a driver problem and is a missing -device flag.
#
# virtio-gpu-pci on both architectures rather than the x86 default VGA: the
# kernel is built with CONFIG_DRM_VIRTIO_GPU=y and CONFIG_DRM_SIMPLEDRM=y, and
# the emulated VGA has no KMS driver in that set. Same device on both keeps the
# two boots comparable.
gpu=${BOOT_GPU:-}

image=duct/iso-qemu:latest

die() { echo "boot-test: $*" >&2; exit 1; }

[ -f "$iso" ] || die "no such ISO: $iso"

case "$arch" in
	aarch64) qemu_pkg=qemu-system-arm; fw_pkg=qemu-efi-aarch64 ;;
	x86_64)  qemu_pkg=qemu-system-x86; fw_pkg=ovmf ;;
	*) die "no QEMU invocation for $arch" ;;
esac

if ! docker image inspect "$image" >/dev/null 2>&1; then
	echo "boot-test: building $image"
	docker build -t "$image" -f - . <<-EOF
	FROM debian:bookworm-slim
	ENV DEBIAN_FRONTEND=noninteractive
	RUN apt-get update && \\
	    apt-get install -y --no-install-recommends $qemu_pkg $fw_pkg && \\
	    rm -rf /var/lib/apt/lists/*
	EOF
fi

echo "boot-test: booting $iso (up to ${timeout_s}s, emulated)"

# The guest's serial output goes to a file rather than to this terminal so it
# can be searched while the machine is still running -- and so the whole log
# can be printed on failure, which is the only thing that makes a failed boot
# diagnosable.
docker run --rm -i \
	-v "$(cd "$(dirname "$iso")" && pwd)/$(basename "$iso")":/live.iso:ro \
	-e "MARKER=$marker" -e "TIMEOUT=$timeout_s" -e "ARCH=$arch" -e "GPU=$gpu" \
	"$image" bash -s <<'INNER'
set -uo pipefail

case "$ARCH" in
	aarch64)
		fw=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
		set -- qemu-system-aarch64 -machine virt -cpu max ;;
	x86_64)
		fw=/usr/share/ovmf/OVMF.fd
		set -- qemu-system-x86_64 -machine q35 -cpu max ;;
esac
[ -f "$fw" ] || { echo "boot-test: no firmware at $fw" >&2; exit 1; }

# virtio-blk rather than -cdrom, and that is not a stylistic choice: QEMU's
# arm64 `virt` machine has no IDE bus, so -cdrom fails outright with "machine
# type does not support if=ide". Presenting the ISO as a plain block device
# works on both architectures, the firmware reads it through EFI block I/O
# either way, and the kernel has VIRTIO_BLK built in.
#
# -no-reboot so a guest that triple-faults stops instead of looping forever and
# filling the log with the same failed boot.
# -nic none, because QEMU adds a virtio-net device to `virt` by default and
# then refuses to start without the iPXE option ROM for it:
#
#   qemu-system-aarch64: failed to find romfile "efi-virtio.rom"
#
# The ROM lives in a separate Debian package, and installing 30 MB of network
# boot firmware so that a test which does no networking can decline to use it
# is the wrong way round.
# Unquoted on purpose: empty must expand to no argument at all, and one flag
# with an argument must expand to two words.
# shellcheck disable=SC2086
gpu_args=
if [ -n "${GPU:-}" ]; then
	gpu_args="-device virtio-gpu-pci"
	echo "boot-test: adding a virtio GPU"
fi

# shellcheck disable=SC2086
"$@" -m 2048 -bios "$fw" \
	-drive "if=none,id=live,file=/live.iso,format=raw,readonly=on" \
	-device virtio-blk-pci,drive=live \
	$gpu_args \
	-nic none \
	-nographic -no-reboot >/tmp/serial.log 2>&1 &
qemu_pid=$!

found=
for _ in $(seq 1 "$TIMEOUT"); do
	if grep -q "$MARKER" /tmp/serial.log 2>/dev/null; then found=1; break; fi
	# A guest that has exited is not going to print the marker later. Without
	# this the test waits out the full timeout on every crash.
	kill -0 "$qemu_pid" 2>/dev/null || break
	sleep 1
done

kill "$qemu_pid" 2>/dev/null || true
wait "$qemu_pid" 2>/dev/null || true

echo "===== serial console ====="
cat /tmp/serial.log
echo "=========================="

if [ -n "$found" ]; then
	echo "boot-test: reached \"$MARKER\" -- PASS"
	exit 0
fi
echo "boot-test: never reached \"$MARKER\" -- FAIL" >&2
exit 1
INNER
