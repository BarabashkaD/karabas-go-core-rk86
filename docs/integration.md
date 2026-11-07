# Using the machine on another platform

This guide is for a platform other than the Karabas boards (for example the Analogue Pocket) that runs the Radio-86RK of this repository: the board-neutral modules `rk86_machine`, `rk86_video` and `rk86_video_stream`, with its own clock, memory, keyboard, sound and display. The rules come from [contract.md](contract.md), cited by section, and from the code, cited by file and line. Each point says whether it is simulated, derived from the code or not checked; a recommendation is marked as one. The Karabas boards run the same modules with `ce` = 1 and `cpu_ready` = 1. `src/rk86_candidate.v` connects the modules as described here; it is described in section 13 and simulated, and the result of its build is in [verification.md](verification.md) (section 3).

## 1. Sources

- `src/rk86_machine.prj` lists the sources, with paths relative to `src/`: `rtl/k580wm80a.v` (CPU), `rtl/k580wt57.v` (DMA), `rtl/k580wg75.v` (CRT), `rtl/k580ww55.v` (PPI), `rtl/rk86_machine.v`, `rtl/rk86_video.v`, `rtl/rk86_video_stream.v`. They are Verilog-2001 without vendor primitives or cores (contract.md, `src/rk86_machine.prj`). The build candidate synthesizes these files and its top, nothing else (section 13).
- The platform provides: the memory (RAM, ROM and their loading), the font ROM, the keyboard adapter, the sound output, the display (a frame buffer), the device of the window A000-BFFF, the reset and the clock enable.
- Data: `src/roms/BIOS.BIN` (2 KB, the stock monitor; the testbenches run it), `src/roms/BIOSSD.BIN` (4 KB, the monitor of the Karabas boards, with the SD card in the window A000-BFFF), `src/roms/FONT.BIN` (1 KB, the font).
- License: modified BSD (`src/LICENSE.TXT`). The CPU, DMA, CRT and PPI are the replica of Dmitry Tselikov (2011); the DMA, CRT and PPI files say "This realization is not fully operational" (`k580wt57.v:16`, `k580wg75.v:16`, `k580ww55.v:18`): they implement what the Radio-86RK uses.
- The sources elaborate unchanged in XST, Quartus Prime Lite 25.1std (synthesis of the build candidate for the Cyclone V 5CEBA4F23C8, checked) and Icarus Verilog 13.0. The testbenches compile them directly, without copies.

## 2. Clock and clock enable

- One clock `clk` and one clock enable `ce` for `rk86_machine` and `rk86_video`. The state of both advances only on the `clk` edges where `ce` is 1; any pattern of `ce` gives the behaviour of `ce` = 1, counted in `ce` cycles (contract.md, `rk86_machine`, **Clock enable and memory ready**; simulated with `ce` on 160 of 297 `clk` and with a pseudo-random `ce`).
- The native speed is 40 million `ce` cycles per second on average: the CPU steps once in 28 `ce` cycles, `cce` comes once in 18, a dot takes 3, a line 1548, a frame 959 760 (41.7 Hz). The Karabas boards run `clk` at 40 MHz with `ce` = 1; another platform can run its own clock with a pattern, e.g. 74.25 MHz with `ce` on 160 of 297 cycles (same section).
- `cce` and `pix_ce` of `rk86_video` are already high only on `ce` cycles; a timebase from elsewhere must also advance only on `ce` cycles (same section).
- Timing: constrain `clk` as a single-cycle clock. `ce` can be high on two `clk` edges in a row (160 of 297 is), the video counters advance on every `ce` cycle, and after a wait the next CPU step can come 1 `ce` cycle later (same section), so no path is a multicycle path without an analysis that this series did not make. The timing result of the candidate is in [verification.md](verification.md) (The build candidate).
- Recommendation: drive `ce` from a register; it goes to every register of the machine (the candidate does so).

## 3. Reset

- `reset` acts on every `clk` edge while it is high, whatever `ce` is: asynchronous in the CPU, the DMA and the PPI, synchronous in `cpu_cnt`, `cpu_ce2` and `startup`. Hold it for at least one `ce` cycle: the hold registers `dma_we_q`, `crt_we_q` and `crt_rd_q` load only on `ce` cycles (contract.md, **Clock enable and memory ready**; derived, not simulated).
- Release `reset` synchronously to `clk`, from a register of `clk`: it acts asynchronously in the CPU, the DMA and the PPI, and an asynchronous release close to a `clk` edge could free them on different edges, or the synchronous registers on another edge than the asynchronous ones (derived; the usual rule for an asynchronous reset). On the Karabas boards both terms of `reset = ~reset_n | loading` come from registers of `clk50`: `reset_n` (`src/radio86rk.v:333-345`) and `loading` (`src/rtl/loader.v:61`, from the MCU link and the file loader). The candidate releases it from its counter `rst_cnt`, after synchronizing its reset pin and its `loading` input with two registers each. Recommendation: keep such synchronizers of `reset` and `loading` out of shift register (SRL) inference and mark them as synchronizers for the tools; with the default options XST packs a two-register chain into an SRL, and the candidate sets `ASYNC_REG` and `SHREG_EXTRACT = "NO"` on them.
- `hldareg` has no reset; it shifts `hlda` on `ce` cycles (contract.md, section 7). In reset the DMA is idle and `hlda` is 0 (`k580wt57.v:54, 66`), so a reset of at least 11 `ce` cycles clears `hldareg` (derived). Recommendation: hold `reset` for at least 11 `ce` cycles. The candidate holds it for 15 `ce` cycles after its reset pin or its loader.
- The Karabas boards (`src/radio86rk.v:333-345`, the same in the Mini and Mini G tops): `reset_cnt` has no reset and wraps. After power-up (its INIT value 0) `reset_n` is low for 15 `clk`. After a later `cpurst | joy_rst`, `reset_n` is low while that is high and then for 1 to 16 more `clk`, depending on where the counter stopped: 16 after a pulse of one `clk` (derived, not simulated). With `ce` = 1 both are at least 11 `ce` cycles.
- The CRT and `rk86_video` have no reset (contract.md, section 4, **Reset**): the machine reset does not restart the video timebase.
- On the Karabas boards the machine is held in reset while the loader writes the memory: `reset = ~reset_n | loading` (contract.md, section 3).

## 4. Power-up values

- The Karabas builds rely on the INIT values of the FPGA: the registers without a reset start at 0 (contract.md, `rk86_video`, **Native timing and geometry**); XST gives the `ipos` register of the CRT the INIT value 7F. The testbenches set these values (`POWER_UP` in `src/sim/machine/tb_rk86_machine.v`, with `dma_we_q`, `crt_we_q` and `crt_rd_q` at 0). The Karabas SRAM is not cleared at power-up: the ROM loader writes only the ROM images (at 65536 and 69632, `src/core.json`); the testbenches start with a RAM of zeros.
- A platform whose registers start at a known value after configuration, as on the Karabas boards, needs nothing more than the reset of section 3.
- A platform without INIT values, or a simulator that starts with X: the reset defines the CPU, the DMA, the PPI, `cpu_cnt`, `cpu_ce2` and `startup`; the hold registers load during a reset of at least one `ce` cycle; `hldareg` after 11 (section 3). The counters of `rk86_video` come back into their range by themselves: out of range they count up to the width of the register and wrap (`rk86_video.v:60-99`; derived, not simulated). The CRT has no reset; the stock BIOS sends it the reset command and its parameters at boot (`BIOS.BIN` FACF-FADF, contract.md, `rk86_video_stream`, **Why this visible area**). Whether every register of the CRT is defined after that has not been checked: set the values as the testbenches do, or add a reset to the CRT (not done in this series: it would change the netlists of the Karabas boards).

## 5. Memory map and ROM

The address decode of `rk86_machine` uses `cpu_a[15:13]` (`rk86_machine.v:74-94`):

| CPU address | Read | Write |
| --- | --- | --- |
| 0000-7FFF | `mem_di`: RAM, or ROM while `startup` (`rom` high) | the memory (`cpu_wr_n` low) |
| 8000-9FFF | the PPI (keyboard), `cpu_a[1:0]` | the PPI |
| A000-BFFF | `ext_di` (the window) | `ext_we_n` low |
| C000-DFFF | the CRT, `cpu_a[0]` | the CRT |
| E000-FFFF | `mem_di` with `rom` high | the DMA registers, `cpu_a[3:0]` |

- The memory must not take a write while `cpu_a[15]` is 1: those writes go to the PPI, the window, the CRT and the DMA. The Karabas write strobe is `cpu_wr_n | addrbus[15]` (`src/radio86rk.v:355`; contract.md, section 4, **Memory**).
- `rom` is high for a read from the ROM area: E000-FFFF, or 0000-7FFF while `startup` is set. `startup` is set by `reset` and cleared by the first access with A15 high, so the CPU starts at 0000 in the ROM and jumps into the monitor (contract.md, section 4, **Memory**).
- The ROM address is the platform's choice. The Karabas boards (`src/radio86rk.v:358-366`): `BIOSSD.BIN` (4 KB) at `{cpu_a[11] | startup, cpu_a[10:0]}`, so the reads while `startup` go to its upper 2 KB; `BIOS.BIN` (2 KB) at `cpu_a[10:0]`. The testbenches and the candidate use `BIOS.BIN` at `cpu_a[10:0]`.
- The DMA reads the screen from the RAM at `vid_a[14:0]` (the Karabas memory uses these bits, `src/radio86rk.v:352-353`); the stock BIOS puts the screen at 76D0 (contract.md, `rk86_video_stream`, **Geometry**).
- Loading a program on the Karabas boards (`src/rtl/loader.v:95-142`): the loader skips leading E6 bytes, takes the start and the end address (high byte first), writes the bytes from the start to the end address, then writes zeros from 0000 up to the start address, all while the machine is in reset; with Autorun on, `src/rtl/macros.v` then types keys into the keyboard parser. A platform writes the image into the RAM while the machine is in reset and starts it its own way.

## 6. `cpu_ready`

From contract.md, `rk86_machine`, **Clock enable and memory ready**:

- The CPU takes a step on a `clk` edge where its step is pending, `ce` is 1 and `cpu_ready` is 1. A pending step that meets `cpu_ready` = 0 waits; the DMA, the CRT and the timebase do not see `cpu_ready` (simulated).
- `cpu_ready` = 1 promises that `mem_di` (or `ext_di` in the window) holds the data for the current `cpu_a`. It must reflect that on every step, the RAM included (for example by an address tag), because there is no minimum gap between CPU steps: after a wait the next step can come 1 `ce` cycle later (simulated). Drive 1 when there is nothing to wait for; the wait applies to every step, not only to reads.
- `mem_di` is one input for the CPU and the CRT. With `cpu_ready` = 1, as on the Karabas boards, the CPU never steps while `vid_rd` is high, by construction (derived in the same section from the scheduling of the CPU steps and the DMA states, and confirmed by the simulation of the machine). A waiting step can reach the DMA read, so if steps can wait, keep `cpu_ready` low while `vid_rd` is high and use `mem_di = vid_rd ? <DMA port> : <CPU port>` with a memory of two ports (derived, same section). The smoke test of the candidate does not show this rule: with `cpu_ready` not gated by `vid_rd`, the CPU steps that fall into `vid_rd` there are steps that do not read the memory, and no check but a sanity check fails (section 13).
- `cpu_rd`, `cpu_wr_n`, `ext_we_n` and `vid_rd` are levels that last any number of `clk` (more with `ce` = 0, longer during a wait): a device with side effects acts on an edge of them or on `ce` cycles, not by counting `clk`.
- A write starts on a CPU step; a wait can stretch the end of a write into a DMA read, with `cpu_wr_n` still low. A memory may take the write once, or define what its DMA port reads during a write to the same address.
- Examples: `tb_rk86_mem` in `src/sim/machine/tb_rk86_machine.v` (a CPU port with an address tag, a DMA port, random stalls) and the memory of `src/rk86_candidate.v` (a tag, and a slow ROM whose data is there 127 `clk` after the address changes).

## 7. The DMA read window

The DMA address `vid_a` changes on a `cce` edge and holds until the CRT has taken the byte, at least 18 `ce` cycles later; `vid_rd` is high for 36 `ce` cycles before the CRT takes the byte. A DMA port that answers within 17 `clk` needs nothing more; a pattern of `ce` only adds `clk` to the window (contract.md, `rk86_machine`, **Clock enable and memory ready**, and `rk86_video_stream`, **Timing**; simulated with a latency of 1 on both ports).

## 8. Keyboard

- The PPI is the keyboard interface of the original computer (contract.md, section 5): port A drives the rows (`ppa_pa`, a row is selected when its bit is 0), port B reads the columns (`kbd_cols`, a pressed key gives 0), PC5, PC6 and PC7 read `kbd_shift[0]`, `[1]` and `[2]`, active low: `СС` (Shift), `УС` (left Ctrl on the Karabas boards) and `РУС/ЛАТ` (right Ctrl); PC4 reads `tape_in` (`rk86_machine.v:166-168`).
- `kbd_cols[c]` is 0 when a key of column c is pressed in a row r whose `ppa_pa[r]` is 0. The keys of the matrix, as `src/rtl/mcu/hid_parser.vhd:112-184` maps them:

| Row (`ppa_pa` bit) | Col 0 | Col 1 | Col 2 | Col 3 | Col 4 | Col 5 | Col 6 | Col 7 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | `↖` | `СТР` | `АР2` | `F1` | `F2` | `F3` | `F4` | `F5` |
| 1 | `ТАБ` | `ПС` | `ВК` | `ЗБ` | ← | ↑ | → | ↓ |
| 2 | `0` | `1` | `2` | `3` | `4` | `5` | `6` | `7` |
| 3 | `8` | `9` | `:` | - | `,` | `-` | `.` | - |
| 4 | - | `A` | `B` | `C` | `D` | `E` | `F` | `G` |
| 5 | `H` | `I` | `J` | `K` | `L` | `M` | `N` | `O` |
| 6 | `P` | `Q` | `R` | `S` | `T` | `U` | `V` | `W` |
| 7 | `X` | `Y` | `Z` | - | - | - | `^` | space |

  "-" is a position that `hid_parser` leaves without a key. The six keys of the Radio-86RK keyboard that have no PC key (`README.md`: `;`, `/`, `@`, `[`, `\`, `]`) are not placed in this table: their positions have not been checked in this repository.
- On the Karabas boards `ppa_pa` goes to `kbd_cols` combinationally (contract.md, section 5). An adapter that registers the columns has not been checked.
- `karabas_keyboard` converts USB HID reports to the matrix (`hid_parser`), maps the joysticks to the arrows, `ВК` and space (`hid_parser.vhd:307-319`) and types the autorun keys (`macros`); the reset keys and the OSD keys are board functions (`README.md`). A platform keyboard computes the same matrix function and `kbd_shift` from its own keys.

## 9. Sound, tape, interrupts

- The machine has two sound and tape sources at its ports and no mixer: `pc0` (PPI port C bit 0) and `inte` (the interrupt enable of the CPU) (contract.md, `rk86_machine`, ports).
- The Karabas boards mix them differently (contract.md, section 6): the Go drives `BEEPER = (pc0 ^ inte) & sound` (`src/radio86rk.v:131`) and gives its DAC `inte & sound` (`src/radio86rk.v:502-510`); the Mini and the Mini G use `(pc0 ^ inte) & sound`. All three drive `TAPE_OUT = pc0`. A platform picks its own mix; none has been checked outside the Karabas boards.
- `tape_in` is PC4 of the PPI. The Karabas boards connect the `TAPE_IN` pin directly; their tape images are loaded into the memory, not played into `tape_in` (section 5). Recommendation: synchronize an external tape input to `clk`. The testbenches keep `tape_in` at 0.
- No interrupt: the interrupt input of the CPU (`cpu_int`, `rk86_machine.v:66`) has no driver; XST ties it to 0 (Xst:653), the testbenches force it to 0. `inte` is used only as a sound source.

## 10. Video

- `rk86_video` (contract.md, `rk86_video`): the font ROM is outside, `font_addr = {ichar, line[2:0]}` (combinational) and `font_data` (bits 5:0 used); the ROM may answer combinationally or up to 16 `clk` after `font_addr` changes (contract.md, `rk86_video_stream`, **Timing**; simulated with 0, 1 and 16, and 16 with a pattern of `ce`). The font is `src/roms/FONT.BIN`.
- `rk86_video_stream` gives the native dot stream: the dot strobe `ce`, `de`, `dot`, `hs`, `vs`, `line_start`, `frame_start`, `line_end`, `frame_end` (contract.md, `rk86_video_stream`). Sample its outputs on the `clk` edge where its `ce` is high and register them in the `clk` domain before any clock crossing: they are combinational.
- A line is 516 dots (468 with `de`), a frame 620 lines (600 with `de`), 41.7 Hz with 40 million `ce` cycles per second. A display at another rate needs a frame buffer: write `dot` at (`h_cnt`, `v_cnt`) when the stream `ce` and `de` are high (468 x 600, or 468 x 300 with `v_cnt[0] == 0`) and start a buffer frame at `frame_start` (contract.md, **Use on a platform with another display rate**). This repository has no frame buffer for another platform; the candidate only registers the stream.
- Each glyph row is on two adjacent lines; the two lines of a pair are the same unless the CRT state changes between them, as at an end-of-screen code (contract.md, `rk86_video_stream`, **Geometry**; partly derived).
- Geometry (same section): text row k on `v_cnt` 20 k to 20 k + 19, column c on `h_cnt` 24 + 6 c to 29 + 6 c; the text area of the monitor, 64 x 25, is `h_cnt` 72 to 455 and `v_cnt` 60 to 559 (derived); the Karabas framebuffer window is `h_cnt` 60 to 467. Each field attribute code on the screen moves the start of the next frame by one byte with the BIOS DMA count, so the picture drifts; a platform that uses attributes must take this into account (derived, not simulated).
- `hilight`, `lattr` and `gattr` of the machine are not used by `rk86_video` or by the Karabas boards. The picture is monochrome; the Karabas boards choose white or green (`src/radio86rk.v:416-418`).

## 11. The window A000-BFFF

`ext_we_n` is low while the CPU writes to A000-BFFF (`rk86_machine.v:91, 185`), a level not gated by `ce`; the CPU reads `ext_di` in the window (`rk86_machine.v:78`). A device there acts on an edge of `ext_we_n` or on `ce` cycles (section 6), and a slow device (for example a cartridge) can make the CPU wait with `cpu_ready`. On the Karabas boards the window holds the SD card (`src/radio86rk.v:420-444`), used by `BIOSSD.BIN`. The testbenches drive `ext_di` = FF and run `BIOS.BIN`.

## 12. Testbenches to reuse

All run with Icarus Verilog (tested with 13.0) from any directory; their outputs go to `build/sim/` (ignored by git).

- `python -B src/sim/machine/run_machine_sim.py [--iverilog PATH] [--ref-rev REV] [--negative]`: `rk86_machine`, `rk86_video` and `rk86_video_stream` with the stock BIOS from power-up to the keyboard loop, `ce` on 160 of 297 `clk`, a pseudo-random `ce` and random memory stalls against the run with `ce` = 1 (contract.md, `rk86_machine`, **The check**). To check a platform memory, give `--mem <file> [<files it instantiates>...]` with a module `tb_rk86_mem` of the same ports as `src/sim/machine/tb_rk86_mem.v`, its parameter `SYNC` (1: the memory under test; 0: the Karabas combinational model, also instantiated with SYNC 0 as the reference memory in every run, so the platform model must build and behave as that model with SYNC 0 too) and its array `bios`; the checks on every `clk` (no state change on a `clk` edge with `ce` = 0, CPU steps only with `cpu_ready` and never while `vid_rd`) and the comparison with the run of `ce` = 1 stay.
- `python -B src/sim/video/run_video_sim.py [--iverilog PATH] [--ce full|frac|random] [--font-latency N] [--negative]`: `rk86_video` and `rk86_video_stream` with the CRT and the DMA set up as the BIOS does, every output on every dot and the picture against a rendering with `FONT.BIN` (contract.md, `rk86_video_stream`, **The check**).
- `python -B src/sim/candidate/run_candidate_sim.py [--iverilog PATH] [--negative] [--jobs N]`: the build candidate with the BIOS loaded through its loader port (section 13).
- The deliberate faults of `--negative` are unified diffs under `src/sim/<testbench>/negative/`, applied to copies under `build/sim` with `git apply` (`src/sim/negative.py`); each must make its run fail with the error its runner names.
- The testbenches set the power-up values (`POWER_UP`) and force `cpu_int` to 0 (section 4, section 9).

## 13. The build candidate

`src/rk86_candidate.v` is the composition of this guide, in the smallest form that synthesizes:

- the clock enable: `CE_NUM` of `CE_DEN` `clk` (160 of 297), from a register (section 2); with the 40 MHz `clk` of the build the machine runs at 21.5 million `ce` cycles per second, slower than native: the candidate checks the logic, not the speed;
- the reset: the reset pin or the loader (`loading`), each synchronized by two registers, then 15 more `ce` cycles, released from a register (section 3);
- the memory: RAM 0000-7FFF in block RAM with a CPU read/write port and a DMA read port, read latency 1 `clk`; ROM 2 KB and font 1 KB in block RAM; a loader port that writes them while the machine is in reset (`loading` may be asynchronous to `clk`; the write signals are synchronous to it);
- `cpu_ready` = the CPU port holds the data of `{rom, cpu_a}` (an address tag) and, for the ROM, a slow source is ready (its data comes 127 `clk` after the address changes, FF before), and `vid_rd` is low; `mem_di = vid_rd ? <DMA port> : <CPU port>` (section 6);
- `rk86_video` with the font ROM, `rk86_video_stream` registered on its `ce` (section 10); the keyboard, the tape input and the window are pins.

`make -C src candidate` (in the ISE 14.7 VM, [tools/ise/README.md](../tools/ise/README.md)) runs XST, NGDBuild, MAP, PAR and TRCE on the XC6SLX25 with the sources of `src/rk86_machine.prj` and `src/rk86_candidate.v`, `src/rk86_candidate.xst` and `src/rk86_candidate.ucf`; there is no bitstream. Only the `clk` pin is placed: T8, the oscillator pin of the Karabas boards (50 MHz there); the candidate constrains it at 25 ns (PERIOD) to model the 40 MHz machine clock. `make -C src candidate-report` prints the resources and the timing result; the result is in [verification.md](verification.md).

`src/sim/candidate/run_candidate_sim.py` loads the stock BIOS and the font through the loader port and runs 10 frames. It checks that every CPU step that reads the RAM or the ROM gets the byte that the memory of the candidate holds at that address (the promise of `cpu_ready`), that the CPU reaches the keyboard loop of the BIOS (a read of FE63), and that CPU steps wait for the slow ROM. The checks that no step comes without `cpu_ready` or while `vid_rd` are sanity checks: they hold by construction. `--negative` runs two broken variants, each of which must fail by its own check: a `cpu_ready` that does not wait for the ROM (the CPU reads FF and does not reach the keyboard loop) and `cpu_ready` = 1 (wrong read data). Both fail at the first reads from the ROM after the reset, so they do not exercise the address tag of the RAM path: the data check covers that path only in the passing run. A variant with `cpu_ready` not gated by `vid_rd` is not among them: it fails only the sanity check (section 6).

## 14. Known limits

- No hardware test of the clock enable or of `cpu_ready` = 0 on any platform. The Karabas boards tie both to 1; their bitstreams after this series are checked by netlist equivalence, timing reports and simulation, not on the boards yet ([verification.md](verification.md)).
- The CRT and `rk86_video` have no reset and rely on INIT values (section 4).
- The keyboard adapter of the Karabas boards is combinational; a registered one has not been checked (section 8).
- Sound mixing, the frame buffer, the clock crossing to the display and the device of the window belong to the platform; none of them is part of the modules.
- Field attributes make the picture drift; columns 75 to 77 of a row are not shown; the effect of an end-of-screen code on the line pairs is derived from the code (contract.md, `rk86_video_stream`, **Geometry**).
- The timing of the candidate is analysed on the XC6SLX25-2 at 25 ns only (the result: [verification.md](verification.md)); another device or clock needs its own timing analysis (section 2).
- `docs/contract-signals.csv` and `tools/contract/check_contract.py` describe the Karabas tops, not another platform.
