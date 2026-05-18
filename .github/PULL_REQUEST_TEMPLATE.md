<!--
Thanks for the PR. A few load-bearing checks before merge:
- `zig build test --summary all` passes (all 211+ tests, all 27 000+ executed cases)
- `tools/coverage-check.sh` still reports 70/70 public functions reachable
- If touching the C-ABI shim: re-run all 4 binding test suites locally
  (Python, Go, Rust, Node) — see docs/bindings/
- If touching perf: include `bench/results/` output before + after

Doc-test drift catches inconsistencies between README and code; CI runs it.
-->

## Summary

<!-- 1-3 bullets on what changed and why. -->

## Test plan

<!-- How did you verify? Be specific. -->
- [ ] `zig build test --summary all` passes
- [ ] `tools/coverage-check.sh` still reports 70/70
- [ ] Bench numbers don't regress (if perf-related)
- [ ] Binding tests pass (if cabi-related)

## Type of change

- [ ] Bug fix (existing function returns wrong output)
- [ ] New function (libh3 parity OR beyond-libh3)
- [ ] New binding language
- [ ] Performance improvement
- [ ] Documentation
- [ ] Build / CI / governance

## Breaking change?

- [ ] Yes — API stability commitment (API_STABILITY.md) requires a major bump
- [ ] No — semver-minor or patch

## BAKEOFF axis touched

<!-- Which of the 13 BAKEOFF axes does this advance or regress? Cite the line in BAKEOFF.md. -->
