#!/bin/bash
# Builds one board from scratch in the working copy, inside the ISE 14.7 VM: a clone in
# the VM or a host checkout mounted through a shared folder.
#
# Usage: bash tools/ise/guest/build.sh <go|mini|minig>
#
# Removes the working directory of the board (build/ise/<board>/) and runs `make <board>`
# in src/: the Coregen cores, XST, NGDBuild, MAP, PAR, TRCE, BitGen and the copy of the
# bitstream to src/<top>.bin, which is tracked: commit it when it changes. For one step at
# a time use src/Makefile directly.
# Log: build/logs/<board>/make.log (Coregen: coregen/); temporary files: build/tmp/.
#
# Optional environment:
#   ISE_SETTINGS  settings script of the ISE installation
#                 (default /opt/Xilinx/14.7/ISE_DS/settings64.sh)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
case "${1:-}" in
    go)    TOP=radio86rk ;;
    mini)  TOP=radio86rk_mini ;;
    minig) TOP=radio86rk_minig ;;
    *)     echo "usage: build.sh go|mini|minig"; exit 2 ;;
esac
export ISE_SETTINGS="${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh}"
[ -f "$ISE_SETTINGS" ] || { echo "ISE not found: $ISE_SETTINGS"; exit 91; }

LOG="$REPO/build/logs/$1"
rm -rf "$REPO/build/ise/$1" "$LOG"
mkdir -p "$LOG" "$REPO/build/tmp" || exit 90
export TMPDIR="$REPO/build/tmp" TMP="$REPO/build/tmp" TEMP="$REPO/build/tmp"
export LANG=C LC_ALL=C

touch "$LOG/started"
echo "make $1"
if ! make -C "$REPO/src" "$1" REGEN_LOG_DIR="$LOG/coregen" > "$LOG/make.log" 2>&1; then
    echo "build failed, see $LOG/make.log"
    exit 95
fi
if [ ! "$REPO/src/$TOP.bin" -nt "$LOG/started" ]; then
    echo "no new src/$TOP.bin"
    exit 96
fi
sha256sum "$REPO/src/$TOP.bin"
