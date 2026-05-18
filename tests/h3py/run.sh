#!/usr/bin/env bash
# tests/h3py/run.sh — second-reference differential. zig-h3 vs h3-py.
#
# zig-h3's existing tests cross-validate the pure-Zig backend against the
# vendored libh3 C library — that's the FIRST reference. This script
# additionally cross-checks against h3-py (Uber's official Python binding)
# — the SECOND reference — to confirm that the wrapper-level glue
# (argument marshalling, return-value handling, string conversion) matches
# what an external consumer sees.
#
# Requires h3-py installed via `pip install h3` (works in any venv).
# Optionally honor $PYTHON to pick a venv interpreter, falling back to
# python3 on PATH.

set -euo pipefail

PY="${PYTHON:-python3}"
SELF_DIR=$(cd "$(dirname "$0")" && pwd)

# Build the differential binary if not already.
if [[ ! -x ./zig-out/bin/h3py-diff ]]; then
    echo "building h3py-diff..."
    zig build h3py-diff-install
fi

# Run the zig side, capturing per-fixture output.
zig_out=$(./zig-out/bin/h3py-diff)

# Now run the h3-py oracle on the same fixtures. We extract the
# (label, lat, lng, res) tuples from the zig source and ask h3-py to
# compute the same answers.
py_out=$("$PY" <<PYEOF
import h3, math

FIXTURES = [
    ("sf-pier-39",         0.65993, -2.13649, 9),
    ("nyc-times-sq",       0.71135, -1.29135, 9),
    ("london-westminster", 0.89884, -0.00218, 9),
    ("tokyo-shibuya",      0.62236,  2.43824, 9),
    ("sydney-opera",      -0.59093,  2.63920, 9),
    ("sf-res-0",           0.65993, -2.13649, 0),
    ("sf-res-5",           0.65993, -2.13649, 5),
    ("sf-res-12",          0.65993, -2.13649, 12),
]

for label, lat_rad, lng_rad, res in FIXTURES:
    lat_deg = math.degrees(lat_rad)
    lng_deg = math.degrees(lng_rad)
    cell = h3.latlng_to_cell(lat_deg, lng_deg, res)
    cell_int = int(cell, 16)
    print(f"{label} cell={cell_int:x}")
    print(f"{label} resolution={h3.get_resolution(cell)}")
    print(f"{label} pentagon={int(h3.is_pentagon(cell))}")
PYEOF
)

if [[ "$zig_out" == "$py_out" ]]; then
    fixtures=$(echo "$zig_out" | wc -l)
    echo "PASS: zig-h3 vs h3-py — $fixtures lines match byte-for-byte across 8 fixtures"
    exit 0
else
    echo "FAIL: zig-h3 vs h3-py differential mismatch:"
    diff <(echo "$zig_out") <(echo "$py_out")
    exit 1
fi
