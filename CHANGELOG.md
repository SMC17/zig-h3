## v1.0.0 — 2026-05-13

**Production-grade hygiene milestone.**

- Added SECURITY.md (coordinated disclosure policy).
- Verified LICENSE, README, CONTRIBUTING, CODE_OF_CONDUCT, CI workflow all in place and accurate.
- API surface declared stable for the v1.x cycle. Breaking changes will bump to v2.x.
- Engineering posture: Virgil work-in-progress convention adapted for OSS — v1.0 means we stand behind the existing surface; v1.x patches refine implementation without breaking the API.

# Changelog

All notable changes to `zig-h3` are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-05-13

Initial release. Idiomatic Zig wrapper around Uber's `libh3` v4.1.0,
fetched and compiled transparently via the Zig package manager. Includes
a parallel pure-Zig track (`src/pure.zig`) covering the projection-free
subset of the API, every function cross-validated against libh3.

### Added
- `LatLng` extern struct with `fromDegrees`, `latDegrees`, `lngDegrees`
  helpers. Bit-compatible with `libh3.LatLng`.
- `CellBoundary` extern struct with `slice()` helper that returns
  `verts[0..num_verts]`. Bit-compatible with `libh3.CellBoundary`.
- `H3Index` (alias for `u64`), `H3_NULL`, `MAX_CELL_BOUNDARY_VERTS`,
  `MAX_RES` constants.
- `Error` enum covering all 15 documented `H3ErrorCodes` plus an
  `Unknown` fallback.
- Lat/lng ↔ cell: `latLngToCell`, `cellToLatLng`, `cellToBoundary`.
- Inspection: `getResolution`, `getBaseCellNumber`, `isValidCell`,
  `isPentagon`, `isResClassIII`, `areNeighborCells`, `maxFaceCount`.
- Hierarchy: `cellToParent`, `cellToCenterChild`, `cellToChildrenSize`,
  `cellToChildren`.
- Grid traversal: `maxGridDiskSize`, `gridDisk`, `gridDistance`.
- Formatting: `h3ToString`, `stringToH3`.
- Distance: `degsToRads`, `radsToDegs`, `greatCircleDistanceRads`,
  `greatCircleDistanceKm`, `greatCircleDistanceM`.
- Area: `cellAreaRads2`, `cellAreaKm2`, `cellAreaM2`,
  `hexagonAreaAvgKm2`, `hexagonAreaAvgM2`, `hexagonEdgeLengthAvgKm`,
  `hexagonEdgeLengthAvgM`.
- Metadata: `getNumCells`, `res0CellCount`, `pentagonCount`,
  `getRes0Cells`, `getPentagons`.
- `raw` export exposing the full `@cImport` namespace so callers can
  reach unwrapped functions today and PR idiomatic wrappers.
- 24 unit tests including closed-form verification (k-ring size,
  resolution cell count), hierarchical roundtrip (7² children),
  great-circle distance (SF → NYC), and base-cell / pentagon
  enumeration sanity checks.

### Build
- Declares `h3c` dependency in `build.zig.zon` pointing at the
  upstream `uber/h3` v4.1.0 release tarball, hash-pinned.
- `build.zig` substitutes CMake placeholders in `h3api.h.in` via
  `addConfigHeader`, compiles 18 libh3 C source files into a static
  library, and exposes the wrapper module with the C library linked.

### Pure-Zig (Phase 1)

`pub const pure = @import("pure.zig")` exposes a growing pure-Zig
reimplementation. Every function is cross-validated against the libh3
equivalent in the same test run.

- `pure.degsToRads` / `pure.radsToDegs` — multiplied by libh3's exact
  `M_PI_180` / `M_180_PI` constants (matched within 4 ULPs across
  `[-360°, 360°]` and `[-2π, 2π]` respectively; ULP-level deviation
  comes from `long double` intermediate precision on platforms with
  x87, not from a different formula).
- `pure.getResolution` / `pure.getBaseCellNumber` / `pure.isResClassIII`
  / `pure.getCellDigit` — bit extraction from the H3 index format.
  Matched exactly against libh3 across all 16 resolutions on 200+
  random cells.
- `pure.isPentagon` — base-cell-table lookup + zero-digit walk. Matched
  against libh3 on every res-0 base cell and every res-0..5 pentagon,
  plus random fine cells.
- `pure.res0CellCount`, `pure.pentagonCount`, `pure.getNumCells`,
  `pure.maxGridDiskSize` — closed-form counts, matched exactly.
- `pure.greatCircleDistanceRads/Km/M` — haversine. Matched within
  `1e-12` radians (`~1e-9` km).
- `pure.PENTAGON_BASE_CELLS` — verified against `libh3.getPentagons(0)`.

### Pure-Zig (Phase 2 — H3 index format helpers)

- `pure.isValidCell` — full libh3 algorithm: high-bit, mode, reserved-bits,
  base-cell range, resolution range, digit-range scan, pentagon "deleted
  subsequence" rule (a pentagon cannot have `K_AXES_DIGIT` at its first
  non-zero digit position), and unused-digit-slots-equal-`INVALID_DIGIT`
  check. Cross-validated against libh3 on every res-0 base cell, every
  pentagon at every resolution, 500 random valid cells, hand-crafted
  garbage indices (zero, all-ones, bad mode, nonzero reserved), and
  specific corruption fixtures (digit poisoning past resolution; pentagon
  with forced K-axis first digit).
- `pure.h3ToString` — `std.fmt.bufPrint("{x}")`, matched byte-for-byte
  against libh3's `sprintf("%llx")` on 200 random cells.
- `pure.stringToH3` — permissive hex parser matching libh3's
  `sscanf("%llx")` behavior: skips leading whitespace, accepts optional
  `0x`/`0X` prefix, consumes maximal hex prefix, rejects 17+ digit
  overflow, rejects empty / whitespace-only / no-digit inputs. Cross-
  validated via roundtrip with `pure.h3ToString` and against libh3 on
  200 random cells, plus explicit fixtures for prefix / whitespace /
  uppercase / max-length input.
- New constants exposed: `pure.CELL_MODE`, `pure.PENTAGON_SKIPPED_DIGIT`,
  `pure.INVALID_DIGIT`.

Roadmap continues in the `pure.zig` module docstring. Phase 3
(icosahedron projection — `latLngToCell`, `cellToLatLng`, `cellToBoundary`,
pentagon distortion handling) is the multi-month substrate where the
real work lives.

### Deferred
- Directed edges, vertices, polygon-to-cells, cells-to-multi-polygon,
  local IJ coordinates, grid path cells, compact / uncompact. The
  raw C functions are reachable via the `raw` export.

### Licensing
- MIT for the wrapper.
- `libh3` is Apache License 2.0 (Copyright Uber Technologies, Inc.);
  upstream `LICENSE` reproduced in `LICENSE-H3-APACHE-2.0`.
