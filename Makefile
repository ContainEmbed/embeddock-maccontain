# Makefile for generating init.block ext4 filesystem image
#
# init.block is a read-only ext4 image used as the root filesystem for the
# Linux VM. It must contain:
#   /sbin/vminitd  - guest init system (PID 1, kernel arg: init=/sbin/vminitd)
#   /usr/bin/vmexec - guest exec helper
#
# Prerequisites (install via Homebrew):
#   brew install e2fsprogs

RESOURCES_DIR := src/EmbedDock/Resources
INIT_BLOCK    := $(RESOURCES_DIR)/init.block
VMINITD       := $(RESOURCES_DIR)/vminitd
VMEXEC        := $(RESOURCES_DIR)/vmexec

# Image size must exceed the total size of both binaries + filesystem overhead.
# vminitd (~255 MB) + vmexec (~256 MB) + overhead -> 600 MB
IMAGE_SIZE_MB := 600

# Locate mke2fs / debugfs: prefer system PATH, then Apple Silicon Homebrew,
# then Intel Homebrew.
MKE2FS  := $(shell command -v mke2fs  2>/dev/null \
              || ls /opt/homebrew/opt/e2fsprogs/sbin/mke2fs  2>/dev/null \
              || ls /usr/local/opt/e2fsprogs/sbin/mke2fs     2>/dev/null)
DEBUGFS := $(shell command -v debugfs 2>/dev/null \
              || ls /opt/homebrew/opt/e2fsprogs/sbin/debugfs 2>/dev/null \
              || ls /usr/local/opt/e2fsprogs/sbin/debugfs    2>/dev/null)

.PHONY: all init-block clean check-tools

all: init-block

init-block: check-tools $(INIT_BLOCK)

check-tools:
	@if [ -z "$(MKE2FS)" ]; then \
	    echo "Error: mke2fs not found. Install with: brew install e2fsprogs"; \
	    exit 1; \
	fi
	@if [ -z "$(DEBUGFS)" ]; then \
	    echo "Error: debugfs not found. Install with: brew install e2fsprogs"; \
	    exit 1; \
	fi

$(INIT_BLOCK): $(VMINITD) $(VMEXEC)
	@echo "==> Creating empty $(IMAGE_SIZE_MB) MB image: $@"
	dd if=/dev/zero of=$@ bs=1M count=$(IMAGE_SIZE_MB)
	@echo "==> Formatting as ext4"
	$(MKE2FS) -t ext4 -L initfs $@
	@echo "==> Populating filesystem"
	$(DEBUGFS) -w -R "mkdir /sbin" $@
	$(DEBUGFS) -w -R "mkdir /usr" $@
	$(DEBUGFS) -w -R "mkdir /usr/bin" $@
	$(DEBUGFS) -w -R "write $(abspath $(VMINITD)) /sbin/vminitd" $@
	$(DEBUGFS) -w -R "write $(abspath $(VMEXEC)) /usr/bin/vmexec" $@
	@echo "==> init.block created: $@"

clean:
	rm -f $(INIT_BLOCK)
