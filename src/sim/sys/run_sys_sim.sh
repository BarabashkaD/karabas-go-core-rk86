#!/bin/bash
# Guest (ISE 14.7 VM): elaborate and run one sim work tree made by gen/gen_sim.py.
# Usage: bash run_sys_sim.sh <work_dir> <out_dir> [plusarg ...]
#   <work_dir>  the work tree (sim.prj with paths relative to it, sim.env, the .mif files, roms/)
#   <out_dir>   results: summary.txt, subst.txt, fuse.log, sim.log, perf.txt, simout/*
#   plusarg     NAME=value (a leading + is dropped), passed to the simulator as -testplusarg NAME=value
# fuse --nodebug: no HDL debugging support (the runs are batch only; about 10 % faster).
# Env: ISE_SETTINGS (default /opt/Xilinx/14.7/ISE_DS/settings64.sh), RUN_TIME (simulator run
#   command argument, e.g. "2 ms"; default: run all, the TB ends with $finish), FUSE_EXTRA,
#   MIN_RATE (reference cycles per second the run must reach for VERDICT PASS; default 15000).
# perf.txt: times, memory, the rates (TB_CYCLES of the log / wall clock from the start of the simulation run,
#   and / wall clock of the whole simulator process), the TB RESULT line and
#   VERDICT PASS|FAIL (TB result PASS and rate >= MIN_RATE; a missing RESULT line is FAIL unless sim.env
#   says TB_RESULT=none, the stub TB). The exit status is non-zero on any FAIL.
set -e
WORK=$(cd "$1" && pwd)
OUT=$2
shift 2
ISE_SETTINGS=${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh}
# shellcheck disable=SC1090
source "$ISE_SETTINGS" "$(dirname "$ISE_SETTINGS")" > /dev/null
# shellcheck disable=SC1091
. "$WORK/sim.env"
mkdir -p "$OUT"
cd "$WORK"

# XilinxCoreLib behavioural models of the Coregen wrappers first, glbl last (from $XILINX)
CORELIB=$XILINX/verilog/src/XilinxCoreLib
{
  echo "verilog work \"$CORELIB/BLK_MEM_GEN_V7_3.v\""
  echo "verilog work \"$CORELIB/FIFO_GENERATOR_V9_3.v\""
  cat sim.prj
  echo "verilog work \"$XILINX/verilog/src/glbl.v\""
} > sim_full.prj

# the Tcl batch prints the wall clock (epoch ms) when the simulation starts, after loading the design
if [ -n "$RUN_TIME" ]; then
  printf 'puts "TCL_T0_MS [clock clicks -milliseconds]"\nrun %s\nquit\n' "$RUN_TIME" > run.tcl
else
  printf 'puts "TCL_T0_MS [clock clicks -milliseconds]"\nrun all\nquit\n' > run.tcl
fi

FUSE_STATUS=0
/usr/bin/time -v -o fuse_time.txt fuse -incremental -prj sim_full.prj -L work -L unisims_ver -L unisim \
  -i tb -d "$DEFINE" -top "work.$TB_TOP" -top work.sim_ctl -top work.glbl -o tb.exe --nodebug $FUSE_EXTRA \
  > fuse.log 2>&1 || FUSE_STATUS=$?

SIM_STATUS=-1
if [ "$FUSE_STATUS" = 0 ]; then
  PLUS=""
  for p in "$@"; do PLUS="$PLUS -testplusarg ${p#+}"; done   # ISim takes NAME=value, no leading +
  mkdir -p simout
  SIM_STATUS=0
  /usr/bin/time -v -o sim_time.txt ./tb.exe -tclbatch run.tcl $PLUS -log sim.log > sim.out 2>&1 || SIM_STATUS=$?
  END_MS=$(date +%s%3N)
fi

# wall clock seconds of a /usr/bin/time -v report
elapsed_s() { awk -F': ' '/Elapsed/ { n = split($2, a, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + a[i]; print s }' "$1"; }
CYCLES=""; RATE_ALL=""; RATE=""; RESULT=""; T0_MS=""
if [ -f sim.log ]; then
  CYCLES=$(grep -m1 '^TB_CYCLES' sim.log | awk '{print $2}' || true)
  RESULT=$(grep -m1 '^RESULT' sim.log || true)
fi
[ -f sim.out ] && T0_MS=$(grep -m1 '^TCL_T0_MS' sim.out | awk '{print $2}' || true)
if [ -n "$CYCLES" ] && [ -f sim_time.txt ]; then
  # rate of the whole process (with loading the design) and of the simulation run alone
  RATE_ALL=$(awk -v c="$CYCLES" -v s="$(elapsed_s sim_time.txt)" 'BEGIN { if (s > 0) printf "%d", c / s }')
  if [ -n "$T0_MS" ]; then
    RATE=$(awk -v c="$CYCLES" -v a="$T0_MS" -v b="$END_MS" 'BEGIN { if (b > a) printf "%d", c * 1000 / (b - a) }')
  fi
fi
# verdict: the TB result (if the TB prints one) and the rate of the simulation run (MIN_RATE cycles/s)
MIN_RATE=${MIN_RATE:-15000}
VERDICT=""
if [ -n "$RESULT" ]; then
  if echo "$RESULT" | grep -q ' PASS$' && [ -n "$RATE" ] && [ "$RATE" -ge "$MIN_RATE" ]; then VERDICT=PASS; else VERDICT=FAIL; fi
elif [ "${TB_RESULT:-required}" != none ]; then
  VERDICT=FAIL    # the system TB always prints RESULT; none = it stopped without a verdict
  RESULT="RESULT missing (simulator status $SIM_STATUS)"
fi

{
  echo "board $BOARD tb_top $TB_TOP define $DEFINE"
  echo "fuse_status $FUSE_STATUS"
  [ -f fuse_time.txt ] && grep -E "Elapsed|Maximum resident" fuse_time.txt | sed 's/^\s*/fuse /'
  echo "sim_status $SIM_STATUS"
  [ -f sim_time.txt ] && grep -E "Elapsed|Maximum resident" sim_time.txt | sed 's/^\s*/sim /'
  if [ -n "$CYCLES" ]; then echo "sim reference cycles $CYCLES, rate $RATE cycles/s of the run (minimum $MIN_RATE), $RATE_ALL cycles/s with loading the design"; fi
  if [ -n "$RESULT" ]; then echo "tb $RESULT"; fi
  if [ -n "$VERDICT" ]; then echo "VERDICT $VERDICT"; fi
} > perf.txt

for f in summary.txt subst.txt fuse.log sim.log perf.txt; do
  [ -f "$f" ] && cp "$f" "$OUT/"
done
if [ -d simout ] && [ -n "$(ls -A simout)" ]; then
  mkdir -p "$OUT/simout" && cp simout/* "$OUT/simout/"
fi
cat perf.txt
grep -E "^(ERROR|FATAL)" fuse.log | head -40 || true
[ "$FUSE_STATUS" = 0 ] && [ "$SIM_STATUS" = 0 ] && [ "$VERDICT" != FAIL ]
