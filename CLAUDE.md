# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

The Radio-86RK (KR580VM80A, an i8080 clone) core for the Karabas Go, Mini and Mini G boards: Xilinx Spartan-6 XC6SLX25, ISE 14.7 (XST). The machine is the FPGA replica of Dmitry Tselikov (2011, modified BSD, `src/LICENSE.TXT`), ported to Aeon Lite, to ZX UNO by Andy Karpov (rk86-zxuno) and to the Karabas Go by Oleh Chastukhin (header of `src/radio86rk.v`).

The library karabas-go-modules is the submodule `modules/`; the build takes five legacy files from it (`burst_rx.vhd`, `pcm5102.v`, `dac.vhd`, `dvi.vhd`, `dvi_encoder.vhd`). The core is not converted to the `kg_*` modules: it carries its own MCU link and OSD in `src/rtl/mcu` and `src/rtl/osd`.

## Layout

- `src/radio86rk.v` (Go, VGA), `src/radio86rk_mini.v`, `src/radio86rk_minig.v` (HDMI, `src/rtl/hdmi`, PCM5102 DAC): the three tops, each a whole machine (CPU, memory map, ROM select, the loaders, OSD, the board glue).
- `src/rtl`: `k580wm80a.v` (CPU), `k580wt57.v` (DMA), `k580wg75.v` (CRT), `k580ww55.v` (PPI), `rk_video.v`, `rk_kbd.v`, `loader.v` (writes the ROMs and the tape image into the memory), `macros.v` (types the keys that start a loaded tape image), `mcu/` (`mcu.vhd`, `soft_switches.vhd`, `hid_parser.vhd`, `usb_ps2_lut.vhd`), `osd/`, `spi/`, `video/`, `adc/`.
- `src/ipcore`: the inputs of the Coregen cores (`<core>.xco` + `coregen.cgp`: `pll`, `pllx5`, `queue`, `rambuffer`, `font`, `osd_vram`, `rom_font`); the generated cores go to `src/ipcore_dir` (ignored). COE paths in the `.xco` are relative to the `.xco`. `src/roms`: `BIOS.BIN`, `BIOSSD.BIN`, `FONT.BIN` with their `.coe`.
- `pk/`: a set of tape images (`.RKR`, `.GAM`) for the SD card. `readme.txt`: the keys (older `WIN+` names; the json uses `Menu+`).
- `modules/`: karabas-go-modules as a submodule (absolute HTTPS URL), pinned to a commit; it changes only by an explicit gitlink commit (`git -C modules checkout <sha>`, `git add modules`). Clone with `--recursive`, or `git submodule update --init` in an existing clone.
- `src/sim`: `run_burst_sim.sh` (ISim, `tb_mcu_burst.vhd`: the link with bursts at 16 and 32 MHz; `queue_sim.vhd` is a behavioural model of the Coregen fifo).

## Build

- Board configuration in `src/`: `radio86rk.prj` / `.xst` / `.ut` (Go, `pins.ucf`), `radio86rk_mini.*` (`pins_mini.ucf`), `radio86rk_minig.*` (`pins_minig.ucf`): the source list (paths relative to `src/`), the XST and the BitGen options; MAP / PAR options in `src/Makefile`. No `.xise` projects.
- `bash tools/ise/guest/build.sh go|mini|minig` builds one or more boards from scratch (in parallel) in the ISE 14.7 VM, in a clone or in a host checkout on a shared folder: it removes `build/ise/<board>` and the cores stamp, runs `make cores` in `src/` (the Coregen cores of all boards once, via `regen_cores.sh`), then `make <board>` for each board in parallel (XST, NGDBuild, MAP, PAR, TRCE, BitGen, copy to `src/<top>.bin`). `make -C src <board>-xst|-report|...` runs the build up to that step (the earlier steps that are out of date run too). `tools/ise/README.md`: VM, shared folder, license, reference hashes.
- The tools run in `build/ise/<board>` (the working directory of the tools): the ISE outputs land there, logs in `build/logs/<board>`; `build/` is ignored. `.gitignore` lists folders only.
- The bitstreams are `src/radio86rk.bin`, `radio86rk_mini.bin`, `radio86rk_minig.bin` (committed); a build that changes one leaves it modified for the commit.
- `src/make_core.py` is a symlink to `../../karabas-go-tools/make_core/make_core.py` (the tools repo checked out next to this one). It packs `src/core.json` (one file for all boards: the common keys, `boards` for what differs; kgo2, karabas-go-tools `docs/kgo2.md`) with the `.bin` and the ROMs into `src/radio86rk.kg` (`make_core.py core.json radio86rk.kg`, or `--boards <board>` for one board's bitstream), the release file.
- Each release commit is per board: the `.bin`, the `build` of the json and the root `.kg*` together.

## MCU link and core file

- `mcu.vhd` is a local copy with the burst receiver (`burst_rx.vhd` of `modules/`) and the `CMD_CAPS` answer; generic `BURST_MAX_MHZ` is 32 on the Mini G and 0 (16 MHz) on the Go and Mini.
- Burst pins differ per board: Go `MCU_IO[1]` burst cs_n (PULLUP in the ucf), `MCU_IO[0]` ready; Mini / Mini G `MCU_IO[0]` cs_n (PULLUP), `MCU_IO[1]` ready. Keep the pull-up on cs_n.
- ROMs come from the core file: `roms/BIOSSD.BIN` at 65536 and `roms/BIOS.BIN` at 69632, written by the ROM loader (`ROMLOAD_*` of `mcu`) through `loader.v` into the SRAM (`MA` / `MD`); the OSD switch "ROM" (`rom_sel`) picks one. The SDRAM pins are tied off.
- OSD (`type: osd`, `eeprom_bank` 6): an `FL` item "Tape image" (slot 1, `.rkr,.rk,.gam`, `Menu+T`, no `autoload`) sent through the `FILELOAD_*` ports into the memory; switches Text color, Sound, ROM, Autorun (starts the image after loading); Reset trigger. The `osd` items are the soft switch registers in their order: a new item changes the index of the items after it.
- The three json files differ only in `bitstream`; keep their `osd`, `roms` and `build` in sync.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a symlink to `../karabas-go-notes` (private repo `andykarpov/karabas-go-notes`, `link.sh` there makes the links). Its `MEMORY.md` is split by repo; commit and push it after every memory change.
