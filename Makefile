BUILD_DIR := build

ASM8080 ?= asm8080
NASM ?= nasm
MKFS_CPM ?= mkfs.cpm
CPMCP ?= cpmcp
PYTHON ?= python3
HXCFE ?= hxcfe

DISKDEFS := $(CURDIR)/cpmtools/diskdefs
CPM_ENV := CPMTOOLSFMT="$(DISKDEFS)"

FDIPL := $(BUILD_DIR)/fdipl80.bin
GATEWAY := $(BUILD_DIR)/gateway86.bin
CPM22 := $(BUILD_DIR)/cpm22_pc98.bin
CBIOS := $(BUILD_DIR)/cbios80.bin
SYSTEM := $(BUILD_DIR)/system.bin

IMG_2DD := $(BUILD_DIR)/pc98_cpm80_2dd.img
IMG_2HD := $(BUILD_DIR)/pc98_cpm80_2hd.img
D88_2DD := $(BUILD_DIR)/pc98_cpm80_2dd.d88
D88_2HD := $(BUILD_DIR)/pc98_cpm80_2hd.d88
HFE_2DD := $(BUILD_DIR)/pc98_cpm80_2dd.hfe
HFE_2HD := $(BUILD_DIR)/pc98_cpm80_2hd.hfe

EXTERNAL_COMMANDS := $(wildcard external/commands/*.COM external/commands/*.com)

.PHONY: all raw d88 hfe clean check-tools check-hxcfe

all: raw d88

raw: $(IMG_2DD) $(IMG_2HD)

d88: $(D88_2DD) $(D88_2HD)

hfe: $(HFE_2DD) $(HFE_2HD)

check-tools:
	@set -e; \
	for t in $(ASM8080) $(NASM) $(MKFS_CPM) $(CPMCP) $(PYTHON); do \
		command -v $$t >/dev/null 2>&1 || { echo "missing required tool: $$t" >&2; exit 1; }; \
	done

check-hxcfe:
	@command -v $(HXCFE) >/dev/null 2>&1 || { \
		echo "missing optional HxC command-line converter: $(HXCFE)" >&2; \
		echo "RAW and D88 images are available with 'make' even without HxC." >&2; \
		exit 1; \
	}

$(BUILD_DIR):
	mkdir -p $@

$(FDIPL): src/fdipl80.asm | $(BUILD_DIR)
	$(NASM) -f bin $< -o $@
	@test "$$(stat -c%s $@)" -eq 512 || { echo "$@: expected 512 bytes" >&2; exit 1; }

$(GATEWAY): src/gateway86.asm | $(BUILD_DIR)
	$(NASM) -f bin $< -o $@
	@test "$$(stat -c%s $@)" -eq 8192 || { echo "$@: expected 8192 bytes" >&2; exit 1; }

$(CPM22): src/cpm22_pc98.asm | $(BUILD_DIR)
	$(ASM8080) $< -o$(basename $@)
	@test "$$(stat -c%s $@)" -eq 5632 || { echo "$@: expected 5632 bytes" >&2; exit 1; }

$(CBIOS): src/cbios80.asm | $(BUILD_DIR)
	$(ASM8080) $< -o$(basename $@)
	@actual=$$(stat -c%s $@); \
	if [ "$$actual" -gt 1536 ]; then \
		echo "$@: assembled size $$actual exceeds 1536-byte BIOS area" >&2; \
		exit 1; \
	fi
	truncate -s 1536 $@

$(SYSTEM): $(FDIPL) $(GATEWAY) $(CPM22) $(CBIOS)
	cat $^ > $@
	@test "$$(stat -c%s $@)" -eq 15872 || { echo "$@: expected 15872 bytes" >&2; exit 1; }

define copy_external_commands
	@if [ -n "$(EXTERNAL_COMMANDS)" ]; then \
		set -e; \
		for f in $(EXTERNAL_COMMANDS); do \
			echo "cpmcp: $$f -> $(1)"; \
			$(CPM_ENV) $(CPMCP) -f $(2) $(1) "$$f" 0:; \
		done; \
	fi
endef

$(IMG_2DD): $(SYSTEM) $(EXTERNAL_COMMANDS) cpmtools/diskdefs | $(BUILD_DIR)
	rm -f $@
	$(CPM_ENV) $(MKFS_CPM) -f cpm80-pc98-2dd -b $(SYSTEM) $@
	$(call copy_external_commands,$@,cpm80-pc98-2dd)

$(IMG_2HD): $(SYSTEM) $(EXTERNAL_COMMANDS) cpmtools/diskdefs | $(BUILD_DIR)
	rm -f $@
	$(CPM_ENV) $(MKFS_CPM) -f cpm80-pc98-2hd -b $(SYSTEM) $@
	$(call copy_external_commands,$@,cpm80-pc98-2hd)

$(D88_2DD): $(IMG_2DD) scripts/raw2d88.py | $(BUILD_DIR)
	$(PYTHON) scripts/raw2d88.py --format 2dd --name "PC98 CPM80 2DD" $< $@

$(D88_2HD): $(IMG_2HD) scripts/raw2d88.py | $(BUILD_DIR)
	$(PYTHON) scripts/raw2d88.py --format 2hd --name "PC98 CPM80 2HD" $< $@

$(HFE_2DD): $(D88_2DD) | check-hxcfe
	$(HXCFE) -finput:"$<" -conv:HXC_HFE -foutput:"$@"

$(HFE_2HD): $(D88_2HD) | check-hxcfe
	$(HXCFE) -finput:"$<" -conv:HXC_HFE -foutput:"$@"

clean:
	rm -rf $(BUILD_DIR)
