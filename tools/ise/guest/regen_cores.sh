#!/bin/bash
# Generates every Coregen core of an ISE project from its tracked inputs.
#
# Usage: bash tools/ise/guest/regen_cores.sh src/<project>.xise
#
# Inputs:  src/ipcore/<path>/<core>.xco and the coregen.cgp next to it (tracked).
# Output:  src/ipcore_dir/<path>/ (ignored): the paths the .xise refers to; also creates
#          the project's Working Directory.
# A coe_file in the tracked .xco is relative to the directory of that .xco; the
# generated copy gets the absolute path, because Coregen reads it from there.
#
# Optional environment:
#   REGEN_LOG_DIR  log directory (default <repo>/build/logs/coregen)
#
# Exit codes: 0 ok, 90 file system, 91 coregen not found, 92 missing core or input,
#             93 COE file not found, 94 coregen failed.

set -u

XISE="$(readlink -f "${1:?project .xise}")"
SRC="$(dirname "$XISE")"
LOG="${REGEN_LOG_DIR:-$SRC/../build/logs/coregen}"
mkdir -p "$LOG" || exit 90
command -v coregen > /dev/null || { echo "coregen not found: source settings64.sh first"; exit 91; }

# ISE does not open a project whose Working Directory is missing (TclTasksC:project_150);
# create it here, so that the project also opens in the GUI after this script.
wd=$(sed -n 's/.*xil_pn:name="Working Directory" xil_pn:value="\([^"]*\)".*/\1/p' "$XISE")
mkdir -p "$SRC/${wd:-.}" || exit 90

cores=$(grep -o 'xil_pn:name="ipcore_dir/[^"]*\.xco"' "$XISE" | sed 's/^xil_pn:name="ipcore_dir\///; s/"$//')
[ -n "$cores" ] || { echo "no Coregen cores in $XISE"; exit 92; }

for rel in $cores; do
    in="$SRC/ipcore/$(dirname "$rel")"
    out="$SRC/ipcore_dir/$(dirname "$rel")"
    name=$(basename "$rel" .xco)
    if [ ! -f "$in/$name.xco" ] || [ ! -f "$in/coregen.cgp" ]; then
        echo "missing input for $rel: $in/$name.xco and $in/coregen.cgp"
        exit 92
    fi
    mkdir -p "$out" || exit 90
    cp "$in/$name.xco" "$in/coregen.cgp" "$out/" || exit 90
    coe=$(sed -n 's/^CSET coe_file=//p' "$in/$name.xco" | tr -d '\r')
    # Coregen writes "no_coe_file_loaded" for a memory without an initialisation file.
    if [ -n "$coe" ] && [ "${coe#no_}" = "$coe" ]; then
        abs=$(cd "$in" && readlink -f "$coe")
        if [ ! -f "$abs" ]; then
            echo "COE file not found for $rel: $coe"
            exit 93
        fi
        sha256sum "$abs" >> "$LOG/coe.sha256"
        sed -i "s#^CSET coe_file=.*#CSET coe_file=$abs#" "$out/$name.xco"
    fi
    ( cd "$out" && coregen -p coregen.cgp -b "$name.xco" -r -intstyle xflow ) > "$LOG/$name.log" 2>&1
    rc=$?
    if [ $rc -ne 0 ] || grep -q '^ERROR:' "$LOG/$name.log"; then
        echo "coregen failed for $rel (rc=$rc), see $LOG/$name.log"
        exit 94
    fi
    echo "coregen ok: $rel"
done
