# rk86_16: the Radio-86RK machine with the original 16 MHz timing

Used by the Analogue Pocket core only; the Karabas boards use `../rk86_machine.v`. Every chip is reproduced
to its own data sheet (Intel 8224, 8255A, 8257, 8275; К155ИЕ4, К155ИР13, К155ТМ2) and the board schematics
(Радио 1986 No. 4-5, S. Kiselev's re-make 1.4); emulators are not sources of behaviour.

| File | Source | Licence | Changes |
|---|---|---|---|
| `k580vm80a.v` | MiSTer-devel/Apogee_MiSTer `rtl/k580vm80a.v` at 4b37da2; author Vslav (1801BM1), as in the file header | CC-BY 3.0 | line endings (CR LF to LF) only |
| `k580vt57.v` | rewritten to the 8257 data sheet; base: Apogee_MiSTer `rtl/k580vt57.v` at 4b37da2 (Dmitry Tselikov, Sorgelig) | modified BSD (`../../LICENSE.TXT`) | listed in the file header |
| `k580vg75.v` | rewritten to the 8275 data sheet; base: Apogee_MiSTer `rtl/k580vg75.sv` at 4b37da2 (Dmitry Tselikov, Sorgelig) | modified BSD | listed in the file header |
| `k580vv55.v`, `rk86_clocks16.v`, `rk86_video16.v`, `rk86_machine16.v` | this project | modified BSD | |

## Decisions where the data sheets are silent

Where a data sheet does not decide a behaviour, the board decides (the picture and timing of the Радио 1986
and Kiselev 1.4 boards); the decision is marked `SILENT` in the file header. The one below is approved for
now and waits for a check on a real chip (next section).

### 8275: the DMA restart after an underrun (`k580vg75.v`, S11; decided 2026-11-11)

- Data sheet: "Upon detection of DU, the DMA operation is stopped and the screen is blanked until after the
  vertical retrace interval" ([D79] 1-180; 1984 data sheet 8-68). And: "The first DMA request for a row will
  start at the first character clock of the preceding row" (1984 data sheet 8-60): row 0's buffer is filled
  during the last row of the vertical retrace, inside the retrace interval.
- Silent: whether that row-0 fill belongs to "until after the vertical retrace interval".
- Model: the DMA stop ends at the start of the last retrace row, so the row-0 fill of the next frame runs as
  in every frame; the screen stays blanked until row 0 starts (after the retrace), which meets the blanking
  sentence word for word. DU, IRQ and the status are as the data sheet says.
- The strict reading (the DMA stopped until VRTC falls, the row-0 fill skipped) was the model's first rule.
  It is not taken: the 8257 hands out its block in order whatever row asks, so a skipped row-0 fill puts
  row 0's bytes into row 1 and the picture stays one row down in every later frame (the 8257's autoload
  repeats the same block; nothing re-synchronises it). On the Radio-86RK that would happen after the boot
  underrun (the monitor sends Start Display before it enables the 8257; whether the underrun hits depends on
  the phase of the boot against the raster) and after every tape operation. The boards show an aligned
  picture.
- Tests: `tb_vg75_dma.v` check 6 (no DRQ and VSP high from the underrun row to the last retrace row; the
  row-0 fill there within 0..84 ce16, 78 transfers; blanking until VRTC falls); the fault
  `vg75_underrun_restart_late` (the strict reading) fails in `vg75`, `vg75_dma`, `vg75_attr` and `machine16`
  (the 8257 out of step with the frame).
- To return to the strict reading: revert the commit "vg75 underrun: the DMA restarts with the row-0 fill"
  and swap the fault back (`vg75_underrun_restart_early`).

## Follow-up: checks on real hardware

Planned by the maintainer: on a real Radio-86RK (or any board with a real 8275 and 8257), with a logic
analyser. Not on the FPGA: an FPGA runs this model, so it cannot tell how the chip behaves.

1. 8275 underrun restart (the decision above). A test program (8080, on the ROM disk or from tape):
   - write each row's number at the start of the row (00..29), so a shift of one row is visible;
   - wait for IR (the start of the last display row), disable the 8257 (E008h <- 80h) for about one frame,
     so that the 8275 finds a row buffer not full and sets DU;
   - at the next IR, before the retrace, program the 8257 as the monitor does (76D0h, 4923h, mode A4h);
   - read the status (DU, bit 1) and show it; hold the picture.
   Result: rows aligned ("00" on the top row) = the model; the picture one row down = the strict reading.
   Logic analyser: 8275 DRQ (pin 5), DACK (pin 6), HRTC, VRTC, triggered on the underrun: whether DRQ pulses
   in the last retrace row after DU.
2. 8275 status read against IR: whether a status read can lose an IR flag set during the read (a status read
   clears IR; seen in simulation at the monitor's second video init: the monitor then waits one more frame).
   Analyser: RD, CS, A0, IRQ (pin 4) around the start of the last display row.
3. 8275 Reset command during a row fill: whether the fill in progress stops at once (the model: DMA and the
   fill stop; the partly filled row is shown as it is) and when DMA resumes after Start Display (S9: the
   model starts at the next row start with a fill due). Analyser: DRQ, DACK, WR, CS, A0.
4. 8257 SI -> S0 after the DRQ sample (`k580vt57.v`; the two data sheet readings of 2026-11-11 put one more
   SI state before S0, a change kept on the branch `rk86-16mhz-m9`): not visible with an 8080 (HLDA comes
   later than the difference); only a board that drives HLDA high in advance would show it.

Record each result with the board, the chip markings and the analyser capture; a result that differs from
the model changes the model and its tests, and this section.
