# Vortex OS top-level build orchestration.
# Every target delegates to a standalone script — each script also runs on its own.
# Host requirements: Docker only (plus qemu-system for `make test`).

VERSION := $(shell cat VERSION)
DIST    := dist

.PHONY: all packages repo pi iso vm test clean help

help:
	@echo "Vortex OS $(VERSION) build targets:"
	@echo "  make packages   Build all Vortex .deb packages (Docker)"
	@echo "  make repo       Publish packages into the signed apt repo tree (aptly)"
	@echo "  make pi         Build vortex-pi-$(VERSION)-arm64.img.xz (pi-gen)"
	@echo "  make iso        Build vortex-$(VERSION)-amd64.iso (live-build)"
	@echo "  make vm         Build vortex-$(VERSION)-amd64.qcow2 + .ova (debos)"
	@echo "  make all        packages + repo + pi + iso + vm"
	@echo "  make test       Run the qemu boot-test harness against built artifacts"
	@echo "  make clean      Remove build outputs"

all: packages repo pi iso vm

packages:
	bash packages/build-all.sh

repo: packages
	bash repo/publish.sh add $(DIST)/debs/*.deb

pi: repo
	bash targets/pi/build.sh

iso: repo
	bash targets/iso/build.sh

vm: repo
	bash targets/vm/build.sh

test:
	bash tools/qemu-test/run-tests.sh

clean:
	rm -rf $(DIST)
