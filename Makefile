# Default values for build system.
export V         ?=
export GUI       ?=
export RELEASE   ?=
export ARCH      ?= x64
export VERSION   ?= v0.8.0

# The default build target.
.PHONY: default
default: build

# Disable builtin implicit rules and variables.
MAKEFLAGS += --no-builtin-rules --no-builtin-variables
.SUFFIXES:

# Enable verbose output if $(V) is set.
ifeq ($(V),)
.SILENT:
endif

topdir      := $(PWD)
build_mode  := $(if $(RELEASE),release,debug)
target_json := kernel/arch/$(ARCH)/$(ARCH).json
kernel_elf := penguin-kernel.$(ARCH).elf
stripped_kernel_elf := penguin-kernel.$(ARCH).stripped.elf
kernel_symbols := $(kernel_elf:.elf=.symbols)

PROGRESS   := printf "  \\033[1;96m%8s\\033[0m  \\033[1;m%s\\033[0m\\n"
PYTHON3    ?= python3
CARGO      ?= cargo +nightly
BOCHS      ?= bochs
NM         ?= rust-nm
READELF    ?= readelf
STRIP      ?= rust-strip

export RUSTFLAGS = -Z emit-stack-sizes
CARGOFLAGS += -Z build-std=core,alloc -Z build-std-features=compiler-builtins-mem
CARGOFLAGS += --target $(target_json)
CARGOFLAGS += $(if $(RELEASE),--release,)
TESTCARGOFLAGS += --package penguin-kernel -Z unstable-options
TESTCARGOFLAGS += --config "target.$(ARCH).runner = '$(PYTHON3) $(topdir)/tools/run-qemu.py --arch $(ARCH)'"

export CARGO_FROM_MAKE=1

#
#  Build Commands
#
.PHONY: build
build:
	$(MAKE) initramfs
	$(CARGO) build $(CARGOFLAGS) --manifest-path kernel/Cargo.toml
	cp target/$(ARCH)/$(build_mode)/penguin-kernel $(kernel_elf)

	$(PROGRESS) "NM" $(kernel_symbols)
	$(NM) $(kernel_elf) | rustfilt | awk '{ $$2=""; print $$0 }' > $(kernel_symbols)

	$(PROGRESS) "SYMBOLS" $(kernel_elf)
	$(PYTHON3) tools/embed-symbol-table.py $(kernel_symbols) $(kernel_elf)

	$(PROGRESS) "STRIP" $(stripped_kernel_elf)
	$(STRIP) $(kernel_elf) -o $(stripped_kernel_elf)

.PHONY: initramfs
initramfs: initramfs.bin

.PHONY: buildw
buildw:
	$(CARGO) watch -s "$(MAKE) build"

.PHONY: iso
iso: build
	$(PROGRESS) MKISO penguin.iso
	mkdir -p isofiles/boot/grub
	cp boot/grub.cfg isofiles/boot/grub/grub.cfg
	cp $(stripped_kernel_elf) isofiles/penguin.elf
	grub-mkrescue -o penguin.iso isofiles

.PHONY: run
run: build
	$(PYTHON3) tools/run-qemu.py              \
		--arch $(ARCH)                    \
		$(if $(GUI),--gui,)               \
		$(if $(GDB),--gdb,)               \
		$(if $(QEMU),--qemu $(QEMU),)     \
		$(kernel_elf)

.PHONY: bochs
bochs: iso
	$(BOCHS) -qf boot/bochsrc

.PHONY: test
test:
	$(MAKE) initramfs
	$(CARGO) test $(CARGOFLAGS) $(TESTCARGOFLAGS)

.PHONY: testw
testw:
	$(CARGO) watch -s "$(MAKE) test"

.PHONY: check
check:
	$(CARGO) check $(CARGOFLAGS)

.PHONY: checkw
checkw:
	$(CARGO) watch -s "$(MAKE) check"

.PHONY: docs
docs:
	RUSTFLAGS="-C panic=abort -Z panic_abort_tests" $(CARGO) doc --workspace

.PHONY: lint
lint:
	RUSTFLAGS="-C panic=abort -Z panic_abort_tests" $(CARGO) clippy --fix -Z unstable-options --allow-dirty

.PHONY: print-stack-sizes
print-stack-sizes: build
	$(READELF) --stack-sizes $(kernel_elf) | sort -n | rustfilt

.PHONY: clean
clean:
	$(CARGO) clean
	rm -rf *.elf *.iso *.bin *.symbols isofiles

#
#  Build Rules
#
initramfs.bin: $(wildcard packages/*.py) Makefile
	$(PROGRESS) "BUILD" initramfs.bin
	$(PYTHON3) packages/__init__.py                       \
		--build-dir build/initramfs                   \
		-o initramfs.bin
