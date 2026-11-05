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

L0 detail runs end early with +STOP_AT. Including generation and fuse, a run to cycle 131 072 takes 44-56 s and
a run to cycle 6 049 792 takes about 6 min.

A comparison takes about 1 min on the host (tools/compare_runs.py with the frame masks).

Since the comparison runs above, the VM runs one simulation at a time, so it has all 4 vCPU. At about 20k
cycles/s a basic chain alone takes about 21 min.
