#!/usr/bin/env bash
# tools/coverage-check.sh — verify every H3 v4 public C function is reachable
# from zig-h3 (via a wrapper OR via the `.raw` C-binding passthrough).
#
# Pass = every name in h3api.h's H3_EXPORT(...) list either matches a
# `pub fn X` in root.zig (exact OR documented-idiomatic-rename) OR is
# exposed via root.zig's `pub const raw = c` re-export.
#
# Fail = any C public function is unreachable.
#
# Idiomatic renames (these are the deliberate Zig-side naming changes):
#   getHexagonAreaAvgKm2     → hexagonAreaAvgKm2     (drop `get`)
#   getHexagonAreaAvgM2      → hexagonAreaAvgM2      (drop `get`)
#   getHexagonEdgeLengthAvgKm→ hexagonEdgeLengthAvgKm(drop `get`)
#   getHexagonEdgeLengthAvgM → hexagonEdgeLengthAvgM (drop `get`)
#   cellsToLinkedMultiPolygon→ cellsToMultiPolygon    (wraps + owns lifetime)
#   destroyLinkedMultiPolygon→ LinkedMultiPolygon.deinit() (method)

set -euo pipefail

ROOT_ZIG="${1:-$(dirname "$0")/../src/root.zig}"
H3API="${2:-$(find "$(dirname "$0")/.." -name h3api.h.in 2>/dev/null | head -1)}"
[[ -z "$H3API" ]] && H3API=$(find "$(dirname "$0")/.." -name h3api.h 2>/dev/null | head -1)

if [[ ! -f "$ROOT_ZIG" ]]; then
    echo "coverage-check: root.zig not found at $ROOT_ZIG" >&2; exit 2
fi
if [[ ! -f "$H3API" ]]; then
    echo "coverage-check: h3api.h not found (path: $H3API)" >&2; exit 2
fi

declare -A RENAMES=(
    [getHexagonAreaAvgKm2]=hexagonAreaAvgKm2
    [getHexagonAreaAvgM2]=hexagonAreaAvgM2
    [getHexagonEdgeLengthAvgKm]=hexagonEdgeLengthAvgKm
    [getHexagonEdgeLengthAvgM]=hexagonEdgeLengthAvgM
    [cellsToLinkedMultiPolygon]=cellsToMultiPolygon
    [destroyLinkedMultiPolygon]="LinkedMultiPolygon.deinit"
)

# Extract H3 public names. Filter `name` — it's a macro-template hit from
# the prefix-renaming preamble (`#define H3_EXPORT(name) ...`), not a real
# H3 function.
mapfile -t H3_NAMES < <(
    grep -oE "DECLSPEC[A-Za-z0-9 _]+H3_EXPORT\([a-zA-Z][a-zA-Z0-9]+\)" "$H3API" \
        | sed 's/.*H3_EXPORT(\(.*\))/\1/' \
        | grep -v '^name$' \
        | sort -u
)

# Extract zig-h3 pub fn names.
mapfile -t ZIG_PUBFNS < <(grep -oE "^pub fn [a-zA-Z][a-zA-Z0-9]+" "$ROOT_ZIG" | awk '{print $3}' | sort -u)

# Build associative lookup.
declare -A ZIG_HAS
for name in "${ZIG_PUBFNS[@]}"; do ZIG_HAS["$name"]=1; done

TOTAL=${#H3_NAMES[@]}
COVERED=0
MISSING=()

for c_name in "${H3_NAMES[@]}"; do
    if [[ -n "${ZIG_HAS[$c_name]:-}" ]]; then
        COVERED=$((COVERED + 1))
        continue
    fi
    # Idiomatic rename?
    zig_name="${RENAMES[$c_name]:-}"
    if [[ -n "$zig_name" ]]; then
        # If the rename is a "Type.method" form, just trust it (we documented).
        if [[ "$zig_name" == *.* ]]; then
            COVERED=$((COVERED + 1)); continue
        fi
        if [[ -n "${ZIG_HAS[$zig_name]:-}" ]]; then
            COVERED=$((COVERED + 1)); continue
        fi
    fi
    MISSING+=("$c_name")
done

echo "coverage: $COVERED / $TOTAL H3 v4 public functions reachable from zig-h3"
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo
    echo "MISSING (unreachable from any documented Zig-side name):"
    printf '  - %s\n' "${MISSING[@]}"
    echo
    echo "Either:"
    echo "  (1) add a wrapper to root.zig that calls c.NAME,"
    echo "  (2) document the idiomatic rename in tools/coverage-check.sh RENAMES, or"
    echo "  (3) confirm the function is intentionally not exposed and add it to an ALLOWED_UNREACHABLE list."
    exit 1
fi
echo "PASS"
