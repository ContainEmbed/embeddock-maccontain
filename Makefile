# Makefile for generating init.block ext4 filesystem image
#
# init.block is a read-only ext4 image used as the root filesystem for the
# Linux VM. It must contain:
#   /init           - pre-init shim (mounts /proc, then execs vminitd)
#   /sbin/vminitd   - guest init system (kernel arg: init=/init)
#   /usr/bin/vmexec  - guest exec helper
#
# The following mount-point directories are also required for vminitd
# standardSetup() to succeed at runtime:
#   /sys            - sysfs
#   /tmp            - tmpfs
#   /dev            - devtmpfs / parent for devpts
#   /dev/pts        - devpts
#   /proc           - procfs
#   /run            - tmpfs (container rootfs paths: /run/container/<id>/rootfs)
#   /run/container  - prefix for guestRootfsPath
#   /etc            - resolv.conf written here by configureDNS()
#
# Prerequisites (install via Homebrew):
#   brew install e2fsprogs zig

RESOURCES_DIR := src/EmbedDock/Resources
INIT_BLOCK    := $(RESOURCES_DIR)/init.block
VMINITD       := $(RESOURCES_DIR)/vminitd
VMEXEC        := $(RESOURCES_DIR)/vmexec
PRE_INIT      := $(RESOURCES_DIR)/pre-init
PRE_INIT_SRC  := $(RESOURCES_DIR)/pre-init.c

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

# Feature flags must match the minimal set produced by ContainerizationEXT4's
# EXT4.Formatter (see EXT4+Formatter.swift lines 903-907).  The VM kernel may
# not support full ext4 features like metadata_csum, 64bit, or journaling.
#
#   compat:    sparse_super2, ext_attr
#   incompat:  filetype, extents, flex_bg, inline_data
#   ro_compat: large_file, huge_file, extra_isize
MKE2FS_FEATURES := -O ^has_journal,^metadata_csum,^64bit,^resize_inode,^dir_index,^dir_nlink,^orphan_file,sparse_super2,inline_data
MKE2FS_OPTS     := -I 256 -L initfs $(MKE2FS_FEATURES)

# Locate zig for cross-compiling pre-init.
ZIG := $(shell command -v zig 2>/dev/null)

.PHONY: all init-block pre-init clean check-tools

all: init-block

init-block: check-tools $(INIT_BLOCK)

pre-init: $(PRE_INIT)

$(PRE_INIT): $(PRE_INIT_SRC)
	@if [ -z "$(ZIG)" ]; then \
	    echo "Error: zig not found. Install with: brew install zig"; \
	    exit 1; \
	fi
	@echo "==> Cross-compiling pre-init for aarch64-linux"
	$(ZIG) cc --target=aarch64-linux-musl -static -Os -o $@ $<
	@echo "==> pre-init built: $@ ($$(wc -c < $@ | tr -d ' ') bytes)"

check-tools:
	@if [ -z "$(MKE2FS)" ]; then \
	    echo "Error: mke2fs not found. Install with: brew install e2fsprogs"; \
	    exit 1; \
	fi
	@if [ -z "$(DEBUGFS)" ]; then \
	    echo "Error: debugfs not found. Install with: brew install e2fsprogs"; \
	    exit 1; \
	fi

$(INIT_BLOCK): $(VMINITD) $(VMEXEC) $(PRE_INIT)
	@echo "==> Creating empty $(IMAGE_SIZE_MB) MB image: $@"
	dd if=/dev/zero of=$@ bs=1M count=$(IMAGE_SIZE_MB)
	@echo "==> Formatting as ext4 (minimal feature set for VM kernel)"
	$(MKE2FS) -t ext4 $(MKE2FS_OPTS) $@
	@echo "==> Creating directory structure"
	$(DEBUGFS) -w -R "mkdir /sbin" $@
	$(DEBUGFS) -w -R "mkdir /usr" $@
	$(DEBUGFS) -w -R "mkdir /usr/bin" $@
	$(DEBUGFS) -w -R "mkdir /sys" $@
	$(DEBUGFS) -w -R "mkdir /tmp" $@
	$(DEBUGFS) -w -R "mkdir /dev" $@
	$(DEBUGFS) -w -R "mkdir /dev/pts" $@
	$(DEBUGFS) -w -R "mkdir /proc" $@
	$(DEBUGFS) -w -R "mkdir /run" $@
	$(DEBUGFS) -w -R "mkdir /run/container" $@
	$(DEBUGFS) -w -R "mkdir /etc" $@
	@echo "==> Copying guest binaries"
	$(DEBUGFS) -w -R "write $(abspath $(PRE_INIT)) /init" $@
	$(DEBUGFS) -w -R "write $(abspath $(VMINITD)) /sbin/vminitd" $@
	$(DEBUGFS) -w -R "write $(abspath $(VMEXEC)) /usr/bin/vmexec" $@
	@echo "==> init.block created: $@"

clean:
	rm -f $(INIT_BLOCK)

