# Contract of the machine and of the board tops

## 1. Why

The core serves three Karabas boards: Go, Mini and Mini G. Other platforms may use the same machine later.

Today each of the three tops repeats the same machine code: CPU, DMA, CRT, PPI, memory map, keyboard glue. A fix has to be made three times.

This document fixes the boundaries between a board-neutral machine, the Karabas keyboard and the board top. It lists the invariants that the extraction must keep. The skeletons and the check come first. The boards move to the machine in a later change.

## 2. Modules

`karabas_keyboard` and `rk86_machine` have their bodies, moved from the three tops without changes; the tops instantiate them. `rk86_video` has the native part of `rk_video`, moved without changes; `rk_video` instantiates it.

### `rk86_machine` (`src/rtl/rk86_machine.v`)

It contains the CPU `k580wm80a`, the DMA `k580wt57`, the CRT `k580wg75`, the PPI `k580ww55`, the CPU clock enable, the `startup` flag, the address decode and the ROM area select. It has no board dependency. The body is the one of the board tops, moved without changes; at its start, aliases give the ports the former names of the tops (`clk50`, `mem_o`, `vid_cce`, `vid_hr`, `vid_vr`, `kbd_o`, `TAPE_IN`, `sd_o`), so that the moved code is unchanged.

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

The machine needs a timebase provider. It takes `cce`, `hrtc` and `vrtc` as inputs. Today `rk86_video` provides them (inside `rk_video` on the Karabas boards).

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

### `rk86_video` (`src/rtl/rk86_video.v`)

It contains the native video of the Radio-86RK: the timebase of the CRT (`state`, `h_cnt`, `v_cnt`, `d_cnt`; `cce`, `hrtc`, `vrtc`) and the dot shift register of the glyph row (`data`, with `lten`, `vsp`, `rvv`). It has no board dependency and no vendor primitive: the font ROM is outside, on `font_addr` / `font_data`. The body is the one of `rk_video`, moved without changes; aliases give the ports the former names (`hr_wg75`, `vr_wg75`, `fdata`).

| Group | Ports |
|---|---|
| Clock | `clk` |
| From the CRT | `line[3:0]` (bits 2:0 used), `ichar[6:0]`, `vsp`, `lten`, `rvv` |
| Timebase to the CRT | `cce`, `hrtc`, `vrtc` (combinational from the counters) |
| Font ROM | `font_addr[9:0]` = `{ichar, line[2:0]}` (out, combinational), `font_data[7:0]` (in, bits 5:0 used): the ROM answers one `clk` later |
| Native picture | `pix_ce` (`state == 0`, one `clk` of 3), `pix` (the dot, `data[5]`), `h_cnt[10:0]` (0 to 515), `v_cnt[10:0]` (0 to 619) |

A board samples `pix`, `h_cnt` and `v_cnt` on the `clk` edge where `pix_ce` is high; all three change at that edge. `rk86_video` is not in `docs/contract-signals.csv`: it sits inside `rk_video`, and its ports are not signals of the tops.

**Native timing and geometry**

- `clk` on the Karabas boards is 40 MHz (the PLL output, historically named `clk50`; `src/ipcore/pll/pll.xco` has `clkout1_requested_out_freq=40`). The dot is `clk`/3 = 13.33 MHz. `cce` is `clk`/18 = 2.22 MHz. A line is 516 dots = 1548 `clk` = 38.7 us. A frame is 620 lines = 959 760 `clk`, about 24.0 ms (41.7 Hz). The moved comment "16MHz from 48MHz" stays as it was; these are the real values.
- Decision: `rk86_video` and `rk86_machine` run from `clk` = 40 MHz, one dot per 3 cycles. The platform provides 40 MHz (the Pocket with its own PLL). There is no clock enable input and none is planned: it would change the clock of the whole machine.
- `cce` goes to the CRT and the DMA, `hrtc` and `vrtc` to the CRT, all without a register.
- `d_cnt == h_cnt mod 6`: both are cleared at the line end and advance under the same strobe. The glyph row is loaded when `d_cnt == 5`. The exact phase dot to character cell, with the latency of the ROM, is defined in PR10 (the dot stream, with simulation) and is not claimed here.
- The line doubling is a property of the CRT, not of `rk86_video`: in both line modes the glyph row `line` comes from `chline[4:1]`, and `chline` advances on every falling edge of `hrtc` (`k580wg75.v:81, 117-131`), so each glyph row goes on two adjacent `v_cnt`.
- The window `h_cnt` 60 to 467 (408 dots = 68 character cells), one line of two (`v_cnt_line`) and `v_cnt2 < 300` are a choice of the Karabas wrapper, not a native property. `v_cnt_line` is not reset at the end of the frame (only `v_cnt2` is) and does not toggle on the last line, so it toggles 619 times in a frame of 620 lines: the written lines are the even `v_cnt` in one frame and the odd ones in the next.
- There is no reset: the initial values are the INIT = 0 of the FPGA. Every register of `rk86_video` (`state`, `d_cnt`, `data`, `h_cnt`, `v_cnt`) and of the wrapper (`v_cnt2`, `v_cnt_line`, `address_in`, `data_in`, ...) starts at 0; a cycle-exact simulation must set them to 0. No `initial` is added in PR09: XST would then infer `state` as an FSM (HDL ADVISOR in the `.syr`), and the names and the encoding would change.
- Outputs such as `pix_de`, `line_end`, `frame_end` are added later (PR10) as new ports; the existing ports do not change.

### `src/rk86_machine.prj`

The manifest lists the board-neutral sources: `k580wm80a.v`, `k580wt57.v`, `k580wg75.v`, `k580ww55.v`, `rk86_machine.v` and `rk86_video.v`. Paths are relative to `src/`. The manifest is in no ISE project. The checker elaborates it with iverilog.

## 3. What stays in the board top

- Memory: the SRAM address and data mux with the priority loader, then video DMA, then CPU. The ROM is at `0x10000 + rom_sel * 0x1000`. The loader (`loader.v`) and the file loader stay here.
- `rk_video` (`src/rtl/rk_video.v`, ports unchanged): the Karabas video around `rk86_video`. It holds the Coregen `font` ROM, the framebuffer `rambuffer` (408x300, one bit per dot) with its write (`h_cnt` 60 to 467, one line of two: `v_cnt2`, `v_cnt_line`), and the VGA output (`hvsync_generator`, 800x600, the reader with doubled dots and lines; `hr`, `vr`, `blank`, `pixel`).
- PLL, MCU link, soft switches, OSD.
- Reset composition: `cpurst | joy_rst` goes through a counter to `reset_n`. Then `reset = ~reset_n | loading`. `areset` is not part of the machine reset.
- SD controller, sound mixing, video output, pin tie-offs.

## 4. Invariants (as is)

The extraction must keep these facts. They are read from the current code.

**Video timebase** (`src/rtl/rk86_video.v`)

- `hrtc` (`hr_wg75`) is low while `h_cnt` is 468 to 515 (line 52).
- `vrtc` (`vr_wg75`) is low while `v_cnt` is 600 to 619 (line 53).
- `cce = d_cnt == 0 && state == 2'b01` (line 54).
- The period of `cce` is 18 `clk50` cycles. It is constant. It does not vary per line or in the blanking.
  - `state` cycles 0, 1, 2 on every `clk50` edge (lines 62-66). One step takes 3 cycles.
  - `h_cnt` and `d_cnt` advance only when `state == 0` (line 68).
  - `d_cnt` counts 0 to 5 and wraps at `d_cnt + 1 == 6` (lines 90-93). One `d_cnt` period is 6 steps of 3 cycles.
  - A line is `h_cnt` 0 to 515, that is 516 steps. 516 is a multiple of 6. The line end resets `d_cnt` to 0 (line 78) at the point where it wraps anyway. The period does not break at the line end.
  - `cce` is high for one cycle (when `state == 1`) once per `d_cnt` period.
- The font ROM has a latency of one `clk`: `font_addr` is combinational (line 56); the glyph row is loaded into `data` when `d_cnt == 5` (lines 70-71).

**CPU clock enable** (`src/rtl/rk86_machine.v`)

- The CPU clock enable is 1 of 28 cycles: `cpu_cnt` counts 0 to 27 (lines 103-104).
- When `hldareg[10:9]` is `01` (about 10 cycles after `hlda` rises) and the CPU has a read or write active, the CPU gets one extra enable at once (line 101). This re-enable is safe while the `cce` period is greater than 11. The period is 18.
- `hrq` is looped back to `hlda` (line 130: `.hlda(hlda), .hrq(hlda)`).

**Memory**

- Memory read is combinational. `mem_di` is shared by the CPU and the CRT.
- Writes are blocked at A15 (`cpu_wr_n | addrbus[15]`).
- ROM reads happen at 0xxx addresses while `startup` is set. `startup` is set by `reset` and cleared by the first access with A15 high.

**Reset**

- Asynchronous reset in the CPU, the DMA, the PPI and the SD controller.
- Synchronous reset in the CPU clock enable generator.
- `loading` enters `reset` combinationally.
- The CRT, `rk86_video` and `rk_video` have no reset.

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

`docs/contract-signals.csv` has one row per signal of the tops. A signal with different parts has one row per part (for example `ppa1_c` bits 0 and 7:1, before the machine moved out of the tops).

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
