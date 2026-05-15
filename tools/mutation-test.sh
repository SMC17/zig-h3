#!/usr/bin/env bash
# zig-h3 / tools / mutation-test.sh
#
# Stylized mutation-testing harness for zig-h3 pure-Zig H3 implementation.
# Adapted from the zig-cobs / zig-frame-protocol / sentinel-sbom templates.
#
# Each mutation is applied to a fresh copy of the source, the full test
# suite runs (currently 169 tests across libh3-wrapper + pure-Zig +
# 10,392-trial property invariant harness + 2,000-trial polygon round-trip
# property), and the exit code determines killed/survived.
#
# Mutation targets span the layers that matter for an H3 implementation:
#   - resolution-domain guards (latLngToCell / cellToParent)
#   - the isValidCell predicate's sub-conditions (high bit, reserved bits,
#     base cell range, digit range, pentagon-base-cell, K-axis "deleted
#     subsequence" rule)
#   - the isPentagon predicate
#   - grid-disk / grid-ring k<0 guards
#   - gridPathCellsSize off-by-one (dist + 1)
#   - ijkDistance @max selection
#   - isClassIII parity check
#   - point-in-polygon ray-cast strict-inequality and degenerate-loop guard

set -euo pipefail
cd "$(dirname "$0")/.."

declare -A SRC_BACKUPS=()
declare -a SRC_FILES=(
  "src/pure.zig"
  "src/pure_h3index.zig"
  "src/pure_hierarchy.zig"
  "src/pure_grid.zig"
  "src/pure_localij.zig"
  "src/pure_polygon.zig"
  "src/pure_boundary.zig"
)

for f in "${SRC_FILES[@]}"; do
  SRC_BACKUPS["$f"]=$(mktemp)
  cp "$f" "${SRC_BACKUPS[$f]}"
done

restore_all() {
  for f in "${SRC_FILES[@]}"; do
    cp "${SRC_BACKUPS[$f]}" "$f"
    rm -f "${SRC_BACKUPS[$f]}"
  done
}
trap restore_all EXIT

# Format: "description|target_file|sed expression"
declare -a MUTATIONS=(
  # ── Resolution-domain guards ──────────────────────────────────────────────
  "M01 (h3index): latLngToCell res-domain check < -> <= (off-by-one at res=0)|src/pure_h3index.zig|s|if (res < 0 or res > MAX_RES) return Error.ResolutionDomain;|if (res <= 0 or res > MAX_RES) return Error.ResolutionDomain;|"
  "M02 (h3index): latLngToCell res-domain check > -> >= (off-by-one at MAX_RES)|src/pure_h3index.zig|s|if (res < 0 or res > MAX_RES) return Error.ResolutionDomain;|if (res < 0 or res >= MAX_RES) return Error.ResolutionDomain;|"
  "M03 (hierarchy): cellToParent res-domain check > -> >= (off-by-one at MAX_RES)|src/pure_hierarchy.zig|s|if (parent_res < 0 or parent_res > MAX_RES) return Error.ResolutionDomain;|if (parent_res < 0 or parent_res >= MAX_RES) return Error.ResolutionDomain;|"
  "M04 (hierarchy): hasChildAtRes upper bound <= -> < (off-by-one at MAX_RES)|src/pure_hierarchy.zig|s|return child_res >= parent_res and child_res <= MAX_RES;|return child_res >= parent_res and child_res < MAX_RES;|"

  # ── isValidCell sub-conditions ────────────────────────────────────────────
  "M05 (pure): isValidCell high-bit check != -> == (accept high-bit-set cells)|src/pure.zig|s|if (getHighBit(cell) != 0) return false;|if (getHighBit(cell) == 0) return false;|"
  "M06 (pure): isValidCell reserved-bits check != -> == (accept reserved-bits-set cells)|src/pure.zig|s|if (getReservedBits(cell) != 0) return false;|if (getReservedBits(cell) == 0) return false;|"
  "M07 (pure): isValidCell base-cell upper bound >= -> > (off-by-one at RES0_CELL_COUNT)|src/pure.zig|s|if (bc < 0 or bc >= RES0_CELL_COUNT) return false;|if (bc < 0 or bc > RES0_CELL_COUNT) return false;|"
  "M08 (pure): isValidCell digit-range >= -> > (accept digit==INVALID_DIGIT mid-resolution)|src/pure.zig|s|if (digit >= INVALID_DIGIT) return false;|if (digit > INVALID_DIGIT) return false;|"

  # ── isPentagon predicate ──────────────────────────────────────────────────
  "M09 (pure): isPentagon base-cell sense flip ! -> identity (accept non-pentagon base cells)|src/pure.zig|s|if (!isPentagonBaseCell(bc)) return false;|if (isPentagonBaseCell(bc)) return false;|"
  "M10 (pure): isPentagon non-zero-digit check != -> == (claim all-nonzero-digit cells are pentagons)|src/pure.zig|s|if (getCellDigit(cell, r) != 0) return false;|if (getCellDigit(cell, r) == 0) return false;|"

  # ── Grid disk / ring guards (both gridDiskUnsafe and gridRingUnsafe) ──────
  "M11 (grid): gridDisk/Ring k<0 check < -> <= (reject k=0 too)|src/pure_grid.zig|s|if (k < 0) return Error.Domain;|if (k <= 0) return Error.Domain;|"

  # ── Grid path size off-by-one ─────────────────────────────────────────────
  "M12 (localij): gridPathCellsSize dist+1 -> dist+0 (off-by-one path length)|src/pure_localij.zig|s|return dist + 1;|return dist + 0;|"

  # ── ijkDistance: @max selection (drop the k-axis)  ────────────────────────
  "M13 (localij): ijkDistance drops k-axis from @max chain|src/pure_localij.zig|s|return @max(ai, @max(aj, ak));|return @max(ai, aj);|"

  # ── isClassIII parity flip ────────────────────────────────────────────────
  "M14 (boundary): isClassIII parity == 1 -> == 0 (flip class III/II sense)|src/pure_boundary.zig|s|return (@mod(res, 2)) == 1;|return (@mod(res, 2)) == 0;|"

  # ── Point-in-polygon ray-cast logic ───────────────────────────────────────
  "M15 (polygon): pointInsideGeoLoop strict < -> <= (boundary-point sense flip)|src/pure_polygon.zig|s|if (p_lng < intersect_lng) contains = !contains;|if (p_lng <= intersect_lng) contains = !contains;|"
  "M16 (polygon): degenerate-loop guard n < 3 -> n > 3 (accept 0/1/2-vertex loops)|src/pure_polygon.zig|s|if (n < 3) return false;|if (n > 3) return false;|"
)

n_total=${#MUTATIONS[@]}
n_killed=0
n_survived=0
declare -a SURVIVORS=()

echo "=== zig-h3 mutation testing ==="
echo "src files: ${SRC_FILES[*]}"
echo "operators: $n_total stylized mutations"
echo "test cmd: zig build test"
echo

for mutation in "${MUTATIONS[@]}"; do
  desc="${mutation%%|*}"
  rest="${mutation#*|}"
  target_file="${rest%%|*}"
  sed_expr="${rest#*|}"

  # Restore all source files first, then apply this single mutation.
  for f in "${SRC_FILES[@]}"; do cp "${SRC_BACKUPS[$f]}" "$f"; done

  sed -i "$sed_expr" "$target_file"

  if cmp -s "${SRC_BACKUPS[$target_file]}" "$target_file"; then
    echo "  SKIPPED   $desc"
    echo "            (sed expression matched 0 lines — mutation is a no-op)"
    n_total=$((n_total - 1))
    continue
  fi

  # 180s hard timeout protects against mutations that induce infinite loops
  # in test paths (e.g. an `isClassIII` parity flip can spin in recursive
  # grid traversal); SIGTERM → non-zero exit → counted as KILLED, which is
  # the correct semantics for a mutation the suite cannot complete on.
  if timeout 180 zig build test >/dev/null 2>&1; then
    n_survived=$((n_survived + 1))
    SURVIVORS+=("$desc")
    echo "  SURVIVED  $desc"
  else
    n_killed=$((n_killed + 1))
    echo "  KILLED    $desc"
  fi
done

for f in "${SRC_FILES[@]}"; do cp "${SRC_BACKUPS[$f]}" "$f"; done

echo
echo "=== summary ==="
echo "  total effective mutations: $n_total"
echo "  killed:                    $n_killed"
echo "  survived:                  $n_survived"

if [ "$n_total" -gt 0 ]; then
  score=$(awk -v k="$n_killed" -v t="$n_total" 'BEGIN{printf "%.1f", k/t*100}')
  echo "  mutation score:            $score%"
fi

if [ "$n_survived" -gt 0 ]; then
  echo
  echo "Survivors (test-suite blind spots):"
  for s in "${SURVIVORS[@]}"; do
    echo "  - $s"
  done
  exit 1
fi

exit 0
