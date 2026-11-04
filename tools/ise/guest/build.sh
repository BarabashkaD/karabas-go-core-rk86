#!/bin/bash
# Builds one or more boards from scratch in the working copy, inside the ISE 14.7 VM: a
# clone in the VM or a host checkout mounted through a shared folder.
#
# Usage: bash tools/ise/guest/build.sh [-k] <go|mini|minig>...
#
#   -k  keep the Coregen cores of the previous build: make generates them again only
#       when their inputs changed (for iterations; verification and releases build
#       without -k)
#
# Removes the working directories of the boards (build/ise/<board>/) and, without -k, the
# cores stamp, runs `make cores` in src/ (the Coregen cores of all boards, once), then
# `make <board>` for every board in parallel: XST, NGDBuild, MAP, PAR, TRCE, BitGen and
# the copy of the bitstream to src/<top>.bin, which is tracked: commit it when it changes.
# For one step at a time use src/Makefile directly.
# Logs: build/logs/cores.log and build/logs/coregen/, build/logs/<board>/make.log;
# temporary files: build/tmp/.
#
# Optional environment:
#   ISE_SETTINGS  settings script of the ISE installation
#                 (default /opt/Xilinx/14.7/ISE_DS/settings64.sh)
#   REGEN_JOBS    Coregen runs at a time (default: the number of CPUs)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
usage() { echo "usage: build.sh [-k] go|mini|minig..."; exit 2; }
top() {
    case "$1" in
        go)    echo radio86rk ;;
        mini)  echo radio86rk_mini ;;
        minig) echo radio86rk_minig ;;
    esac
}
# Removes the given paths. On a shared folder an unlink can fail for a moment after a
# build ("Text file busy"): try again, and stop if a path stays, so that a build never
# starts on old outputs.
remove() {
    local i
    for i in 1 2 3 4 5; do
        rm -rf "$@" 2> /dev/null && return 0
        sleep 2
    done
    rm -rf "$@" || { echo "cannot remove $*"; exit 90; }
}

KEEP_CORES=0
if [ "${1:-}" = "-k" ]; then KEEP_CORES=1; shift; fi
[ $# -gt 0 ] || usage
for b in "$@"; do [ -n "$(top "$b")" ] || usage; done
export ISE_SETTINGS="${ISE_SETTINGS:-/opt/Xilinx/14.7/ISE_DS/settings64.sh}"
[ -f "$ISE_SETTINGS" ] || { echo "ISE not found: $ISE_SETTINGS"; exit 91; }
[ -f "$REPO/modules/rtl/mcu/burst_rx.vhd" ] \
    || { echo "modules/ is empty: run git submodule update --init"; exit 97; }

LOG="$REPO/build/logs"
for b in "$@"; do remove "$REPO/build/ise/$b" "$LOG/$b"; done
remove "$LOG/cores.log"
# Without -k, or when the generated cores are missing, Coregen runs again from scratch.
if [ $KEEP_CORES -eq 0 ] || [ ! -d "$REPO/src/ipcore_dir" ]; then
    remove "$REPO/build/ise/cores.stamp" "$LOG/coregen"
fi
mkdir -p "$LOG" "$REPO/build/tmp" || exit 90
export TMPDIR="$REPO/build/tmp" TMP="$REPO/build/tmp" TEMP="$REPO/build/tmp"
export LANG=C LC_ALL=C

STARTED="$LOG/started"
touch "$STARTED"
echo "make cores"
if ! make -C "$REPO/src" cores REGEN_LOG_DIR="$LOG/coregen" > "$LOG/cores.log" 2>&1; then
    echo "Coregen failed, see $LOG/cores.log"
    exit 95
fi

jobs_=""
for b in "$@"; do
    mkdir -p "$LOG/$b" || exit 90
    echo "make $b"
    make -C "$REPO/src" "$b" > "$LOG/$b/make.log" 2>&1 &
    jobs_="$jobs_ $b:$!"
done
rc=0
for j in $jobs_; do
    if ! wait "${j#*:}"; then
        echo "build failed: ${j%%:*}, see $LOG/${j%%:*}/make.log"
        rc=95
    fi
done
[ $rc -eq 0 ] || exit $rc
for b in "$@"; do
    bin="$REPO/src/$(top "$b").bin"
    [ "$bin" -nt "$STARTED" ] || { echo "no new src/$(top "$b").bin"; exit 96; }
    sha256sum "$bin"
done
