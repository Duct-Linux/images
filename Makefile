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
NAME       := $(if $(REGISTRY),$(REGISTRY)/,)$(IMAGE)

BUILD_ARGS = \
	--build-arg DEBIAN_SNAPSHOT=$(DEBIAN_SNAPSHOT) \
	--build-arg SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
	--build-arg DEBIAN_DIGEST=$(DEBIAN_DIGEST) \
	--build-arg GOLANG_DIGEST=$(GOLANG_DIGEST)

BUILDX = docker buildx build $(BUILD_ARGS) -f $(DOCKERFILE)

.PHONY: build build-multi push shell test pins clean base base-test builder images-test have-repo toolchain chroot chroot-test rust go-image

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
BASE_PACKAGES ?= duct-filesystem linux-headers glibc zlib \
                 gmp mpfr mpc binutils gcc ncurses bash \
                 uutils-coreutils tape

BUILDER_PACKAGES ?= $(BASE_PACKAGES) \
                 m4 bison flex make gawk sed grep findutils diffutils \
                 tar gzip xz bzip2 patch file pkgconf perl texinfo

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
		-t $(NAME):$(TAG) -t $(NAME):latest $(CONTEXT)

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

rust:
	@test -d $(RUST_SOURCES) || \
		{ echo "no Rust tarball at $(RUST_SOURCES) -- see docker/README.md"; exit 1; }
	docker buildx build -f $(CURDIR)/Dockerfile.rust --load \
		--build-context ductrust=$(RUST_SOURCES) \
		--build-context ductpkgs=$(CONTEXT)/packages/out/pkgs \
		--build-arg CHROOT=$(CHROOT_IMAGE):latest \
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
