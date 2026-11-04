# Command line build of the Radio-86RK core for the Karabas Go, Mini and Mini G: the steps
# and options of the ISE 14.7 Project Navigator (the .xise projects that this Makefile
# replaced). Runs in the ISE VM, see tools/ise/README.md.
#
#   make go|mini|minig     one board: cores, synthesis, implementation, src/<top>.bin
#   make <board>-cores     the Coregen cores of the board: src/ipcore -> src/ipcore_dir
#   make <board>-config    the working copies of <top>.prj / .xst / .ut
#   make <board>-xst       the build up to synthesis (.ngc); earlier steps that are out of date run too
#   make <board>-report    LUTs, slices, block RAMs and the timing result of the last build
#   make clean-<board>     the working directory of the board
#   make clean             all working directories and the generated cores
#
# Inputs per board: <top>.prj (the source list, paths relative to src/), <top>.xst (XST
# options), the .ucf, <top>.ut (BitGen options); the cores of the .prj come from src/ipcore/.
# The tools run in ../build/ise/<board>/, which gets copies of the .prj and .xst with the
# paths seen from there. A step runs again when one of its inputs is newer than its output;
# a release build starts from scratch: tools/ise/guest/build.sh <board>.
# src/<top>.bin is tracked and not removed by clean.
# GNU make 3.81 (the ISE VM image): no .SHELLFLAGS, no .ONESHELL.

ISE_SETTINGS ?= /opt/Xilinx/14.7/ISE_DS/settings64.sh
REGEN_LOG_DIR ?= ../build/logs/coregen
PART = xc6slx25-ftg256-2
BOARDS = go mini minig

TOP_go = radio86rk
TOP_mini = radio86rk_mini
TOP_minig = radio86rk_minig
UCF_go = pins.ucf
UCF_mini = pins_mini.ucf
UCF_minig = pins_minig.ucf

# The working directories, and src/ seen from a working directory.
WORK = ../build/ise
UP = ../../../src

# Implementation options of the former .xise projects, the same for the three boards.
MAP_OPT = -logic_opt off -ol high -t 1 -xt 0 -register_duplication off -r 4 -global_opt off -mt off -ir off -pr off -lc off -power off
PAR_OPT = -ol high -mt off
TRCE_OPT = -v 3 -s 2 -n 3 -fastpaths

SHELL = /bin/bash
# settings64.sh takes its first argument as the installation directory.
XIL = source $(ISE_SETTINGS) $(patsubst %/,%,$(dir $(ISE_SETTINGS))) > /dev/null &&

# The COE files of the cores: coe_file in an .xco is relative to the .xco.
COE := $(shell for x in $(wildcard ipcore/*.xco ipcore/*/*.xco); do \
	c=$$(sed -n 's/^CSET coe_file=//p' $$x | tr -d '\r'); \
	case "$$c" in (""|no_*) ;; (*) echo $$(dirname $$x)/$$c ;; esac; done)
CGP := $(wildcard ipcore/coregen.cgp ipcore/*/coregen.cgp)

# The boards share src/ipcore_dir (and the Coregen logs), so they are built one after the other.
.NOTPARALLEL:

.PHONY: all clean $(BOARDS) $(BOARDS:=-cores) $(BOARDS:=-config) $(BOARDS:=-xst) \
	$(BOARDS:=-report) $(addprefix clean-,$(BOARDS))

all: $(BOARDS)

# $(1) board, $(2) top module, $(3) working directory
define board
SRC_$(1) := $$(shell sed -n 's/^[a-z]* work "\(.*\)"/\1/p' $(2).prj)
XCO_$(1) := $$(patsubst ipcore_dir/%.v,ipcore/%.xco,$$(filter ipcore_dir/%,$$(SRC_$(1))))
SD_$(1) := $$(shell sed -n 's/^-sd {\(.*\)}/\1/p' $(2).xst | tr -d '"')

$(3)/cores.stamp: $$(XCO_$(1)) $(CGP) $(COE)
	mkdir -p $(3)
	$(XIL) REGEN_LOG_DIR=$(REGEN_LOG_DIR) bash ../tools/ise/guest/regen_cores.sh $(2).prj
	touch $$@

$(3)/$(2).prj: $(2).prj
	mkdir -p $(3)
	sed 's#^\([a-z]*\) work "#\1 work "$(UP)/#' $$< > $$@

$(3)/$(2).xst: $(2).xst
	mkdir -p $(3)
	sed 's#"ipcore_dir#"$(UP)/ipcore_dir#g' $$< > $$@

$(3)/$(2).ut: $(2).ut
	mkdir -p $(3)
	cp $$< $$@

$(3)/$(2).ngc: $(3)/$(2).prj $(3)/$(2).xst $(3)/cores.stamp $$(filter-out ipcore_dir/%,$$(SRC_$(1)))
	mkdir -p $(3)/xst/projnav.tmp
	cd $(3) && $(XIL) xst -intstyle ise -ifn $(2).xst -ofn $(2).syr

$(3)/$(2).bin: $(3)/$(2).ngc $(UCF_$(1)) $(3)/$(2).ut
	cd $(3) && $(XIL) ngdbuild -intstyle ise -dd _ngo $$(patsubst %,-sd $(UP)/%,$$(SD_$(1))) -nt timestamp -uc $(UP)/$(UCF_$(1)) -p $(PART) $(2).ngc $(2).ngd
	cd $(3) && $(XIL) map -intstyle ise -p $(PART) -w $(MAP_OPT) -o $(2)_map.ncd $(2).ngd $(2).pcf
	cd $(3) && $(XIL) par -w -intstyle ise $(PAR_OPT) $(2)_map.ncd $(2).ncd $(2).pcf
	cd $(3) && $(XIL) trce -intstyle ise $(TRCE_OPT) -xml $(2).twx $(2).ncd -o $(2).twr $(2).pcf
	cd $(3) && $(XIL) bitgen -intstyle ise -f $(2).ut $(2).ncd

$(2).bin: $(3)/$(2).bin
	cp $$< $$@

$(1): $(2).bin
$(1)-cores: $(3)/cores.stamp
$(1)-config: $(3)/$(2).prj $(3)/$(2).xst $(3)/$(2).ut
$(1)-xst: $(3)/$(2).ngc
$(1)-report:
	@grep -E "Number of (Slice LUTs|occupied Slices|RAMB16BWERs|RAMB8BWERs):" $(3)/$(2)_map.mrp
	@grep -E "constraints? (was|were) met|constraints? not met|Timing Score" $(3)/$(2).par | sort -u
clean-$(1):
	rm -rf $(3)
endef

$(foreach b,$(BOARDS),$(eval $(call board,$(b),$(TOP_$(b)),$(WORK)/$(b))))

clean: $(addprefix clean-,$(BOARDS))
	rm -rf ipcore_dir
