ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT := $(ROOT)/new-juice.gprj
BUILD_TCL := $(ROOT)/scripts/build.tcl
OUTPUT := $(ROOT)/impl/pnr/new-juice.fs

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
GOWIN_IDE ?= /Applications/GowinIDE.app/Contents/Resources/Gowin_EDA/IDE
GOWIN_ENV := \
	QT_QPA_PLATFORM_PLUGIN_PATH="$(GOWIN_IDE)/plugins/qt/platforms" \
	DYLD_LIBRARY_PATH="$(GOWIN_IDE)/lib" \
	DYLD_FRAMEWORK_PATH="$(GOWIN_IDE)/lib"
else
GOWIN_IDE ?= /opt/Gowin/IDE
GOWIN_ENV :=
endif

GW_SH ?= $(GOWIN_IDE)/bin/gw_sh
OPENFPGALOADER ?= openFPGALoader
PROGRAMMER_BOARD ?= tangnano20k
PROGRAMMER_FLAGS ?= -f
ROM_PROGRAMMER_FLAGS ?= -f --external-flash

DOS2_ROM := $(ROOT)/roms/Nextor-2.1.1.WonderTANG.ROM.bin
DOS2_ROM_BETA := $(ROOT)/roms/Nextor-3.0.0-beta1.WonderTANG.NO_UNDOC.ROM
DOS2_ROM_OFFSET ?= 1048576
FM_ROM := $(ROOT)/roms/16k_fm_opl.bin
FM_ROM_OFFSET ?= 1179648
SFG_ROM := $(ROOT)/roms/SFG01.ROM
# MoonSound fork: the YRW801 wave ROM (2 MB, copyright Yamaha) is NOT included.
# Point YRW801 at your own image; it goes to flash 0x200000.
YRW801 ?= $(ROOT)/roms/yrw801.rom
YRW801_OFFSET ?= 2097152

JT_SUBMODULE_DIRS := \
	$(ROOT)/src/jtopl \
	$(ROOT)/src/jt49 \
	$(ROOT)/src/jt51
JT_REQUIRED_FILES := \
	$(ROOT)/src/jtopl/hdl/jt2413.v \
	$(ROOT)/src/jt49/hdl/jt49.v \
	$(ROOT)/src/jt51/hdl/jt51.v
JT_HDL_INPUTS := $(foreach dir,$(JT_SUBMODULE_DIRS),\
	$(if $(wildcard $(dir)/hdl),$(shell find $(dir)/hdl -maxdepth 1 -type f)))

PROJECT_INPUTS := \
	$(PROJECT) \
	$(shell find $(ROOT)/src -path $(ROOT)/src/jtopl -prune -o -path $(ROOT)/src/jt49 -prune -o -path $(ROOT)/src/jt51 -prune -o -type f -print) \
	$(JT_HDL_INPUTS) \
	$(shell find $(ROOT)/roms -type f)

.DEFAULT_GOAL := all

.PHONY: all init build rebuild program reprogram roms yrw801 check-submodules check-tools check-programmer

all: build

init:
	@cd "$(ROOT)" && git submodule update --init --recursive
	@$(MAKE) --no-print-directory check-submodules

build: $(OUTPUT)

rebuild: check-submodules check-tools
	$(call run-gowin)

program: check-programmer $(OUTPUT)
	@echo "Programming $(OUTPUT) with $(OPENFPGALOADER)"
	@"$(OPENFPGALOADER)" -b "$(PROGRAMMER_BOARD)" \
		$(PROGRAMMER_FLAGS) "$(OUTPUT)"

reprogram: check-programmer
	@if [ ! -f "$(OUTPUT)" ]; then \
		echo "Built bitstream not found: $(OUTPUT)"; \
		echo "Run 'make build' first."; \
		exit 1; \
	fi
	@echo "Reprogramming $(OUTPUT) with $(OPENFPGALOADER)"
	@"$(OPENFPGALOADER)" -b "$(PROGRAMMER_BOARD)" \
		$(PROGRAMMER_FLAGS) "$(OUTPUT)"

beta_roms: check-programmer $(DOS2_ROM) $(FM_ROM) $(SFG_ROM)
	@echo "Programming DOS2 ROM at offset $(DOS2_ROM_OFFSET)"
	@"$(OPENFPGALOADER)" -b "$(PROGRAMMER_BOARD)" \
		$(ROM_PROGRAMMER_FLAGS) -o "$(DOS2_ROM_OFFSET)" "$(DOS2_ROM_BETA)"
	@combined_rom="$$(mktemp -t new-juice-fm-sfg.XXX)"; \
		trap 'rm -f "$$combined_rom"' EXIT; \
		cp "$(FM_ROM)" "$$combined_rom"; \
		dd if="$(SFG_ROM)" of="$$combined_rom" bs=16384 seek=1 \
			conv=notrunc status=none; \
		echo "Programming FM and SFG-01 ROMs at offset $(FM_ROM_OFFSET)"; \
		"$(OPENFPGALOADER)" -b "$(PROGRAMMER_BOARD)" \
			$(ROM_PROGRAMMER_FLAGS) -o "$(FM_ROM_OFFSET)" "$$combined_rom"

roms: check-programmer $(DOS2_ROM) $(FM_ROM) $(SFG_ROM)
	@echo "Programming DOS2 ROM at offset $(DOS2_ROM_OFFSET)"
	@"$(OPENFPGALOADER)" -b "$(PROGRAMMER_BOARD)" \
		$(ROM_PROGRAMMER_FLAGS) -o "$(DOS2_ROM_OFFSET)" "$(DOS2_ROM)"
	@combined_rom="$$(mktemp -t new-juice-fm-sfg.XXX)"; \
		trap 'rm -f "$$combined_rom"' EXIT; \
		cp "$(FM_ROM)" "$$combined_rom"; \
		dd if="$(SFG_ROM)" of="$$combined_rom" bs=16384 seek=1 \
			conv=notrunc status=none; \
		echo "Programming FM and SFG-01 ROMs at offset $(FM_ROM_OFFSET)"; \
		"$(OPENFPGALOADER)" -b "$(PROGRAMMER_BOARD)" \
			$(ROM_PROGRAMMER_FLAGS) -o "$(FM_ROM_OFFSET)" "$$combined_rom"

yrw801: check-programmer
	@if [ ! -f "$(YRW801)" ]; then \
		echo "YRW801 image not found: $(YRW801)"; \
		echo "Set YRW801=/path/to/yrw801.rom (2 MB; not included)."; \
		exit 1; \
	fi
	@echo "Programming the YRW801 wave ROM at offset $(YRW801_OFFSET)"
	@"$(OPENFPGALOADER)" -b "$(PROGRAMMER_BOARD)" \
		$(ROM_PROGRAMMER_FLAGS) -o "$(YRW801_OFFSET)" "$(YRW801)"

check-tools:
	@if [ ! -x "$(GW_SH)" ]; then \
		echo "Gowin command-line tool not found: $(GW_SH)"; \
		echo "Set GOWIN_IDE=/path/to/Gowin/IDE or GW_SH=/path/to/gw_sh."; \
		exit 1; \
	fi

check-submodules:
	@missing=0; \
	for required_file in $(JT_REQUIRED_FILES); do \
		if [ ! -f "$$required_file" ]; then \
			echo "Missing initialized JT submodule file: $$required_file" >&2; \
			missing=1; \
		fi; \
	done; \
	if [ "$$missing" -ne 0 ]; then \
		echo "Run 'make init' to initialize the required git submodules." >&2; \
		exit 1; \
	fi; \
	if git -C "$(ROOT)" rev-parse --git-dir >/dev/null 2>&1; then \
		for submodule in $(JT_SUBMODULE_DIRS); do \
			relative="$${submodule#$(ROOT)/}"; \
			expected="$$(git -C "$(ROOT)" ls-files --stage -- "$$relative" | awk '{print $$2}')"; \
			actual="$$(git -C "$$submodule" rev-parse HEAD 2>/dev/null || true)"; \
			if [ -z "$$expected" ] || [ "$$actual" != "$$expected" ]; then \
				echo "Submodule $$relative is not at its locked commit." >&2; \
				echo "  expected: $${expected:-unknown}" >&2; \
				echo "  actual:   $${actual:-uninitialized}" >&2; \
				echo "Run 'make init' to restore locked submodule revisions." >&2; \
				exit 1; \
			fi; \
			if [ -n "$$(git -C "$$submodule" status --porcelain)" ]; then \
				echo "Submodule $$relative has local modifications." >&2; \
				echo "Commit and pin them explicitly before building." >&2; \
				exit 1; \
			fi; \
		done; \
	fi

check-programmer:
	@if ! command -v "$(OPENFPGALOADER)" >/dev/null 2>&1; then \
		echo "openFPGALoader not found: $(OPENFPGALOADER)"; \
		echo "Install openFPGALoader or set OPENFPGALOADER=/path/to/openFPGALoader."; \
		exit 1; \
	fi

define run-gowin
	@echo "Building new-juice with $(GW_SH)"
	@cd "$(ROOT)" && env $(GOWIN_ENV) NEW_JUICE_ROOT="$(ROOT)" \
		"$(GW_SH)" "$(BUILD_TCL)"
	@echo "Generated $(OUTPUT)"
endef

$(OUTPUT): $(PROJECT_INPUTS) $(BUILD_TCL) | check-submodules check-tools
	$(call run-gowin)
