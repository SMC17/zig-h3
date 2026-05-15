# API stability

zig-h3 follows [Semantic Versioning 2.0.0](https://semver.org/) with
the caveats below.

## Pre-1.0 posture

Despite the `v1.x` tag pattern, this project is **pre-1.0 in semver
spirit** for two independent reasons:

1. **Zig itself is on 0.16, not 1.0.** Until the Zig language hits
   1.0, no Zig project can credibly claim API stability beyond
   "stable on Zig 0.16 today." Tagging v1.x against a pre-1.0
   substrate is a calibration choice — the underlying language
   guarantees aren't there yet.
2. **The vendored libh3 is the authority.** zig-h3 wraps Uber's
   `libh3` v4.1.0. Our `h3.*` API surface tracks libh3's public
   function set. If libh3 v4.2 changes its public API, our wrapper
   layer changes to match — we are NOT a long-term-stable API on
   top of a moving libh3.

The v1.x tags will be honored for changelog continuity.

## Public API (STABLE within v1.x)

The following Zig-side surface is committed:

- `h3.LatLng` extern struct (`lat: f64`, `lng: f64` in radians) and
  its `fromDegrees / latDegrees / lngDegrees` helpers
- `h3.CellBoundary` extern struct
- `h3.H3Index = u64`, `h3.H3_NULL`, `h3.MAX_CELL_BOUNDARY_VERTS`,
  `h3.MAX_RES`
- 70 public functions covering: lat/lng↔cell, hierarchy (parent /
  children / center child / child position), grid traversal (`gridDisk`
  + variants), directed edges, vertices, polygon↔cells, local IJ,
  grid path, compact/uncompact, formatting (h3↔string), distance,
  area, resolution metadata

Full list with documented signatures: see [README.md](README.md).

## Pure-Zig parallel path

`h3.pure.*` / `h3.h3index.*` / `h3.h3decode.*` / `h3.grid.*` /
`h3.hierarchy.*` / `h3.boundary.*` etc. are the pure-Zig
reimplementations cross-validated against libh3. These are **internal
implementation surfaces** — they may be renamed or restructured at any
minor version. Library consumers should call `h3.*` (the unified
wrapper layer) and not the pure modules directly.

## Raw escape hatch

`h3.raw` exposes the raw C bindings from `@cImport("h3api.h")` for
callers that need access to internal helpers or `H3Error` codes
directly. The `raw` surface is best-effort stable but tracks libh3's
ABI; we make no Zig-side promise beyond "passes through to libh3."

## Explicitly UNSTABLE

- The benchmark output format (`bench=NAME ...` lines) — additive
  changes are allowed but the line ordering may shift.
- The internal layout of `h3.LinkedMultiPolygon` (returned by
  `cellsToMultiPolygon`) — call the documented accessors only.
- The error-set membership: `h3.Error` may gain new variants at any
  minor version; handlers should use `else =>` exhaustively.

## Deprecation policy

If a stable surface needs to change:

1. The new surface ships alongside the old in version `vN.M+1` with
   the old marked deprecated in the changelog.
2. The old surface continues to work for at least 6 months OR until
   the next major version, whichever is later.
3. Removal happens only at a major version bump.

## Verification

Releases are double-provenance signed:

- **GPG-signed git tags** — fingerprint
  `079261B06444C6A410B3BE363CFCB60243028886`. Verify with
  `git tag -v v1.X.Y`. Public key at
  [`release-signing.gpg.pub`](release-signing.gpg.pub).
- **Cosign blob signatures** on release tarballs. Verify with:

```sh
cosign verify-blob \
  --key cosign.pub \
  --bundle zig-h3-v1.X.Y.bundle \
  zig-h3-v1.X.Y.tar.gz
```

Public key at [`cosign.pub`](cosign.pub).

## Per-release scope

| Version | Substrate gates                                      | Added                                                |
|---------|------------------------------------------------------|------------------------------------------------------|
| v0.1.0  | initial port; 14 H3 v4 functions                     | first release                                        |
| v1.0.0  | production-grade hygiene milestone                   | LICENSE / SECURITY / CONTRIBUTING / CODE_OF_CONDUCT  |
| v1.1.0  | directed-edge + vertex + polygon + local-IJ + path + compact | 64 of 70 public functions                  |
| v1.2.0  | wrap last 6 functions; 70/70 coverage                | coverage-check.sh regression guard                   |
| v1.3.0  | property invariants + polygon round-trip + mutation harness | BAKEOFF.md + 190/190 tests + double-provenance |
