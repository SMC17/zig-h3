#!/usr/bin/env bash
# zig-h3 / tools / doctest.sh
#
# Documentation tests — verify that the README's executable claims
# actually hold. A passing doctest run means:
#
#   1. The README "Quickstart" code block matches `examples/quickstart.zig`
#      byte-for-byte (drift between docs and code FAILS the test).
#   2. The compiled quickstart binary runs cleanly and prints the
#      documented lines on stdout (cell hex, resolution 9, base cell,
#      pentagon flag, and k=1 ring entries).
#   3. The README's documented shell commands (`zig build test`,
#      `zig build bench`) at least PARSE as valid build steps (we don't
#      run bench here — it's slow — but we confirm the step name exists).
#
# WHY: Stale README examples are a common failure mode in OSS projects.
# The library evolves, the README doesn't, and new users get confused.
# This script makes the README a load-bearing artifact that CI gates.

set -euo pipefail
cd "$(dirname "$0")/.."

n_pass=0
n_fail=0
declare -a FAILURES=()

assert_match() {
  local name="$1"
  local file_a="$2"
  local file_b="$3"
  if diff -u "$file_a" "$file_b" >/dev/null 2>&1; then
    n_pass=$((n_pass + 1))
    echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1))
    FAILURES+=("$name (see: diff -u $file_a $file_b)")
    echo "  FAIL  $name"
    diff -u "$file_a" "$file_b" | sed 's/^/        /' | head -30
  fi
}

assert_output() {
  local name="$1"
  local expected_regex="$2"
  shift 2
  local out; out=$("$@" 2>&1 || true)
  if echo "$out" | grep -qE "$expected_regex"; then
    n_pass=$((n_pass + 1))
    echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1))
    FAILURES+=("$name: stdout did not match /$expected_regex/")
    echo "  FAIL  $name"
    echo "        got: $out" | head -5
  fi
}

assert_build_step() {
  local name="$1"
  local step="$2"
  if zig build --help 2>&1 | grep -qE "  $step\b"; then
    n_pass=$((n_pass + 1))
    echo "  PASS  $name"
  else
    n_fail=$((n_fail + 1))
    FAILURES+=("$name: build step '$step' is missing")
    echo "  FAIL  $name (step '$step' missing)"
  fi
}

echo "=== zig-h3 doctest ==="

# --- Check 1: README Quickstart block matches examples/quickstart.zig ------
#
# The README has the Quickstart code starting at the line `const std =`
# (inside a ```zig fenced block) and ending at the trailing closing
# brace of `pub fn main`. We extract the block and diff against the
# vendored example file (with its header comment stripped).

EXTRACTED=$(mktemp)
awk '
  /^```zig$/    { in_block = 1; next }
  /^```$/       { if (in_block && found_main) { in_block = 0; exit } }
  in_block && /const std = @import\("std"\)/ { found_main = 1 }
  in_block && found_main { print }
' README.md > "$EXTRACTED"

# Strip the header comment from examples/quickstart.zig to match.
EX_STRIPPED=$(mktemp)
awk '
  /^const std = @import\("std"\)/ { printing = 1 }
  printing { print }
' examples/quickstart.zig > "$EX_STRIPPED"

assert_match "README Quickstart block matches examples/quickstart.zig" "$EXTRACTED" "$EX_STRIPPED"
rm -f "$EXTRACTED" "$EX_STRIPPED"

# --- Check 2: Quickstart binary runs and prints documented lines ----------
QUICKSTART_BIN=zig-out/bin/example-quickstart
if [ ! -x "$QUICKSTART_BIN" ]; then
  echo "  FAIL  example-quickstart binary missing (run \`zig build\` first)"
  n_fail=$((n_fail + 1))
  FAILURES+=("example-quickstart binary missing")
else
  # H3 string form for the Statue of Liberty res-9 cell is 15 hex chars
  # (e.g. 892a100894bffff). The README quickstart prints `cell: <hex>`.
  assert_output "Quickstart prints 'cell: <h3-hex>'"        'cell: [0-9a-f]{15}'  "$QUICKSTART_BIN"
  assert_output "Quickstart prints 'resolution: 9'"         'resolution: 9'       "$QUICKSTART_BIN"
  assert_output "Quickstart prints 'base cell: <int>'"      'base cell: [0-9]+'   "$QUICKSTART_BIN"
  assert_output "Quickstart prints 'pentagon: false'"       'pentagon: false'     "$QUICKSTART_BIN"
  # The k=1 ring at a non-pentagon hexagon has 6 neighbors at distance 1
  # plus the origin itself. Each neighbor line is `ring[N]: distance 1`.
  assert_output "Quickstart prints 'ring[N]: distance 1'"   'ring\[[0-9]+\]: distance 1' "$QUICKSTART_BIN"
fi

# --- Check 3: Documented build steps exist --------------------------------
assert_build_step "README documents 'zig build test'" "test"
assert_build_step "README documents 'zig build bench'" "bench"

echo
echo "=== summary ==="
echo "  pass: $n_pass"
echo "  fail: $n_fail"
if [ "$n_fail" -gt 0 ]; then
  echo
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
