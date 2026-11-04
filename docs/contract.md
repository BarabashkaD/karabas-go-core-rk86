# Contract of the machine and of the board tops

## 1. Why

The core serves three Karabas boards: Go, Mini and Mini G. Other platforms may use the same machine later.

Today each of the three tops repeats the same machine code: CPU, DMA, CRT, PPI, memory map, keyboard glue. A fix has to be made three times.

This document fixes the boundaries between a board-neutral machine, the Karabas keyboard and the board top. It lists the invariants that the extraction must keep. The skeletons and the check come first. The boards move to the machine in a later change.

## 2. Modules

`karabas_keyboard` has its body, moved from the three tops without changes; the tops instantiate it. `rk86_machine` is still an interface skeleton with an empty body and is in no build yet.

### `rk86_machine` (`src/rtl/rk86_machine.v`)

It will contain the CPU `k580wm80a`, the DMA `k580wt57`, the CRT `k580wg75`, the PPI `k580ww55`, the CPU clock enable, the `startup` flag, the address decode and the ROM area select. It has no board dependency.

| Group | Ports |
|---|---|
| Clock and reset | `clk`, `reset` (composed by the board) |
| Timebase from the video | `cce`, `hrtc`, `vrtc` |
| CPU side of the memory bus | `cpu_a[15:0]`, `cpu_do[7:0]`, `cpu_rd`, `cpu_wr_n`, `rom`, `startup` |
| DMA side of the memory bus | `vid_a[15:0]`, `vid_rd` |
| Memory read data | `mem_di[7:0]` (to the CPU and to the CRT) |
| Keyboard | `ppa_pa[7:0]` (rows, out), `kbd_cols[7:0]` (columns, in), `kbd_shift[2:0]` (PC7..PC5, in), `tape_in` (PC4, in) |
| Sound and tape sources | `pc0`, `inte` |
| Native video (CRT outputs) | `line[3:0]`, `ochar[6:0]`, `lten`, `vsp`, `rvv`, `hilight`, `lattr[1:0]`, `gattr[1:0]`, `irq` |
| Window A000-BFFF for a board device | `ext_we_n`, `ext_di[7:0]` (the SD card on the Karabas boards) |

`rom` is high for a read from the ROM area: E000-FFFF, or 0000-7FFF while `startup` is set.

The machine needs a timebase provider. It takes `cce`, `hrtc` and `vrtc` as inputs. Today `rk_video` provides them.

### `karabas_keyboard` (`src/rtl/karabas_keyboard.v`)

It contains the conversion of HID reports and joysticks from the MCU to the keyboard matrix of the Radio-86RK (`hid_parser`), and the autorun macros (`macros`). The body is the one of the board tops, moved without changes.

| Group | Ports |
|---|---|
| Clock, reset, OSD | `clk`, `areset`, `osd_act` (the OSD is open: keys go to the OSD) |
| From the MCU | `hid_kb_status[7:0]`, `hid_kb_dat0..5[7:0]`, `joy_l[12:0]`, `joy_r[12:0]` |
| From the machine | `ppa_pa[7:0]` (rows) |
| Autorun | `loading`, `loaded_done`, `enable_autorun` |
| To the machine | `kbd_cols[7:0]`, `kbd_shift[2:0]` |
| To the board | `joy_rst` |

### `src/rk86_machine.prj`

The manifest lists the sources of the machine: `k580wm80a.v`, `k580wt57.v`, `k580wg75.v`, `k580ww55.v` and `rk86_machine.v`. Paths are relative to `src/`. The manifest is in no ISE project. The checker elaborates it with iverilog.

## 3. What stays in the board top

- Memory: the SRAM address and data mux with the priority loader, then video DMA, then CPU. The ROM is at `0x10000 + rom_sel * 0x1000`. The loader (`loader.v`) and the file loader stay here.
- `rk_video`: it uses Xilinx-specific cores (`rambuffer`, Coregen `font`). It also generates the timebase and the output sync. The two parts are split later.
- PLL, MCU link, soft switches, OSD.
- Reset composition: `cpurst | joy_rst` goes through a counter to `reset_n`. Then `reset = ~reset_n | loading`. `areset` is not part of the machine reset.
- SD controller, sound mixing, video output, pin tie-offs.

## 4. Invariants (as is)

The extraction must keep these facts. They are read from the current code.

**Video timebase** (`src/rtl/rk_video.v`)

- `hrtc` (`hr_wg75`) is low while `h_cnt` is 468 to 515 (line 66).
- `vrtc` (`vr_wg75`) is low while `v_cnt` is 600 to 619 (line 67).
- `cce = d_cnt == 0 && state == 2'b01` (line 68).
- The period of `cce` is 18 `clk50` cycles. It is constant. It does not vary per line or in the blanking.
  - `state` cycles 0, 1, 2 on every `clk50` edge (lines 78-82). One step takes 3 cycles.
  - `h_cnt` and `d_cnt` advance only when `state == 0` (line 84).
  - `d_cnt` counts 0 to 5 and wraps at `d_cnt + 1 == 6` (lines 122-125). One `d_cnt` period is 6 steps of 3 cycles.
  - A line is `h_cnt` 0 to 515, that is 516 steps. 516 is a multiple of 6. The line end resets `d_cnt` to 0 (line 102) at the point where it wraps anyway. The period does not break at the line end.
  - `cce` is high for one cycle (when `state == 1`) once per `d_cnt` period.

**CPU clock enable** (`src/radio86rk.v`)

- The CPU clock enable is 1 of 28 cycles: `cpu_cnt` counts 0 to 27 (lines 424-425).
- When `hldareg[10:9]` is `01` (about 10 cycles after `hlda` rises) and the CPU has a read or write active, the CPU gets one extra enable at once (line 422). This re-enable is safe while the `cce` period is greater than 11. The period is 18.
- `hrq` is looped back to `hlda` (line 452: `.hlda(hlda), .hrq(hlda)`).

**Memory**

- Memory read is combinational. `mem_di` is shared by the CPU and the CRT.
- Writes are blocked at A15 (`cpu_wr_n | addrbus[15]`).
- ROM reads happen at 0xxx addresses while `startup` is set. `startup` is set by `reset` and cleared by the first access with A15 high.

**Reset**

- Asynchronous reset in the CPU, the DMA, the PPI and the SD controller.
- Synchronous reset in the CPU clock enable generator.
- `loading` enters `reset` combinationally.
- The CRT and `rk_video` have no reset.

## 5. Keyboard

- Rows, columns and PC5..PC7 are the physical keyboard interface of the original computer.
- `kbd_shift` is active low. Bit 0 (PC5) is both Shift keys. Bit 1 (PC6) is the left Ctrl. Bit 2 (PC7) is the right Ctrl. `hid_parser` produces them.
- `ppa_pa` goes to `kbd_cols` combinationally.
- `macros` (autorun after a file is loaded) lives in `karabas_keyboard`, because it replaces HID data.

## 6. Board differences kept

- Sound on the Go: `inte & sound` at bit 9 (0x200). PC0 is used only on BEEPER.
- Sound on the Mini and Mini G: `(PC0 ^ inte) & sound` at bit 13 (0x2000).
- The Mini G has `audio_mix` unused. Its PCM5102 has no reset.
- The burst pins are swapped: Go has `MCU_IO[1]` as burst cs_n and `MCU_IO[0]` as ready. Mini and Mini G have the reverse.

## 7. Known defects, not fixed in this series

- `hdla`: a typo of `hlda`, unused.
- `rom_a` is 23 bits wide and goes into 21.
- `hldareg` reset is overridden: the shift is outside the `else` branch.
- `WA = 16'b0` goes into a 3-bit port.
- `FT_OE_N` on the Mini: assigned, but not a port (implicit net).
- iverilog findings that ISE accepts: `k580wm80a.v` uses `inte` before its declaration (lines 47 and 49). `k580ww55.v` has an `always` block without a delay (line 29). The checker lists these as known.

## 8. The check

`docs/contract-signals.csv` has one row per signal of the tops. A signal with different parts has one row per part (for example `ppa1_c` bits 0 and 7:1).

| Column | Meaning |
|---|---|
| `signal` | name in the top |
| `bits` | bit range, empty for the whole signal |
| `go`, `mini`, `minig` | `y` when the top has it, `-` when not |
| `boundary` | `machine`, `keyboard`, `video`, `sound`, `memory` or `platform` |
| `target` | where the signal goes, separated by `;` |
| `note` | free text |

Target forms:

- `module.port`: a port of `rk86_machine` or `karabas_keyboard`.
- `planned:`: a port that is planned and not yet in a skeleton.
- `internal:module`: a net that moves inside the module.
- `platform`: stays in the board top.

Run the check from any directory:

```
python tools/contract/check_contract.py [--iverilog PATH]
```

It compares the CSV with the three tops, the skeletons and the manifest. With `--iverilog` it also elaborates the manifest and fails on any diagnostic that is not known.

A change that adds, removes or renames a signal in a top updates the CSV in the same commit.

Limit: the check compares names and widths only. A correctly named net on the wrong port is not caught. Review and the XST warning diff cover that.

Lifetime: the CSV and the checker are removed after the boards are moved to the machine.
