#!/bin/bash
# Builds one board in the working copy, inside the ISE 14.7 VM: a clone in the VM or a
# host checkout mounted through a shared folder.
#
# Usage: bash tools/ise/guest/build.sh <go|mini|minig>
#
# 1. regen_cores.sh generates the Coregen cores from src/ipcore/ into src/ipcore_dir/.
# 2. xtclsh runs the complete flow of the unchanged project ("Generate Programming File",
#    rerun_all): XST, Translate, Map, PAR, TRCE, BitGen.
# 3. The bitstream is copied from the project's Working Directory to src/<top>.bin, which
#    is tracked: commit it when it changes.
# Logs go to build/logs/<board>/, temporary files to build/tmp/.
#
# Optional environment:
#   ISE_SETTINGS  settings script of the ISE installation
#                 (default /opt/Xilinx/14.7/ISE_DS/settings64.sh)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
case "${1:-}" in
    go)    XISE=Radio-86RK.xise;       TOP=radio86rk ;;
    mini)  XISE=Radio-86RK-mini.xise;  TOP=radio86rk_mini ;;
    minig) XISE=Radio-86RK-minig.xise; TOP=radio86rk_minig ;;
    *)     echo "usage: build.sh go|mini|minig"; exit 2 ;;
esac
ISE_SETTINGS="${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh}"
LOG="$REPO/build/logs/$1"
mkdir -p "$LOG" "$REPO/build/tmp" || exit 90
rm -f "$LOG"/*.log "$LOG"/coregen/* 2> /dev/null

# The project's Working Directory (relative to src/) receives every ISE output.
wd=$(sed -n 's/.*xil_pn:name="Working Directory" xil_pn:value="\([^"]*\)".*/\1/p' "$REPO/src/$XISE")
WORK="$REPO/src/${wd:-.}"
mkdir -p "$WORK" || exit 90
# A stale bitstream in a separate Working Directory must not pass for a new one.
[ "$(readlink -f "$WORK")" = "$(readlink -f "$REPO/src")" ] || rm -f "$WORK/$TOP.bin"

export TMPDIR="$REPO/build/tmp" TMP="$REPO/build/tmp" TEMP="$REPO/build/tmp"
export LANG=C LC_ALL=C
# settings64.sh takes its first argument as the installation directory, and the Xilinx
# scripts read unset variables.
set +u
# shellcheck disable=SC1090
source "$ISE_SETTINGS" "$(dirname "$ISE_SETTINGS")" > "$LOG/settings.log" 2>&1
set -u
command -v xtclsh > /dev/null || { echo "ISE not found: $ISE_SETTINGS"; exit 91; }

# Through bash: a checkout on a shared folder has no executable bits.
REGEN_LOG_DIR="$LOG/coregen" bash "$HERE/regen_cores.sh" "$REPO/src/$XISE" || exit $?

cd "$REPO/src" || exit 90
touch "$LOG/started"
echo "xtclsh: $XISE"
if ! xtclsh "$HERE/ise_build.tcl" "$XISE" "$LOG" > "$LOG/xtclsh.log" 2>&1; then
    echo "ISE flow failed, see $LOG/xtclsh.log"
    exit 95
fi
if [ ! "$WORK/$TOP.bin" -nt "$LOG/started" ]; then
    echo "no new $TOP.bin in $WORK"
    exit 96
fi
[ "$(readlink -f "$WORK/$TOP.bin")" = "$(readlink -f "$REPO/src/$TOP.bin")" ] \
    || cp "$WORK/$TOP.bin" "$REPO/src/$TOP.bin" || exit 90
sha256sum "$REPO/src/$TOP.bin"
