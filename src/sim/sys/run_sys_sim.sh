#!/bin/bash
# Guest (ISE 14.7 VM): elaborate and run one sim work tree made by gen/gen_sim.py.
# Usage: bash run_sys_sim.sh <work_dir> <out_dir> [plusarg ...]
#   <work_dir>  the work tree (sim.prj with paths relative to it, sim.env, the .mif files, roms/)
#   <out_dir>   results: summary.txt, subst.txt, fuse.log, sim.log, perf.txt, simout/*
#   plusarg     passed to the simulator as -testplusarg <plusarg>
# Env: ISE_SETTINGS (default /opt/Xilinx/14.7/ISE_DS/settings64.sh), RUN_TIME (simulator run
#   command argument, e.g. "2 ms"; default: run all, the TB ends with $finish), FUSE_EXTRA.
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

if [ -n "$RUN_TIME" ]; then
  printf 'run %s\nquit\n' "$RUN_TIME" > run.tcl
else
  printf 'run all\nquit\n' > run.tcl
fi

FUSE_STATUS=0
/usr/bin/time -v -o fuse_time.txt fuse -incremental -prj sim_full.prj -L work -L unisims_ver -L unisim \
  -i tb -d "$DEFINE" -top "work.$TB_TOP" -top work.sim_ctl -top work.glbl -o tb.exe $FUSE_EXTRA \
  > fuse.log 2>&1 || FUSE_STATUS=$?

SIM_STATUS=-1
if [ "$FUSE_STATUS" = 0 ]; then
  PLUS=""
  for p in "$@"; do PLUS="$PLUS -testplusarg $p"; done
  mkdir -p simout
  SIM_STATUS=0
  /usr/bin/time -v -o sim_time.txt ./tb.exe -tclbatch run.tcl $PLUS -log sim.log > sim.out 2>&1 || SIM_STATUS=$?
fi

{
  echo "board $BOARD tb_top $TB_TOP define $DEFINE"
  echo "fuse_status $FUSE_STATUS"
  [ -f fuse_time.txt ] && grep -E "Elapsed|Maximum resident" fuse_time.txt | sed 's/^\s*/fuse /'
  echo "sim_status $SIM_STATUS"
  [ -f sim_time.txt ] && grep -E "Elapsed|Maximum resident" sim_time.txt | sed 's/^\s*/sim /'
} > perf.txt

for f in summary.txt subst.txt fuse.log sim.log perf.txt; do
  [ -f "$f" ] && cp "$f" "$OUT/"
done
if [ -d simout ] && [ -n "$(ls -A simout)" ]; then
  mkdir -p "$OUT/simout" && cp simout/* "$OUT/simout/"
fi
cat perf.txt
grep -E "^(ERROR|FATAL)" fuse.log | head -40 || true
[ "$FUSE_STATUS" = 0 ] && [ "$SIM_STATUS" = 0 ]
