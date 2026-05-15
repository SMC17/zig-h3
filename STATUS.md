# zig-h3 status

Last touched: 2026-05-15

## Honest version posture

Despite the `v1.2.1` git tag, this project is **pre-1.0 in semver
spirit** for two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the Zig language hits 1.0,
   no Zig library can credibly claim API stability beyond "stable on
   Zig 0.16 today." Tagging v1.x against a pre-1.0 substrate is a
   vanity claim — the language guarantees aren't there yet.
2. **No production deployment exists.** This library has zero
   real-traffic operation, zero soak time, zero production-incident
   history. "Production-grade hygiene milestone" describes shipping
   process (LICENSE / SECURITY / CONTRIBUTING / CI / CODE_OF_CONDUCT)
   — necessary but **not sufficient** for "production-grade."

The hygiene work is real. The v1.x tags will be honored for changelog
continuity. But every reader should treat this as a pre-1.0 substrate
until both gates above close.

A second axis of caveat: this library is a **Zig client of libh3
v4.1.0** — not a libh3 substitute. The wrapper layer + pure-Zig
cross-validation track are the engineered surface; everything geospatially
load-bearing routes through Uber's C implementation. `BAKEOFF.md`
audits the 11 categories where uber/h3 leads decisively. Read it
before treating zig-h3 as a libh3 replacement.

## Proof-vocabulary index (per `~/AGENT_HARNESS.md`)

| component                       | proof level                  | evidence                                                                                                                                                          |
|---------------------------------|------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Wrapper surface (`latLngToCell` / `cellToLatLng` / hierarchy / grid / polygon, 70/70 H3 v4 functions) | `unit-tested` + `audited` against libh3 | `zig build test` 180/180 pass; `tools/coverage-check.sh` asserts every `H3_EXPORT(...)` in `h3api.h` resolves to a wrapper or `raw` re-export                     |
| Property-invariant harness (`src/property_invariants.zig`) | `audited` (self-consistent) | `MIN_TOTAL_TRIALS = 10_000`; actual run reports `[property_invariants] total trials: 10392` (8000 geo across 16 res + 200 pentagon walks + 2000 synth + drift)     |
| Polygon round-trip property (`src/property_polygon_test.zig`) | `audited` (self-consistent) | `PROP_A_TRIALS = 2_000`; run reports `passed: 1999, pentagon skips: 0, antimeridian skips: 1, superset misses: 0`; Property B sweeps 610 (122×5) base-cell trials |
| Mutation harness (`tools/mutation-test.sh`) | `audited` (one HW class, one Zig version) | 16 mutation operators defined (`M01`..`M16`); 16/16 killed after M07/M08 `isValidCell` regressions (commit `88afd31`) and M15 `pointInsideGeoLoop` half-open boundary closure (commit `d729cd2`) |
| `cellAreaKm2` numeric tolerance | `unit-tested` (sampled)      | `src/pure_boundary.zig` tolerance schedule: hex rads² / km² compared at `1e-8` relative (15 trials × 7 even-step resolutions); pentagons at `1e-6` relative (12 pentagons at res 5) — the looser pentagon bound is itself the finding, not a hidden assumption |
| Fuzz path (`src/pure.zig`)      | `audited` (self-consistent)  | `fuzz_iters: usize = 10_000` random-u64 inputs through the pure parser; zero panics; explicit NaN/Inf rejection                                                   |
| Cross-architecture build        | `compiled` (CI only)         | CI matrix in `.github/workflows/` covers Linux x86_64 + Linux aarch64 + macOS arm64; no behavior assertions on the non-primary targets                            |
| README ↔ code drift             | `unit-tested` (partial)      | `tools/coverage-check.sh` covers the H3 public-function enumeration; the README's `180 tests` line is currently drifted on the `feat/wrap-final-6-h3-functions` worktree (172 there) — fixed forward via the existing doc-lag pattern, not by this audit |

## Gates that would justify a stronger claim

- **G1 — Exhaustive resolution sweep.** All 122 base cells × all 16
  resolutions × ≥1000 random lat/lng per resolution × load-bearing
  property (round-trip, parent/child, gridDisk symmetry). Status:
  `NOT YET CLOSED`. Current property harness samples 10,392 trials
  total — non-trivial but not exhaustive. uber/h3's suite walks the
  full grid; ours doesn't.
- **G2 — Antimeridian + polar edge coverage.** Lat ∈ {±60°, ±75°,
  ±85°, ±89°} × full resolution sweep. The icosahedron projection
  has seams that a 1e-8 relative tolerance at mid-latitude may not
  catch at the poles. Status: `NOT YET CLOSED`.
- **G3 — Cross-platform behavioral verification (not just compile).**
  macOS arm64 and Linux aarch64 have CI green for `zig build`, but the
  property harness has never been observed to run on those targets.
  Status: `NOT YET CLOSED` (need CI to gate `zig build test` on every
  matrix entry, not just `zig build`).
- **G4 — Soak time.** ≥30 days of continuous use in some real
  spatial workload (orderbook H3 routing, a thermal-grid cell-area
  pipeline, a Lineage map). Status: `NOT YET CLOSED`. The
  orderbook prototype uses zig-h3 but has not run continuously.
- **G5 — Independent review.** A second pair of eyes from someone
  who has shipped H3 in production (Uber, Carto, DoorDash, h3-go
  maintainers). Status: `NOT YET CLOSED`.
- **G6 — Zig 1.0 reaches stable.** The language-level guarantee
  that makes the v1.x tag mean what it says in any other ecosystem.
  Status: `NOT YET CLOSED` (out of this repo's control).

Only after G6 + at least one of G1 / G2 / G3 / G4 / G5 do the words
"production-grade" or "stable v1" honestly fit. Today they do not.
