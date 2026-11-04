#!/bin/bash
# Generates the Coregen cores of the boards from their tracked inputs (called by src/Makefile).
#
# Usage: bash tools/ise/guest/regen_cores.sh src/<top>.prj [src/<top>.prj ...]
#
# The cores are the "ipcore_dir/<path>/<core>.v" entries of the .prj files, each core once.
# Inputs:  src/ipcore/<path>/<core>.xco and the coregen.cgp next to it (tracked).
# Output:  src/ipcore_dir/<path>/ (ignored).
# A coe_file in the tracked .xco is relative to the directory of that .xco; the
# generated copy gets the absolute path, because Coregen reads it from there.
# The cores of different directories are generated in parallel; Coregen writes its
# project files into the directory of the core, so the cores of one directory run one
# after the other.
#
# Optional environment:
#   REGEN_LOG_DIR  log directory (default <repo>/build/logs/coregen)
#   REGEN_JOBS     Coregen runs at a time (default: the number of CPUs)
#
# Exit codes: 0 ok, 90 file system, 91 coregen not found, 92 missing core or input,
#             93 COE file not found, 94 coregen failed.

set -u

[ $# -gt 0 ] || { echo "usage: regen_cores.sh <board .prj>..."; exit 92; }
SRC="$(dirname "$(readlink -f "$1")")"
LOG="${REGEN_LOG_DIR:-$SRC/../build/logs/coregen}"
JOBS="${REGEN_JOBS:-$(nproc 2> /dev/null || echo 1)}"
mkdir -p "$LOG" || exit 90
command -v coregen > /dev/null || { echo "coregen not found: source settings64.sh first"; exit 91; }

cores=$(for prj in "$@"; do
    sed -n 's/^[a-z]* work "ipcore_dir\/\(.*\)\.v"/\1/p' "$prj" | tr -d '\r'
done | sort -u)
[ -n "$cores" ] || { echo "no Coregen cores in $*"; exit 92; }

# Copies the inputs of one core to its directory and generates it.
regen() {
    local rel=$1 in out name coe abs rc
    in="$SRC/ipcore/$(dirname "$rel")"
    out="$SRC/ipcore_dir/$(dirname "$rel")"
    name=$(basename "$rel")
    if [ ! -f "$in/$name.xco" ] || [ ! -f "$in/coregen.cgp" ]; then
        echo "missing input for $rel: $in/$name.xco and $in/coregen.cgp"
        return 92
    fi
    mkdir -p "$out" || return 90
    cp "$in/$name.xco" "$in/coregen.cgp" "$out/" || return 90
    coe=$(sed -n 's/^CSET coe_file=//p' "$in/$name.xco" | tr -d '\r')
    # Coregen writes "no_coe_file_loaded" for a memory without an initialisation file.
    if [ -n "$coe" ] && [ "${coe#no_}" = "$coe" ]; then
        abs=$(cd "$in" && readlink -f "$coe")
        if [ ! -f "$abs" ]; then
            echo "COE file not found for $rel: $coe"
            return 93
        fi
        sha256sum "$abs" >> "$LOG/coe.sha256"
        sed -i "s#^CSET coe_file=.*#CSET coe_file=$abs#" "$out/$name.xco"
    fi
    ( cd "$out" && coregen -p coregen.cgp -b "$name.xco" -r -intstyle xflow ) > "$LOG/$name.log" 2>&1
    rc=$?
    if [ $rc -ne 0 ] || grep -q '^ERROR:' "$LOG/$name.log"; then
        echo "coregen failed for $rel (rc=$rc), see $LOG/$name.log"
        return 94
    fi
    echo "coregen ok: $rel.xco"
}

# One job per directory: its cores one after the other.
pids=""
for dir in $(for rel in $cores; do dirname "$rel"; done | sort -u); do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 1; done
    (
        for rel in $cores; do
            [ "$(dirname "$rel")" = "$dir" ] || continue
            regen "$rel" || exit $?
        done
    ) &
    pids="$pids $!"
done
status=0
for p in $pids; do
    wait "$p"
    rc=$?
    [ $rc -eq 0 ] || [ $status -ne 0 ] || status=$rc
done
exit $status
