# Verification of the standard configuration

The standard configuration is the one of the three Karabas boards after this series: each top instantiates `rk86_machine`, `karabas_keyboard` and `rk_video` (around `rk86_video`), with the clock enable `ce` and the CPU memory ready `cpu_ready` tied to 1 ([contract.md](contract.md), section 3). This document says, for each board, what shows that the new configuration behaves as the release before the series, what has not been checked, how to repeat the checks, and what to test on the boards before a release. The steps of the series are named by their number in the modernization plan and their title (PR01 to PR12; these are not GitHub pull request numbers); the release is `origin/main` 4ef5988 (the merge of kgo2; its bitstreams are reproduced from the sources at 10ff7fd; the release `.bin` files were committed in eb21367 (Go), 91b465b (Mini) and 732e076 (Mini G); the core file was repacked in d9cfe90).

## 1. Bitstreams

| Board | Release (`origin/main` 4ef5988) | Now (PR11 and later) |
| --- | --- | --- |
| Go | `119827fd3c602181cb5a0409c58baf153bd013d7668667a79e940989203e4af5` | `a2434caf5596cf346a1397f46738286cd1d43d8a57cd0c0e8168ac9815d813d6` |
| Mini | `a7acac5902d299b65da8d800f8ea4c3b6fc9de58d094b4366da59c77e2f9d7cd` | `a66a7dff17b85585c1eb0b0122261ac120aab88793d53ebb12430bff960dea01` |
| Mini G | `9e839cfc955ee9d989e9fccad8275ecd25e695a125fca23ff7bf206565c238e2` | `e899d7f2ef3f5497609821cd8a740dd0cb8f3b493514bd4d4f3abb0f0589e164` |

SHA256 of `src/radio86rk.bin`, `src/radio86rk_mini.bin` and `src/radio86rk_minig.bin`. Builds are reproducible byte for byte ([tools/ise/README.md](../tools/ise/README.md), Reproducibility). The PR12 commits change no logic: the board build commands are the same (`make -C src -n -B go mini minig` gives the same output before and after them, with the three XST runs), and a Mini build from scratch gives the same bitstream (`a66a7dff…`). `src/radio86rk.kg` still holds the release bitstreams; packing the new ones is the release step (section 6).

## 2. What changed and what shows that the boards are the same

| Step | Change | Evidence |
| --- | --- | --- |
| PR01, build in the ISE 14.7 VM; PR02, explicit build configuration; PR03, `modules/` submodule; parallel build | the build, not the design | the three bitstreams equal the release ones |
| Mini G timing constraint | a PERIOD on the 50 MHz clock of the Mini G (`src/pins_minig.ucf`); before it the Mini G clocks had no constraint | constraint only; all constraints met; new Mini G bitstream (placement) |
| PR05, contract and checker | documents, `tools/contract` | no source of a board changed |
| PR06, keyboard | `karabas_keyboard` from the tops | netlist equivalence against the build before it: EQUIVALENT on the three boards |
| PR07, machine | `rk86_machine` from the tops | netlist equivalence against the PR06 build: EQUIVALENT on the three boards |
| PR09, native video split | `rk86_video` from `rk_video` | netlist equivalence against the PR07 build: EQUIVALENT on the three boards |
| PR10, video stream | `rk86_video_stream`, in no board build | the sources of the boards unchanged; simulation |
| PR11, clock enable and CPU ready | `ce` and `cpu_ready`, tied to 1 by the boards | netlist equivalence against the PR09 build: EQUIVALENT on the three boards; simulation |
| PR12, integration guide, build candidate, this document | documents, one comment, the candidate | board build commands unchanged; Mini rebuilt: same bitstream |

**Netlist equivalence.** A local tool (not in this repository) reads the post-synthesis netlists of two builds (`netgen` of the `.ngc`) and cuts them at the registers: flip-flops, block RAM, DSP, I/O and clock cells are matched by name, and every input of a matched cell and every output port is compared as a function of the cut points: exhaustively, or exactly with a BDD, and only where a function is too large with 4096 random vectors (the checkpoints listed below). The Coregen cores are black boxes for the tool: their ports are compared, not their contents; their `.xco` inputs (`src/ipcore`) did not change in these steps. Registers that XST duplicated or merged are matched by their functions. EQUIVALENT means: the same registers with the same next-state functions, no cut cell left unmatched, no mismatch. Each step was compared with the build of the step before.

- PR09: EQUIVALENT on the three boards, 0 unmatched cut cells (1547 on the Go, 2199 on the Mini, 2266 on the Mini G). Two DSP cells that XST named differently in the two builds were matched by an explicit rename. Random vectors only for two checkpoints of the CPU, which did not change: `FC` and `A_6` (Go) or `A_3` (Mini, Mini G); every other checkpoint was checked exhaustively or with a BDD.
- PR11: EQUIVALENT on the three boards, 0 unmatched cut cells, with a larger BDD budget; random vectors only for one checkpoint of the CPU, `FC`.
- PR06 and PR07: EQUIVALENT on the three boards, 0 unmatched cut cells (PR06: 1547, 2199 and 2272 matched on the Go, Mini and Mini G; PR07: 1547, 2199 and 2266), with the larger BDD budget. Random vectors only for one checkpoint per board, a bit of the dot shift register of the video (`data_3`, `data_4` or `data_5`), which neither step changed; every checkpoint of the keyboard and of the machine was checked exhaustively or with a BDD. The two comparisons were repeated with the current tool on the stored netlists of the steps.

**Timing and resources** (MAP and PAR reports of the release and of the current build):

| Board | Build | Registers | LUTs | Slices | RAMB16 / RAMB8 / DSP | 40 MHz clock: achieved period / slack |
| --- | --- | --- | --- | --- | --- | --- |
| Go | release | 1,544 | 2,254 | 835 | 19 / 1 / 2 | 13.544 ns / 5.728 ns |
| Go | now | 1,544 | 2,239 | 851 | 19 / 1 / 2 | 18.788 ns / 3.106 ns |
| Mini | release | 2,161 | 3,184 | 1,077 | 19 / 1 / 2 | 22.794 ns / 1.103 ns |
| Mini | now | 2,161 | 3,169 | 1,089 | 19 / 1 / 2 | 23.896 ns / 0.552 ns |
| Mini G | release | 2,234 | 3,287 | 1,115 | 19 / 1 / 2 | no constraint |
| Mini G | now | 2,228 | 3,285 | 1,131 | 19 / 1 / 2 | 24.152 ns / 0.424 ns |

The 40 MHz clock is the PLL output `clk50` (`TS_pll_clkout0`, 25 ns); all timing constraints of the three boards are met. The Mini G has 6 registers fewer since the machine step: XST no longer duplicates 6 registers of the OSD; the equivalence check matched the duplicates. PAR stops when the constraints are met, so the achieved period moves with the placement.

**Simulation.** The machine testbench last ran on the PR11 step; the RTL of the modules has not changed since, apart from one comment in `rk86_machine.v`. The video testbench (`ce` 160 of 297) and the candidate testbench were run again on the PR12 step: PASS (the logs are kept under `build/ref/pr12-candidate` of the working tree, outside git).

- `src/sim/machine`: the machine, `rk86_video` and `rk86_video_stream` with the BIOS from power-up to the keyboard loop, 12 frames: `ce` on 160 of 297 `clk` and a pseudo-random `ce` give the bus transactions and the video lines of `ce` = 1, line by line; random memory stalls give the same transactions apart from the status poll of the BIOS and the same final frames; with `ce` = 1 and the Karabas memory the machine equals the code of the video stream step (PR10, before the clock enable) on every `clk`. The 11 broken variants of the gating each fail by their own check, and so does a twelfth variant, a CPU period of 27 instead of 28 `ce` cycles, against that code. PASS.
- `src/sim/video`: every output of `rk86_video_stream` on every dot and the picture against a rendering with `FONT.BIN`: on the PR11 step with `ce` = 1, 160 of 297 and pseudo-random at font latency 1, and 160 of 297 at latency 16; on the PR10 step (without `ce`) also latency 0 and 16. A broken variant fails. PASS.
- `src/sim/candidate`: the build candidate with the BIOS (section 3). PASS; its two broken variants fail (the run of the PR12 candidate commit).
- A system simulation of the whole Go top (ISim, with the MCU link and the ROM loading) exists on a separate branch, not in this repository state; it is not part of this evidence.

## 3. The build candidate

`make -C src candidate` builds `src/rk86_candidate.v` on the XC6SLX25-2: the board-neutral modules with a clock enable of 160 of 297 `clk` and a synchronous memory whose slow ROM makes the CPU wait on `cpu_ready` ([integration.md](integration.md), The build candidate). With these signals not constant, the gated logic stays in the netlist. This rests on a check of the register names in the synthesis report (`.syr`), not on a netlist analysis: the warnings of trimmed or unconnected registers, with and without an INIT value (Xst:2677, 1710, 1895, 2404, and Xst:1293, 1896, 1898 for registers with an INIT value, as the registers of the clock enable, the reset and the memory ready of the candidate have), the merges of equivalent registers (Xst:2261) and the shift registers that XST extracted. What it shows for the registers of the gating (`dma_we_q`, `crt_we_q`, `crt_rd_q`, `cpu_cnt`, `cpu_ce2`, `hldareg`) and of the candidate (`ce`, `cadence`, `rst_cnt`, `rom_busy`, `cpu_tag`):

- `cadence` bit 9 is trimmed as constant 0 (Xst:1293): the accumulator stays below 297 and needs only 9 bits.
- The edge registers of the CRT, `exwe_n` and `exrd_n`, are merged into `crt_we_q` and `crt_rd_q` (Xst:2261): they hold the same value on every edge (with `ce` = 1 both take `crt_we_n` / `crt_rd_n`; with `ce` = 0 the edge register takes the held value).
- `hldareg` becomes a shift register LUT (SRL) for its first 10 stages.
- Nothing else of these registers is removed.

The other merge of the top is `d_cnt` bit 0 into `h_cnt` bit 0 of `rk86_video` (equal, since `d_cnt == h_cnt mod 6`). Of the other registers of the candidate top only `font_q` bits 7 and 6 are trimmed, the font bits that `rk86_video` does not use; the rest of the trimmed registers are unused bits inside the CPU, the DMA, the CRT, the PPI and the video counters (for example the PPI port B outputs, the top bit of `h_cnt`). The two-register synchronizers `rst_sync` and `load_sync` carry `ASYNC_REG` and `SHREG_EXTRACT = "NO"` ([integration.md](integration.md), section 3); XST applies both properties and keeps them as flip-flops (without the attributes an earlier build had packed them into SRLs), so MAP reports one shift register, `hldareg`. The implementation meets the PERIOD of 25 ns on `clk`:

| Registers | LUTs | Slices | RAMB16 / RAMB8 / DSP | `clk` 25 ns: achieved period / slack |
| --- | --- | --- | --- | --- |
| 489 | 1,228 | 390 | 17 / 1 / 0 | 11.591 ns (86.3 MHz) / 13.409 ns |

Of the XC6SLX25: 30,064 registers, 15,032 LUTs, 3,758 slices, 52 RAMB16, 104 RAMB8. The synthesis report has 120 warnings. Only the `clk` pin is placed and the I/O timing is not constrained; there is no bitstream.

The smoke simulation loads the BIOS and the font through the loader port and runs 10 frames at 160 of 297. Every CPU step that reads the RAM or the ROM gets the byte that the memory holds at that address (53,858 reads checked); the CPU reaches the keyboard loop of the BIOS in frame 6; steps wait for the slow ROM. Two more checks (no step without `cpu_ready`, none while `vid_rd`) hold by construction and are sanity checks only. Two broken variants fail (the passing run and both variants were re-run on the final PR12 tree, with the synchronizer attributes; the logs are kept under `build/ref/pr12-candidate` of the working tree, outside git): with a `cpu_ready` that does not wait for the ROM, the CPU reads FF and does not reach the keyboard loop; with `cpu_ready` = 1, the CPU reads wrong data. Both fail at the first reads from the ROM after the reset (FF at 0001 and 0002), so neither exercises the address tag of the RAM path; the data check covers that path only in the passing run. A variant with `cpu_ready` not gated by `vid_rd` is not caught by these checks, so the rule "`cpu_ready` low while `vid_rd`" rests on the derivation in contract.md, not on this simulation. This is the level of verification for another platform: the composition synthesizes, meets its clock constraint and runs the BIOS in simulation; it has not run on hardware.

## 4. What has not been checked

- **No board has run the new bitstreams.** The evidence above is about the logic and the internal timing. The bitstreams differ from the release ones in synthesized structure (equivalent by the netlist check of section 2: random vectors on the listed checkpoints; the Coregen cores compared as black boxes, their `.xco` unchanged) and placement, and the pins to the SRAM, the video output and the MCU have no I/O timing constraint (no OFFSET in the `.ucf`), so their margins changed without a check; only a test on the boards covers them (section 6).
- The equivalence tool is not in this repository: the result can be repeated only with that tool. It compares the netlists from the same register state; the power-up values (INIT) of the boards come from XST in both builds.
- `ce` patterns and `cpu_ready` = 0 are checked in simulation and, for synthesis and timing, by the build candidate; no platform has run them on hardware.
- The CRT and `rk86_video` have no reset (contract.md, section 4); the known defects of contract.md, section 7, are kept.

## 5. How to repeat the checks

On the host, with Icarus Verilog (tested with 13.0) and Python 3:

```
python -B tools/contract/check_contract.py --iverilog <iverilog>
python -B src/sim/machine/run_machine_sim.py --iverilog <iverilog> --ref-rev <rev> --negative
python -B src/sim/video/run_video_sim.py --iverilog <iverilog> [--ce full|frac|random] [--font-latency N] [--negative]
python -B src/sim/candidate/run_candidate_sim.py --iverilog <iverilog> --negative
```

`<rev>` is the code before the clock enable: the parent of the first commit that adds `cpu_ready` to `src/rtl/rk86_machine.v`. In sh, and in PowerShell:

```
git rev-parse "$(git log --reverse --format=%H -S cpu_ready -- src/rtl/rk86_machine.v | head -n 1)^"
git rev-parse "$(git log --reverse --format=%H -S cpu_ready -- src/rtl/rk86_machine.v | Select-Object -First 1)^"
```

The video runs above use `--font-latency` 0, 1 (the default) and 16.

In the ISE 14.7 VM ([tools/ise/README.md](../tools/ise/README.md)):

```
bash tools/ise/guest/build.sh go mini minig     # bitstreams: compare with section 1
make -C src candidate && make -C src candidate-report
```

## 6. Hardware test before a release

The core file in the repository holds the release bitstreams. For the test, pack the current ones with `make_core.py` of karabas-go-tools (`src/make_core.py` links to it; [tools/ise/README.md](../tools/ise/README.md), Repositories side by side), from `src/`: `python make_core.py core.json ../build/radio86rk-test.kg` (`build/` is ignored; do not commit the test file). The release commit (the `.bin`, the `build` of `core.json` and the `.kg` together) follows the test. Compare with the release core file on the same board and monitor where a result is unclear.

| # | Check | Expected | Go | Mini | Mini G |
| --- | --- | --- | --- | --- | --- |
| 1 | Start the core from the menu (ROM: BIOSSD, the default) | the monitor screen with its prompt; stable picture | [ ] | [ ] | [ ] |
| 2 | Picture | the whole text area visible, not shifted or cut, as with the release core; Go: VGA 800 x 600; Mini, Mini G: HDMI | [ ] | [ ] | [ ] |
| 3 | Type letters, digits, `-` `,` `.`, `=` (`:`), `` ` `` (`^`), keypad digits | echoed as typed | [ ] | [ ] | [ ] |
| 4 | `Enter` (`ВК`), `Backspace` (`ЗБ`), arrows, `Home` (`↖`), `Del` (`СТР`), `Tab`, `Scroll Lock` (`ПС`), `Esc` (`АР2`), `F1`-`F5` | the action of the Radio-86RK key (`README.md`) | [ ] | [ ] | [ ] |
| 5 | `Shift` (`СС`) + `1` | `!` | [ ] | [ ] | [ ] |
| 6 | left `Ctrl` (`УС`) with a key; right `Ctrl` (`РУС/ЛАТ`) | control code; letters switch to Cyrillic and back | [ ] | [ ] | [ ] |
| 7 | RAM, 0000-75FF (below the monitor's work area): `F0000,3AFF,55` and `F3B00,75FF,AA`, then `C0000,3AFF,3B00`; samples with `D` (for example `D0000,000F`, `D3AF0,3B0F`, `D75F0,75FF`); then the same with 55 and AA swapped | `C` reports a difference at every address (55 against AA); the samples show 55 in the lower half and AA in the upper half (swapped in the second pass) | [ ] | [ ] | [ ] |
| 8 | `Menu+T`, a tape image from `pk/` with Autorun on (`Menu+A`) | loaded and started | [ ] | [ ] | [ ] |
| 9 | The same with Autorun off | loaded, the monitor prompt stays | [ ] | [ ] | [ ] |
| 10 | With BIOSSD: the SD card in the window A000-BFFF, as with the release core | the SD card functions of BIOSSD work | [ ] | [ ] | [ ] |
| 11 | `Menu+B` (ROM: BIOS), then reset | the monitor of `BIOS.BIN` starts; back to BIOSSD the same | [ ] | [ ] | [ ] |
| 12 | Tape: save a block with the monitor (`O`) to `TAPE_OUT` and read it back (`I`) from `TAPE_IN`, where the board has the tape lines | the block reads back | [ ] | [ ] | [ ] |
| 13 | A program with sound; `Menu+M` off and on | sound and silence; Go: BEEPER and the DAC; Mini: HDMI audio and the audio outputs; Mini G: HDMI audio and the PCM5102 | [ ] | [ ] | [ ] |
| 14 | `Menu+V` | white and green text | [ ] | [ ] | [ ] |
| 15 | `Menu+Esc`; keys while the OSD is open; OSD item Reset | the OSD opens and takes the keys; Reset restarts the monitor | [ ] | [ ] | [ ] |
| 16 | `Ctrl+Alt+Del`; `Ctrl+Alt+Backspace` | reset; back to the core loader | [ ] | [ ] | [ ] |
| 17 | SEGA joystick: D-pad, `A`, `B`, `X+Z`, `R+Start` | arrows, `ВК`, space, reset, OSD | [ ] | [ ] | [ ] |
| 18 | The cursor; fill the screen until it scrolls; run for 10 minutes | the cursor blinks; scroll without garbage; no hang | [ ] | [ ] | [ ] |

## 7. Open points

- The equivalence tool could be added to the repository, so that a later change can be checked the same way.
- contract.md, section 8, says that the signal table and its checker are removed after the boards move to the machine; the boards have moved, and the decision is the maintainer's.
