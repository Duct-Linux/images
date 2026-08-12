# Duct bootstrap image -- the Debian host that builds the cross toolchain.
#
# The build context is the Duct root, not this directory: the image compiles
# tape from source. Every target below runs buildx from ../ with -f here.

REGISTRY ?=
IMAGE    ?= duct/bootstrap

# The two things that decide what is in the image. Change either and you are
# building a different environment, so both are in the tag.
DEBIAN_SNAPSHOT   ?= 20260801T000000Z
SOURCE_DATE_EPOCH ?= 1785542400

# Base images, pinned by index digest. Refresh with `make pins`.
DEBIAN_DIGEST ?= sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
GOLANG_DIGEST ?= sha256:1a6d4452c65dea36aac2e2d606b01b4a029ec90cc1ae53890540ce6173ea77ac

TAG       ?= bookworm-$(DEBIAN_SNAPSHOT)
PLATFORMS ?= linux/amd64,linux/arm64

CONTEXT    := $(CURDIR)/..
DOCKERFILE := $(CURDIR)/Dockerfile
# Local image names are always duct/<name>, matching every other image here
# (duct/toolchain, duct/chroot, duct/base ...). REGISTRY is only for pushing.
#
# It used to be prepended to IMAGE, which already starts with "duct/", so any
# build with REGISTRY set referred to ghcr.io/duct-linux/duct/bootstrap and
# failed with "not found". Local builds never saw it because REGISTRY is empty
# there; the CI bootstrap did, and had never been run until now.
NAME       := $(IMAGE)
REMOTE     := $(if $(REGISTRY),$(REGISTRY)/$(notdir $(IMAGE)),$(IMAGE))

BUILD_ARGS = \
	--build-arg DEBIAN_SNAPSHOT=$(DEBIAN_SNAPSHOT) \
	--build-arg SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
	--build-arg DEBIAN_DIGEST=$(DEBIAN_DIGEST) \
	--build-arg GOLANG_DIGEST=$(GOLANG_DIGEST)

BUILDX = docker buildx build $(BUILD_ARGS) -f $(DOCKERFILE)

.PHONY: build build-multi push shell test pins clean base base-test builder images-test have-repo toolchain chroot chroot-test rust go-image iso iso-test iso-boot-test iso-run \
	have-desktop-set iso-manifest iso-preflight

# ---------------------------------------------------------------------------
# The cross toolchain. LFS chapter 5, built inside duct/bootstrap.
# ---------------------------------------------------------------------------

TOOLCHAIN_IMAGE ?= duct/toolchain
JOBS            ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

# The tarballs are passed as a named build context rather than through the main
# one. They are 400 MB and never change, so putting them in the build context
# would invalidate every layer on any unrelated edit -- and mounting them
# read-only means a normal toolchain build downloads nothing at all, which is
# what keeps a two-hour compile from dying to a 502 from a GNU mirror.
SOURCES ?= $(HOME)/.cache/duct/sources

toolchain:
	@test -f $(CONTEXT)/packages/pkgs/versions.env || \
		{ echo "no pinned versions -- run: make -C ../distro pin"; exit 1; }
	@test -d $(SOURCES) || \
		{ echo "no source cache at $(SOURCES) -- run: make -C ../distro pin"; exit 1; }
	docker buildx build -f $(CURDIR)/Dockerfile.toolchain --load \
		--build-context ductsources=$(SOURCES) \
		--build-arg DUCT_JOBS=$(JOBS) \
		--build-arg BOOTSTRAP=$(NAME):latest \
		-t $(TOOLCHAIN_IMAGE):latest $(CONTEXT)

CHROOT_IMAGE ?= duct/chroot

# The gate that matters: a compiler, a shell and a libc with no Debian left.
chroot:
	docker buildx build -f $(CURDIR)/Dockerfile.chroot --load \
		--build-context ductsources=$(SOURCES) \
		--build-arg DUCT_JOBS=$(JOBS) \
		--build-arg TOOLCHAIN=$(TOOLCHAIN_IMAGE):latest \
		--build-arg BOOTSTRAP=$(NAME):latest \
		-t $(CHROOT_IMAGE):latest $(CONTEXT)

chroot-test:
	@set -eu; \
	echo '== the toolchain is gone =='; \
	! docker run --rm $(CHROOT_IMAGE):latest test -e /tools || \
		{ echo "/tools survived into the image"; exit 1; }; \
	echo '== gcc and bash are Duct-built =='; \
	docker run --rm $(CHROOT_IMAGE):latest gcc --version | head -1; \
	docker run --rm $(CHROOT_IMAGE):latest bash --version | head -1; \
	echo '== it can compile and run a program =='; \
	docker run --rm $(CHROOT_IMAGE):latest bash -c \
		'echo "int main(void){return 42;}" > /tmp/t.c && gcc /tmp/t.c -o /tmp/t && /tmp/t; \
		 [ $$? -eq 42 ] && echo "compiled and ran correctly"'

# ---------------------------------------------------------------------------
# The Duct-native images, assembled from Duct packages rather than from Debian.
# These need `make -C ../distro repo` to have run first.
# ---------------------------------------------------------------------------

BASE_IMAGE    ?= duct/base
BUILDER_IMAGE ?= duct/builder
TAG_IMAGES    ?= latest

# What each image is. tape resolves dependencies itself, but listing them makes
# the contents of each image a reviewable decision rather than a consequence of
# whatever some recipe happens to depend on.
#
# Every package is in exactly one of the lists below, and the image sets are
# DEFINED as their union. That is deliberate: there is no separate "image set"
# to fall out of sync, so a package cannot be added without choosing whether it
# is build-only or not. Unclassified is not a state this file can represent, so
# nothing has to check for it.
#
# ca-certificates is here rather than bolted onto the ISO set: without a trust
# store tape cannot complete a TLS handshake, so an image missing it can never
# install or update anything from the repository it was built from. It has to
# arrive in the image because it cannot be fetched by a client that does not
# already have it.
BASE_PACKAGES ?= duct-filesystem ca-certificates linux-headers glibc zlib \
                 gmp mpfr mpc binutils gcc ncurses bash \
                 uutils-coreutils tape

# What duct/builder adds and a live medium also runs.
BUILDER_RUNTIME_PACKAGES ?= \
                 m4 bison flex make gawk sed grep findutils diffutils \
                 tar gzip xz bzip2 patch file pkgconf perl texinfo

# Needed to COMPILE things inside duct/builder, and never run on a live medium.
# Reasons, not just names -- a name with no reason gets deleted by the next
# person who cannot see why it is there.
#
#   python   grub's configure refuses to run without an interpreter. It was
#            added because grub built in duct/chroot and FAILED in duct/builder,
#            which is not deducible from the package name or any flag.
#   gettext  msgfmt, for packages that ship translations.
#
# 56 MB of the two on a medium that cannot use them. The cost of carrying build
# tooling is constant; the reason for carrying it never existed. At 243 MB that
# is a fifth of the ISO, and when the desktop manifest lands and the image is
# near 700 MB it is still 56 MB -- by which time nobody will remember to ask.
BUILDER_BUILD_ONLY_PACKAGES ?= python gettext

BUILDER_PACKAGES := $(BASE_PACKAGES) $(BUILDER_RUNTIME_PACKAGES) \
                    $(BUILDER_BUILD_ONLY_PACKAGES)

# Read by .github/workflows/assemble.yml, so the workflow holds no copy of these
# lists at all. One list and one reader, rather than two lists kept equal by
# discipline -- which is what they were, and they had already drifted by three
# packages before anyone noticed.
print-%:
	@echo $($*)

have-repo:
	@test -f $(CONTEXT)/packages/out/repo/repo.db.sig || \
		{ echo "no signed repository -- run: make -C ../distro repo"; exit 1; }

base: have-repo
	docker buildx build -f $(CURDIR)/Dockerfile.base --load \
		--build-arg PACKAGES="$(BASE_PACKAGES)" \
		-t $(BASE_IMAGE):$(TAG_IMAGES) $(CONTEXT)

builder: have-repo
	docker buildx build -f $(CURDIR)/Dockerfile.base --load \
		--build-arg PACKAGES="$(BUILDER_PACKAGES)" \
		-t $(BUILDER_IMAGE):$(TAG_IMAGES) $(CONTEXT)

# Both images have a shell and a compiler, so unlike the two-package slice they
# can simply be asked.
images-test:
	@set -eu; \
	echo '== duct/base =='; \
	docker run --rm $(BASE_IMAGE):$(TAG_IMAGES) /usr/bin/gcc --version | head -1; \
	docker run --rm $(BASE_IMAGE):$(TAG_IMAGES) /usr/bin/bash -c \
		'echo "int main(void){return 0;}" >/tmp/t.c && gcc /tmp/t.c -o /tmp/t && /tmp/t && echo "gcc works"'; \
	docker run --rm $(BASE_IMAGE):$(TAG_IMAGES) /usr/bin/ls --version | head -1; \
	echo '== duct/builder =='; \
	docker run --rm $(BUILDER_IMAGE):$(TAG_IMAGES) /usr/bin/make --version | head -1; \
	docker run --rm $(BUILDER_IMAGE):$(TAG_IMAGES) /usr/bin/perl --version | sed -n 2p

# The gate for the whole assembly pipeline: tape must run inside the image it
# was installed into, and agree about what is there. The image has no shell, so
# the daemon is the container process and the CLI is exec'd alongside it.
base-test:
	@set -eu; \
	cid=$$(docker run -d --entrypoint /usr/bin/taped $(BASE_IMAGE):$(TAG_IMAGES)); \
	trap 'docker rm -f $$cid >/dev/null 2>&1 || true' EXIT; \
	for i in $$(seq 1 50); do \
		docker exec $$cid /usr/bin/tape ping >/dev/null 2>&1 && break; sleep 0.2; \
	done; \
	docker exec $$cid /usr/bin/tape list 2>&1 | grep -v INFO

# ---------------------------------------------------------------------------
# The live ISO.
#
# Unlike duct/base, this is assembled from the *local* signed repository rather
# than the published one. That is not a shortcut: an ISO is normally built from
# packages that have just been built and not yet published, and building one
# should not require a network at all. Point REPO_URL at the server to build
# the published set instead.
# ---------------------------------------------------------------------------

# macOS calls arm64 what Linux calls aarch64, and the package archives, the
# kernel and the GRUB target all use the Linux spelling.
HOST_ARCH := $(shell uname -m)
ifeq ($(HOST_ARCH),arm64)
HOST_ARCH := aarch64
endif

ISO_NAME     ?= duct-live
ISO_VOLID    ?= DUCT_LIVE
# zstd, not xz: a live root filesystem is decompressed continuously for as long
# as the system runs, and zstd reads about three times faster for 8% more size.
ISO_COMP     ?= zstd

# Extra kernel parameters baked into every live menu entry. Empty by default,
# and empty produces a byte-identical ISO to one built without it.
#
# A kernel command line cannot be injected from outside the ISO -- QEMU's
# -append only applies with -kernel, and an ISO boots through firmware and GRUB,
# so -append is silently ignored. This is the only way in.
#
#   make iso ISO_CMDLINE_EXTRA="duct.install=1"
ISO_CMDLINE_EXTRA ?=
ISO_REPO_URL ?= /repo
ISO_OUT      ?= $(CURDIR)/out

LOCAL_REPO := $(CONTEXT)/packages/out/repo

# The public half of whichever key signed the repository above. The local repo
# is signed with the key `make -C ../packages key` generated, not with the
# production one in packages/server -- so this has to follow ISO_REPO_URL.
ISO_KEY_DIR ?= $(CONTEXT)/packages/out/keys

# The package set that ends up on the ISO.
#
# The builder set, plus what it takes to boot: a kernel, a bootloader, the
# static busybox the initramfs is made of, module and mount tools, and the
# live system's own init wiring.
#
# Kept as one overridable variable because this is the seam a desktop package
# set is layered in through -- `make iso ISO_EXTRA_PACKAGES="..."` should be
# the whole of what adding one costs.
#
# The image set MINUS the build-only half, derived rather than restated. The
# builder image and a live medium have different jobs -- one compiles things,
# one boots -- and carrying the compiler's dependencies onto the medium was
# convenience rather than design.
#
# ca-certificates is no longer appended here: it moved into BASE_PACKAGES, where
# it always belonged, because an image without a trust store can never install
# or update anything from the repository it came from and cannot fetch the trust
# store either -- fetching is what needs one.
ISO_BASE_PACKAGES  ?= $(BASE_PACKAGES) $(BUILDER_RUNTIME_PACKAGES)
ISO_BOOT_PACKAGES  ?= bc elfutils busybox kmod util-linux linux grub duct-live

# ---------------------------------------------------------------------------
# The desktop package set: `make iso DESKTOP=1`
#
# THERE IS NO LIST OF PACKAGE NAMES HERE, AND THAT IS THE DESIGN. The set is
# everything the packages tree builds that a console ISO does not already
# carry, read out of ../packages/Makefile at build time.
#
# The previous attempt at this was 69 package names written out here. It was
# correct on the day it was written and 110 packages short of the tree ten days
# later, which is what a snapshot always becomes -- and extending it would only
# reset the clock. A list of TIER names (GRAPHICS_PKGS, GNOME_PKGS, ...) fails
# the same way one level up: an enumeration matches what its author could see,
# so the day a chain adds a list nobody here knows about, the ISO silently
# stops shipping it. ALL_PKGS is the single line every chain already edits when
# it lands a tier, so deriving from it is the only form with nothing to rot.
#
# RUST_LATE_PKGS is unioned in explicitly because ALL_PKGS does not contain it
# -- nor RUST_PKGS nor TAPE_PKGS. Of those three, only librsvg is missing from
# a live medium: uutils-coreutils and tape are already named in BASE_PACKAGES.
# librsvg is the pixbuf loader for SVG, without which the icon theme is a
# directory of files nothing can decode.
#
# Deliberately NO build-only trimming here. Which packages are build-only is
# already decided, once, by BUILDER_BUILD_ONLY_PACKAGES above; a second
# classification in this file would be the same two-lists problem that variable
# exists to remove.
#
# WHAT THIS DOES NOT DO IS FILTER. A package that has merged but not yet
# published makes `tape install` fail, loudly, and that is correct: dropping
# names that do not resolve would produce a green ISO with no shell on it. Run
# `make iso-preflight` for a diagnosis -- it names each package as present,
# one-architecture-only, withdrawn or absent.
PACKAGES_MK   ?= $(CONTEXT)/packages/Makefile
PRINT_VARS_MK := $(CURDIR)/scripts/print-vars.mk

# The value of one variable in the packages Makefile. Recursive (`=`), so it
# runs only when something asks for the desktop set: a console `make iso` never
# executes it and does not need a packages checkout at all.
packages_var = $(shell $(MAKE) --no-print-directory -C $(dir $(PACKAGES_MK)) \
                 -f $(notdir $(PACKAGES_MK)) -f $(PRINT_VARS_MK) print-$(1) 2>/dev/null)

ISO_DESKTOP_PACKAGES = $(filter-out $(ISO_BASE_PACKAGES) $(ISO_BOOT_PACKAGES), \
                         $(call packages_var,ALL_PKGS) \
                         $(call packages_var,RUST_LATE_PKGS))

ISO_EXTRA_PACKAGES ?= $(if $(DESKTOP),$(ISO_DESKTOP_PACKAGES),)
ISO_PACKAGES       ?= $(ISO_BASE_PACKAGES) $(ISO_BOOT_PACKAGES) $(ISO_EXTRA_PACKAGES)

# The kernel is only ever built for one architecture at a time, and an ISO is
# bootable on exactly one. Naming the file after the machine that built it
# keeps two of them from overwriting each other in out/.
ISO_ARCH  ?= $(HOST_ARCH)
ISO_FILE  ?= $(ISO_NAME)-$(ISO_ARCH).iso

# An empty desktop set is the dangerous failure, not a loud one: DESKTOP=1
# would build an ordinary console ISO, pass every check, and be indexed by
# whoever asked for a desktop as one. Every way it can come back empty is a
# reader problem rather than a tree problem -- no packages checkout beside this
# one, a renamed ALL_PKGS, a packages/Makefile that fails to parse -- so this
# refuses rather than continuing, and prints the command that produced nothing.
have-desktop-set:
	@set -eu; \
	test -f "$(PACKAGES_MK)" || { \
		echo "DESKTOP=1 needs the packages tree beside this one; no $(PACKAGES_MK)"; \
		echo "override with: make iso DESKTOP=1 PACKAGES_MK=/path/to/packages/Makefile"; \
		exit 1; }; \
	n=$$(printf '%s\n' $(ISO_DESKTOP_PACKAGES) | grep -c . || true); \
	if [ "$$n" -eq 0 ]; then \
		echo "DESKTOP=1 but the derived package set is empty."; \
		echo "ALL_PKGS came back with nothing. Reproduce with:"; \
		echo "  $(MAKE) -C $(dir $(PACKAGES_MK)) -f $(notdir $(PACKAGES_MK)) -f $(PRINT_VARS_MK) print-ALL_PKGS"; \
		exit 1; \
	fi; \
	echo "==> desktop set: $$n packages derived from $(PACKAGES_MK)"

# What is actually going on the medium. The manifest used to be readable by
# looking at one variable; now that it is derived, printing it is how it stays
# a reviewable decision.
iso-manifest:
	@printf '%s\n' $(ISO_PACKAGES) | sort
	@printf '%s packages\n' "$$(printf '%s\n' $(ISO_PACKAGES) | grep -c .)"

# Is every package in the manifest actually installable, right now?
#
# This is the check that turns "tape install: no such package" into a list of
# names with reasons. It asks the published index, because the index is the
# authority on published-ness -- a merged package is not an installable one,
# and a green publish run is not evidence that any particular package is in it.
iso-preflight:
	@$(CURDIR)/iso/preflight.sh "$(ISO_PREFLIGHT_URL)" $(ISO_PACKAGES)

# Forces the package install to re-run instead of reusing its cached layer.
# Empty by default: iteration on a boot script should not re-download the whole
# manifest. Set it to anything that varies -- `ISO_CACHEBUST=$(date +%s)` --
# when a package has published since the last build, because otherwise the ISO
# is rebuilt around the OLD package set and says nothing about it.
ISO_CACHEBUST ?=

ISO_PREFLIGHT_URL ?= https://repo.duct.dss-net.de

# An ISO built from the PUBLISHED repository needs no local one, and the README
# has documented that invocation since the ISO existed:
#
#   make iso ISO_REPO_URL=https://repo.duct.dss-net.de ISO_KEY_DIR=.../server
#
# It has never worked. `iso` depended on have-repo unconditionally, so the
# command in the README stopped at "no signed repository -- run: make -C
# ../distro repo" before anything was built. Nobody noticed because the local
# workflow builds a repository first and CI does not use this target at all.
#
# So the dependency follows the source, and the build context does too: when
# REPO_URL is an https:// address the repository is downloaded and the mount is
# never read, but buildx still requires the named context to exist -- iso.yml
# already passes an empty directory for exactly this reason, and this makes the
# Makefile do what the workflow does.
ISO_LOCAL_REPO_NEEDED := $(if $(filter http://% https://%,$(ISO_REPO_URL)),,yes)
ISO_REPO_CONTEXT      := $(if $(ISO_LOCAL_REPO_NEEDED),$(LOCAL_REPO),$(ISO_OUT)/.empty-repo)

$(ISO_OUT)/.empty-repo:
	@mkdir -p $@

iso: $(if $(ISO_LOCAL_REPO_NEEDED),have-repo,$(ISO_OUT)/.empty-repo) \
     $(if $(DESKTOP),have-desktop-set) | out
	docker buildx build -f $(CURDIR)/Dockerfile.iso \
		--build-context ductrepo=$(ISO_REPO_CONTEXT) \
		--build-context ductkey=$(ISO_KEY_DIR) \
		--build-arg BOOTSTRAP=$(NAME):latest \
		--build-arg DEBIAN_DIGEST=$(DEBIAN_DIGEST) \
		--build-arg DEBIAN_SNAPSHOT=$(DEBIAN_SNAPSHOT) \
		--build-arg SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
		--build-arg REPO_URL=$(ISO_REPO_URL) \
		--build-arg CACHEBUST=$(ISO_CACHEBUST) \
		--build-arg VOLID=$(ISO_VOLID) \
		--build-arg COMPRESSION=$(ISO_COMP) \
		--build-arg CMDLINE_EXTRA="$(ISO_CMDLINE_EXTRA)" \
		--build-arg PACKAGES="$(ISO_PACKAGES)" \
		--output type=local,dest=$(ISO_OUT) \
		$(CONTEXT)
	@mv $(ISO_OUT)/duct-live.iso $(ISO_OUT)/$(ISO_FILE)
	@echo "==> wrote out/$(ISO_FILE)"

# What can be checked without booting, using nothing but dd.
#
# Reading the image's own headers rather than asking xorriso keeps this
# runnable anywhere -- no container, no tools that are only installed inside
# the ISO build -- and it checks the three things that actually decide whether
# a machine will boot this file:
#
#   the volume id      the initramfs finds the medium by searching for it, so
#                      an ISO whose label does not match what grub.cfg puts on
#                      the kernel command line boots as far as the initramfs
#                      and then stops
#   El Torito          the boot record at sector 17, without which UEFI
#                      firmware will not look for a boot image at all
#   the GPT            what firmware reads instead when the same bytes have
#                      been written to a USB stick
iso-test:
	@set -eu; \
	iso=$(ISO_OUT)/$(ISO_FILE); \
	test -f "$$iso" || { echo "no $$iso -- run: make iso"; exit 1; }; \
	fail=0; \
	printf 'ISO      %s (%s bytes)\n' "$$iso" "$$(wc -c <"$$iso" | tr -d ' ')"; \
	volid=$$(dd if="$$iso" bs=1 skip=32808 count=32 2>/dev/null | tr -d '\0' | sed 's/ *$$//'); \
	printf 'volume   %s' "$$volid"; \
	if [ "$$volid" = "$(ISO_VOLID)" ]; then echo "  ok"; \
	else echo "  MISMATCH (grub.cfg boots $(ISO_VOLID))"; fail=1; fi; \
	if dd if="$$iso" bs=2048 skip=17 count=1 2>/dev/null | grep -q "EL TORITO SPECIFICATION"; then \
		echo "eltorito boot record present  ok"; \
	else echo "eltorito boot record MISSING"; fail=1; fi; \
	if dd if="$$iso" bs=512 skip=1 count=1 2>/dev/null | grep -q "EFI PART"; then \
		echo "gpt      present  ok"; \
	else echo "gpt      MISSING (a USB stick written from this will not boot)"; fail=1; fi; \
	test "$$fail" -eq 0 || { echo "iso-test FAILED"; exit 1; }; \
	echo "iso-test OK"

# The check that is not a proxy for anything: boot the thing and wait for the
# live system to report that it is up. Everything the ISO build produces is on
# that path -- bootloader, kernel, initramfs, overlay, PID 1 -- and every one
# of them can fail in a way the image's headers look fine after.
#
# QEMU runs in a container, so this needs nothing installed on the host. It is
# emulated and therefore slow; BOOT_TIMEOUT=<seconds> if it needs longer.
#   make iso-boot-test BOOT_GPU=1 BOOT_MARKER="..."
#
# forwarded rather than exported, so the two knobs are visible in this file:
# BOOT_GPU gives the guest a DRM device (needed by anything graphical, and by
# nothing the console ISO does), BOOT_MARKER is the line that means success.
iso-boot-test:
	@set -eu; \
	iso=$(ISO_OUT)/$(ISO_FILE); \
	test -f "$$iso" || { echo "no $$iso -- run: make iso"; exit 1; }; \
	BOOT_GPU="$(BOOT_GPU)" BOOT_MARKER="$(BOOT_MARKER)" \
		$(CURDIR)/iso/boot-test.sh "$$iso" $(ISO_ARCH)

# ---------------------------------------------------------------------------
# The installed-system boot path
# ---------------------------------------------------------------------------

# An installed Duct system is meant to boot with NO initramfs: the kernel has
# ext4, the block drivers and the EFI partition parser built in, so it can
# resolve root=PARTUUID= and mount its root unaided. Nothing on the live path
# tests that, because the live path is precisely what an installed system does
# differently -- label search, squashfs, overlay, switch_root.
#
# So this builds the smallest disk that can answer the question and boots it.
# It reuses the ISO's assemble stage, so the kernel and the GRUB binary under
# test are the same artefacts the ISO ships rather than a second build of them.
#
#   make disk && make disk-boot-test
DISK_OUT      ?= $(ISO_OUT)
DISK_FILE     ?= duct-disk-test-$(ISO_ARCH).img
DISK_ROOTFS   ?= duct/iso-rootfs:latest

# Fixed, because the EFI binary has it compiled into its embedded grub.cfg and
# is therefore linked before the partition table exists.
ROOT_PARTUUID ?= 44444444-4444-4444-8444-444444444444

disk-rootfs: have-repo
	docker buildx build -f $(CURDIR)/Dockerfile.iso --target assemble --load \
		--build-context ductrepo=$(LOCAL_REPO) \
		--build-context ductkey=$(ISO_KEY_DIR) \
		--build-arg BOOTSTRAP=$(NAME):latest \
		--build-arg REPO_URL=$(ISO_REPO_URL) \
		--build-arg PACKAGES="$(ISO_PACKAGES)" \
		-t $(DISK_ROOTFS) $(CONTEXT)

disk: disk-rootfs | out
	docker buildx build -f $(CURDIR)/Dockerfile.disk \
		--build-arg ROOTFS=$(DISK_ROOTFS) \
		--build-arg DEBIAN_DIGEST=$(DEBIAN_DIGEST) \
		--build-arg ROOT_PARTUUID=$(ROOT_PARTUUID) \
		--output type=local,dest=$(DISK_OUT) \
		$(CONTEXT)
	@mv $(DISK_OUT)/duct-disk-test.img $(DISK_OUT)/$(DISK_FILE)
	@echo "==> wrote out/$(DISK_FILE)"

# The same QEMU harness the ISO uses -- it takes any raw image and a marker,
# and a disk is as much a block device to it as a disc was.
#
# The marker is printed by the test init AFTER it has mounted /proc and read
# the command line, so it cannot be reached by a kernel that got to init
# without a working root filesystem.
disk-boot-test:
	@set -eu; \
	img=$(DISK_OUT)/$(DISK_FILE); \
	test -f "$$img" || { echo "no $$img -- run: make disk"; exit 1; }; \
	BOOT_MARKER="duct-disk-test: DISK BOOT OK" \
		$(CURDIR)/iso/boot-test.sh "$$img" $(ISO_ARCH)

# Boot it interactively, with qemu on the host. Needs an EDK2 firmware image:
# an EFI-only ISO has nothing for a BIOS to run, so `qemu-system-x86_64`
# without -bios OVMF shows a blank screen and that is the expected behaviour,
# not a bug.
#
#   make iso-run OVMF=/path/to/OVMF.fd
QEMU_MEM ?= 2048
iso-run:
	@set -eu; \
	iso=$(ISO_OUT)/$(ISO_FILE); \
	test -f "$$iso" || { echo "no $$iso -- run: make iso"; exit 1; }; \
	test -n "$(OVMF)" || { echo "set OVMF=/path/to/edk2 firmware"; exit 1; }; \
	drive="-drive if=none,id=live,file=$$iso,format=raw,readonly=on -device virtio-blk-pci,drive=live"; \
	case "$(ISO_ARCH)" in \
	  aarch64) qemu-system-aarch64 -M virt -cpu max -m $(QEMU_MEM) \
	             -bios "$(OVMF)" $$drive -nographic ;; \
	  x86_64)  qemu-system-x86_64 -M q35 -cpu max -m $(QEMU_MEM) \
	             -bios "$(OVMF)" $$drive -nographic ;; \
	  *) echo "no qemu invocation for $(ISO_ARCH)"; exit 1 ;; \
	esac

# Native platform, loaded into the local daemon. This is the one you use.
build:
	$(BUILDX) --load -t $(NAME):$(TAG) -t $(NAME):latest $(CONTEXT)

# Both architectures. A multi-platform result cannot be --load'ed into the
# daemon, so it goes to an OCI archive: that verifies every platform actually
# builds and leaves something you can push or inspect later.
build-multi: out
	$(BUILDX) --platform $(PLATFORMS) \
		--output type=oci,dest=$(CURDIR)/out/duct-bootstrap-$(TAG).oci.tar \
		-t $(NAME):$(TAG) $(CONTEXT)
	@echo "wrote out/duct-bootstrap-$(TAG).oci.tar"

push:
	$(BUILDX) --platform $(PLATFORMS) --push \
		-t $(REMOTE):$(TAG) -t $(REMOTE):latest $(CONTEXT)

out:
	mkdir -p $(CURDIR)/out

shell:
	docker run --rm -it --entrypoint /bin/bash $(NAME):latest

# Build the same package twice in two fresh containers and compare digests.
# This is the acceptance test for the whole image: if these differ, something
# in the environment is still leaking into the output.
#
# The package directory is copied per run and mounted read-write, because
# tape-builder stages work/ and wrap/ inside it. A read-only mount does not
# fail loudly -- it just produces no package.
# tape/dev/ is excluded by tape's "*dev*" gitignore, so the old default
# here could never work from a fresh clone. A real recipe always can.
TEST_PKG ?= $(CONTEXT)/packages/pkgs/m4

test:
	@set -eu; \
	test -d "$(TEST_PKG)" || { echo "missing $(TEST_PKG)"; exit 1; }; \
	rm -rf $(CURDIR)/out/repro-a $(CURDIR)/out/repro-b; \
	for run in a b; do \
		d=$(CURDIR)/out/repro-$$run; \
		mkdir -p "$$d/out"; \
		cp -R "$(TEST_PKG)" "$$d/pkg"; \
		docker run --rm \
			-v "$$d/pkg":/work/pkg \
			-v "$$d/out":/out \
			$(NAME):latest build /work/pkg -o /out >/dev/null; \
		n=$$(ls "$$d/out" | grep -c '\.tape\.tar\.gz$$' || true); \
		test "$$n" -eq 1 || { echo "run $$run produced $$n packages, expected 1"; exit 1; }; \
	done; \
	a=$$(cd $(CURDIR)/out/repro-a/out && shasum -a 256 *.tape.tar.gz | awk '{print $$1}'); \
	b=$$(cd $(CURDIR)/out/repro-b/out && shasum -a 256 *.tape.tar.gz | awk '{print $$1}'); \
	echo "run a: $$a"; \
	echo "run b: $$b"; \
	test "$$a" = "$$b" && echo "REPRODUCIBLE" || { echo "MISMATCH"; exit 1; }

# Print the current index digests so the pins above can be refreshed
# deliberately, as a reviewable change, rather than drifting on their own.
pins:
	@printf 'DEBIAN_DIGEST ?= %s\n' \
		"$$(docker buildx imagetools inspect debian:bookworm-slim --format '{{.Manifest.Digest}}')"
	@printf 'GOLANG_DIGEST ?= %s\n' \
		"$$(docker buildx imagetools inspect golang:1.24-bookworm --format '{{.Manifest.Digest}}')"

clean:
	rm -rf $(CURDIR)/out

# ---------------------------------------------------------------------------
# The Rust cross environment, used only for uutils-coreutils.
# ---------------------------------------------------------------------------

RUST_IMAGE ?= duct/rust

# The Rust tarball comes in as its own build context for the same reason the
# upstream sources do: duct/chroot has no network tooling, and a 168 MB blob has
# no business in the main context.
RUST_SOURCES ?= $(HOME)/.cache/duct/rust

# BUILDER, not CHROOT. Dockerfile.rust builds FROM the BUILDER argument and
# declares no CHROOT at all, so the CHROOT build-arg this target used to pass
# was silently discarded -- buildx does not complain about a build-arg the
# Dockerfile never declares.
#
# It looked correct and worked anyway, because BUILDER's default is the
# published builder image and that is a reasonable base. What it was not was
# retargetable: anyone pointing this at a different image would have watched
# their argument have no effect whatsoever.
#
# Passing BUILDER also brings this target in line with every other one here,
# which build against the locally built images rather than the published ones.
#
# The comment lives outside the recipe deliberately: make expands variables in
# recipe lines, so a ${BUILDER} written inside one is echoed as an empty string
# and the explanation contradicts itself.
rust:
	@test -d $(RUST_SOURCES) || \
		{ echo "no Rust tarball at $(RUST_SOURCES) -- see docker/README.md"; exit 1; }
	docker buildx build -f $(CURDIR)/Dockerfile.rust --load \
		--build-context ductrust=$(RUST_SOURCES) \
		--build-context ductpkgs=$(CONTEXT)/packages/out/pkgs \
		--build-arg BUILDER=$(BUILDER_IMAGE):latest \
		--build-arg BOOTSTRAP=$(NAME):latest \
		-t $(RUST_IMAGE):latest $(CONTEXT)

# ---------------------------------------------------------------------------
# The Go environment, used only for the go package itself.
#
# Go has had no C bootstrap path since 1.20: building the toolchain from source
# needs a working Go, so a pinned upstream release is imported the same way
# rustc is for uutils. Everything the package ships is then compiled by it.
# ---------------------------------------------------------------------------

GO_IMAGE   ?= duct/go
GO_SOURCES ?= $(HOME)/.cache/duct/go

go-image:
	@test -d $(GO_SOURCES) || \
		{ echo "no Go tarball at $(GO_SOURCES) -- fetch go<version>.linux-<arch>.tar.gz from go.dev/dl"; exit 1; }
	docker buildx build -f $(CURDIR)/Dockerfile.go --load \
		--build-context ductgo=$(GO_SOURCES) \
		--build-arg BUILDER=$(BUILDER_IMAGE):latest \
		--build-arg BOOTSTRAP=$(NAME):latest \
		-t $(GO_IMAGE):latest $(CONTEXT)
