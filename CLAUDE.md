# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

The Radio-86RK (KR580VM80A, an i8080 clone) core for the Karabas Go, Mini and Mini G boards: Xilinx Spartan-6 XC6SLX25, ISE 14.7 (XST). The machine is the FPGA replica of Dmitry Tselikov (2011, modified BSD, `src/LICENSE.TXT`), ported to Aeon Lite, to ZX UNO by Andy Karpov (rk86-zxuno) and to the Karabas Go by Oleh Chastukhin (header of `src/radio86rk.v`).

The core is not converted to karabas-go-modules: it has no `modules/` submodule and carries its own MCU link and OSD in `src/rtl/mcu` and `src/rtl/osd`.

## Layout

- `src/radio86rk.v` (Go, VGA), `src/radio86rk_mini.v`, `src/radio86rk_minig.v` (HDMI, `src/rtl/hdmi`, PCM5102 DAC): the three tops, each a whole machine (CPU, memory map, ROM select, the loaders, OSD, the board glue).
- `src/rtl`: `k580wm80a.v` (CPU), `k580wt57.v` (DMA), `k580wg75.v` (CRT), `k580ww55.v` (PPI), `rk_video.v`, `rk_kbd.v`, `loader.v` (writes the ROMs and the tape image into the memory), `macros.v` (types the keys that start a loaded tape image), `mcu/` (`mcu.vhd`, `burst_rx.vhd`, `soft_switches.vhd`, `hid_parser.vhd`, `usb_ps2_lut.vhd`), `osd/`, `spi/`, `video/`, `dac/`, `adc/`.
- `src/ipcore_dir`: Coregen cores (`pll`, `pllx5`, `queue`, `rambuffer`, `font`, `osd_vram`, ...). `src/roms`: `BIOS.BIN`, `BIOSSD.BIN`, `FONT.BIN` with their `.coe`.
- `pk/`: a set of tape images (`.RKR`, `.GAM`) for the SD card. `readme.txt`: the keys (older `WIN+` names; the json uses `Menu+`).
- `src/sim`: `run_burst_sim.sh` (ISim, `tb_mcu_burst.vhd`: the link with bursts at 16 and 32 MHz; `queue_sim.vhd` is a behavioural model of the Coregen fifo).

## Build

- ISE GUI projects in `src/`: `Radio-86RK.xise` (Go, top `radio86rk`, `pins.ucf`), `Radio-86RK-mini.xise` (`radio86rk_mini`, `pins_mini.ucf`), `Radio-86RK-minig.xise` (`radio86rk_minig`, `pins_minig.ucf`). `Radio-86RK.tcl` is the exported ISE project script of the Go. There is no Makefile and no build script.
- The bitstreams are `src/radio86rk.bin`, `radio86rk_mini.bin`, `radio86rk_minig.bin` (committed). The ISE outputs land in `src/` next to the sources; `.gitignore` covers most of them.
- `src/make_core.py` is a symlink to `../../karabas-go-tools/make_core/make_core.py` (the tools repo checked out next to this one). It packs `src/core.json` (one file for all boards: the common keys, `boards` for what differs; kgo2, karabas-go-tools `docs/kgo2.md`) with the `.bin` and the ROMs into `src/radio86rk.kg` (`make_core.py core.json radio86rk.kg`, or `--boards <board>` for one board's bitstream), the release file.
- Each release commit is per board: the `.bin`, the `.xise`, the `build` of the json and the root `.kg*` together.

## MCU link and core file

- `mcu.vhd` is a local copy with the burst receiver (`burst_rx.vhd`) and the `CMD_CAPS` answer; generic `BURST_MAX_MHZ` is 32 on the Mini G and 0 (16 MHz) on the Go and Mini.
- Burst pins differ per board: Go `MCU_IO[1]` burst cs_n (PULLUP in the ucf), `MCU_IO[0]` ready; Mini / Mini G `MCU_IO[0]` cs_n (PULLUP), `MCU_IO[1]` ready. Keep the pull-up on cs_n.
- ROMs come from the core file: `roms/BIOSSD.BIN` at 65536 and `roms/BIOS.BIN` at 69632, written by the ROM loader (`ROMLOAD_*` of `mcu`) through `loader.v` into the SRAM (`MA` / `MD`); the OSD switch "ROM" (`rom_sel`) picks one. The SDRAM pins are tied off.
- OSD (`type: osd`, `eeprom_bank` 6): an `FL` item "Tape image" (slot 1, `.rkr,.rk,.gam`, `Menu+T`, no `autoload`) sent through the `FILELOAD_*` ports into the memory; switches Text color, Sound, ROM, Autorun (starts the image after loading); Reset trigger. The `osd` items are the soft switch registers in their order: a new item changes the index of the items after it.
- The three json files differ only in `bitstream`; keep their `osd`, `roms` and `build` in sync.

## Memory

The Claude Code memory of this repo is shared with all karabas-go repos: `~/.claude/projects/<this project>/memory` is a symlink to `../karabas-go-notes` (private repo `andykarpov/karabas-go-notes`, `link.sh` there makes the links). Its `MEMORY.md` is split by repo; commit and push it after every memory change.
