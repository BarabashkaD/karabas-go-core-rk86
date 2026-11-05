# System simulation: wall times (Go, chain basic)

ISE 14.7 ISim in a VM with 4 vCPU / 6 GB; TB revision 70bba01. The rate is reference cycles (40 MHz) per
second of the simulation run (run_sys_sim.sh perf.txt).

The basic chain takes 25 234 819 cycles (631 ms model time). Snap keys2, the second picture in the other
cursor phase, adds about 6.7M cycles. Fuse takes 15-35 s alone and up to 2 min when several runs start
together.

| Run | Runs at the same time | sim wall | rate |
|---|---|---|---|
| a9685c7, ebf0c36 (development) | 2 | 24:18 | 17.2k-17.3k |
| ebf0c36, a9685c7, a9685c7 + seed opos_restart, a9685c7 + seed rom_banner, cb1c70b, 0ad30b6 | 6 | 30:56-32:32 | 13.0k-13.6k |
| Task 4 basic chain (19.25M cycles, older chain) | 1 | 15:33 | 20.7k |
| a9685c7 + seed cce_delay (TB b533214) | 1 | 21:39 | 19.5k |

L0 detail runs end early with +STOP_AT. Including generation and fuse, a run to cycle 131 072 takes 44-56 s and
a run to cycle 6 049 792 takes about 6 min.

A comparison takes a few seconds on the host (tools/compare_runs.py with the frame masks; 4 s for the
calibration pair).

## Sensitivity of the comparison

L0 resolves one 40 MHz cycle (the reference clock V_CLK) on the observed pins of GO_OBS, sampled at the
falling edge. A change inside the design that never reaches an observed pin, or changes a pin only between
two samples, is invisible to L0. L1 ignores timing by design (event-aligned: event names, RAM, value-changing
SRAM writes, frames; cycle shifts are informative only), so a pure timing change is seen by L0 alone.

Measured with the seed cce_delay (the DMA / CRT clock enable one 40 MHz clock later, a9685c7, against the
calibration run of a9685c7): L0 differs from window 461 (cycle 1 888 256, inside the expected windows
init_done..prompt) in 5666 of 6161 windows; L1 is equal (RAM, writes and frames; event shifts of +1 cycle).

Since the comparison runs above, the VM runs one simulation at a time, so it has all 4 vCPU. At about 20k
cycles/s a basic chain alone takes about 21 min.
