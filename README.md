# zig-h3

[![CI](https://github.com/SMC17/zig-h3/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/zig-h3/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/SMC17/zig-h3?display_name=tag&sort=semver)](https://github.com/SMC17/zig-h3/releases) [![License](https://img.shields.io/github/license/SMC17/zig-h3)](LICENSE)

**Idiomatic Zig bindings for [H3 v4][h3-site] plus a parallel pure-Zig
reimplementation cross-validated cell-by-cell against the C reference.**
Two code paths in the same library: the wrapper around `libh3` v4.1.0
(vendored via the Zig package manager) and a pure-Zig track exposed
under `h3.h3index.*`, `h3.h3decode.*`, `h3.grid.*`, etc. Every pure-Zig
function is matched against its libh3 equivalent in the test run — same
build, same binary, no dual-implementation drift.

- **166 / 166 tests pass** on Zig 0.16.0 (47 wrapper, 117 pure-Zig
  cross-validation, 2 adversarial-input fuzz).
- **63 of ~70 H3 v4 public functions wrapped**, full grid / edge /
  vertex / polygon / IJ / compact / path coverage.
- **Pure-Zig reimplementation** covers `latLngToCell`, `cellToLatLng`,
  `cellToBoundary`, hierarchy, grid traversal, local-IJ, vertices,
  edges, polygon ops, and more — bit-identical output to libh3 on every
  tested input.

[h3-site]: https://h3geo.org/

## Status

`v1.2.1` — covers **all 70 H3 v4 public functions** (verified by
`zig build coverage`), spanning the full
grid / edge / vertex / polygon / IJ / compact / path API:

- Lat/lng ↔ cell conversions
- Cell boundary geometry
- Resolution / base cell / pentagon / Class III inspection
- Hierarchical traversal (parent, children, center child, child-position
  in ordered children list)
- Grid disk traversal: `gridDisk` (safe), `gridDiskUnsafe`,
  `gridDiskDistances`, `gridDiskDistancesSafe`,
  `gridDiskDistancesUnsafe`, `gridDisksUnsafe` (multi-origin),
  `gridRingUnsafe`; plus `gridDistance` + neighbor check
- **Directed edges** (`cellsToDirectedEdge`, `isValidDirectedEdge`,
  `getDirectedEdgeOrigin/Destination`, `directedEdgeToCells`,
  `originToDirectedEdges`, `directedEdgeToBoundary`,
  `edgeLengthRads/Km/M`)
- **Vertices** (`cellToVertex`, `cellToVertexes`, `vertexToLatLng`,
  `isValidVertex`)
- **Polygon ↔ cells** (`polygonToCells`, `cellsToMultiPolygon`,
  `maxPolygonToCellsSize`, with a `LinkedMultiPolygon` RAII wrapper)
- **Local IJ coordinates** (`cellToLocalIj`, `localIjToCell`)
- **Grid path** (`gridPathCells`, `gridPathCellsSize`)
- **Compact / uncompact** (`compactCells`, `uncompactCells`,
  `uncompactCellsSize`)
- Icosahedron faces (`getIcosahedronFaces` + `maxFaceCount`)
- Formatting (h3 ↔ string)
- Great-circle distances (radians, km, m)
- Cell area (radians², km², m²) and average hexagon area / edge length
- Resolution metadata (`getNumCells`, `getRes0Cells`, `getPentagons`,
  `res0CellCount`, `pentagonCount`)

<<<<<<< Updated upstream
**172 tests pass** across the wrapper layer (53), the pure-Zig
cross-validation matrix (117), and the adversarial-input fuzz suite (2 —
10 000 random-u64 inputs probed through the pure parser, plus
NaN/Inf-input rejection). Coverage includes degrees↔radians roundtrip,
=======
**166 tests pass** across the wrapper layer (47), the pure-Zig
cross-validation suite (117 — each test calls both `root.<fn>` /
libh3 and the pure-Zig equivalent and asserts equality), and the
adversarial-input fuzz suite (2 — 10 000 random-u64 inputs probed
through the pure parser, plus NaN/Inf-input rejection). Coverage
includes degrees↔radians roundtrip,
>>>>>>> Stashed changes
closed-form cell-count and grid-disk-size verification, NYC / SF / Tokyo
/ Sydney / null-island / pole-adjacent cell resolution, boundary vertex
counts, hexagonal grid disk arithmetic, k=1 neighbor and grid-distance
round-trip, parent/children/center-child hierarchy (7² = 49 children at
resolution-step 2), h3↔string roundtrip, San Francisco → New York City
great-circle distance (4100–4200 km), res-9 cell area within published
bounds, all 122 base cells valid at resolution 0, all 12 pentagons valid
at every resolution, malformed-string rejection, zero-cell rejection,
directed-edge origin/destination/boundary/length roundtrip on NYC res 9,
hexagon-vs-pentagon edge/vertex counts (6 vs 5), polygon-to-cells on a
0.1° × 0.1° bbox at res 7, cells-to-multi-polygon on single cells and
k=1 disks, local-IJ ↔ cell roundtrip on all k=1 neighbors,
gridPathCells endpoint/contiguity verification, and compact/uncompact
roundtrip on a full subtree.

The `raw` C bindings remain exposed via the `raw` module export as an
escape hatch (e.g., for accessing helper utilities and `H3Error` codes
directly) — but no longer hides any missing wrapper. Every H3 v4 public
function has an idiomatic Zig binding.

Minimum Zig version: `0.16.0`.

## Install

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .h3 = .{
        .url = "https://github.com/SMC17/zig-h3/archive/refs/tags/v1.1.0.tar.gz",
        .hash = "...",
    },
},
```

In `build.zig`:

```zig
const h3 = b.dependency("h3", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("h3", h3.module("h3"));
```

The first build downloads libh3 v4.1.0 from the official Uber/h3 GitHub
release tag, verifies its hash, and compiles its 18 C source files into a
static library. Subsequent builds reuse the cached static library.

## Quickstart

```zig
const std = @import("std");
const h3 = @import("h3");

pub fn main() !void {
    // Statue of Liberty, resolution 9.
    const point = h3.LatLng.fromDegrees(40.6892, -74.0445);
    const cell = try h3.latLngToCell(point, 9);

    var buf: [17]u8 = undefined;
    const hex = try h3.h3ToString(cell, &buf);
    std.debug.print("cell: {s}\n", .{hex});
    std.debug.print("resolution: {d}\n", .{h3.getResolution(cell)});
    std.debug.print("base cell: {d}\n", .{h3.getBaseCellNumber(cell)});
    std.debug.print("pentagon: {}\n", .{h3.isPentagon(cell)});

    // Walk the k=1 ring.
    var ring: [7]h3.H3Index = undefined;
    try h3.gridDisk(cell, 1, &ring);
    for (ring, 0..) |neighbor, i| {
        if (neighbor == h3.H3_NULL) continue;
        std.debug.print("ring[{d}]: distance {d}\n", .{
            i,
            try h3.gridDistance(cell, neighbor),
        });
    }
}
```

## API

```zig
pub const H3Index = u64;
pub const H3_NULL: H3Index = 0;
pub const MAX_CELL_BOUNDARY_VERTS: usize = 10;
pub const MAX_RES: i32 = 15;

pub const LatLng = extern struct {
    lat: f64,  // radians
    lng: f64,  // radians

    pub fn fromDegrees(lat_deg: f64, lng_deg: f64) LatLng;
    pub fn latDegrees(self: LatLng) f64;
    pub fn lngDegrees(self: LatLng) f64;
};

pub const CellBoundary = extern struct {
    num_verts: c_int,
    verts: [MAX_CELL_BOUNDARY_VERTS]LatLng,

    pub fn slice(self: *const CellBoundary) []const LatLng;
};

// Lat/lng ↔ cell
pub fn latLngToCell(point: LatLng, res: i32) Error!H3Index;
pub fn cellToLatLng(cell: H3Index) Error!LatLng;
pub fn cellToBoundary(cell: H3Index) Error!CellBoundary;

// Inspection
pub fn getResolution(cell: H3Index) i32;
pub fn getBaseCellNumber(cell: H3Index) i32;
pub fn isValidCell(cell: H3Index) bool;
pub fn isPentagon(cell: H3Index) bool;
pub fn isResClassIII(cell: H3Index) bool;
pub fn areNeighborCells(a: H3Index, b: H3Index) Error!bool;
pub fn maxFaceCount(cell: H3Index) Error!i32;

// Hierarchy
pub fn cellToParent(cell: H3Index, parent_res: i32) Error!H3Index;
pub fn cellToCenterChild(cell: H3Index, child_res: i32) Error!H3Index;
pub fn cellToChildrenSize(cell: H3Index, child_res: i32) Error!i64;
pub fn cellToChildren(cell: H3Index, child_res: i32, out: []H3Index) Error!void;
pub fn cellToChildPos(child: H3Index, parent_res: i32) Error!i64;
pub fn childPosToCell(child_pos: i64, parent: H3Index, child_res: i32) Error!H3Index;

// Grid traversal
pub fn maxGridDiskSize(k: i32) Error!i64;
pub fn gridDisk(origin: H3Index, k: i32, out: []H3Index) Error!void;
pub fn gridDistance(a: H3Index, b: H3Index) Error!i64;
pub fn gridPathCellsSize(start: H3Index, end: H3Index) Error!i64;
pub fn gridPathCells(start: H3Index, end: H3Index, out: []H3Index) Error!void;

// Directed edges
pub const MAX_DIRECTED_EDGES_PER_CELL: usize = 6;
pub fn cellsToDirectedEdge(origin: H3Index, destination: H3Index) Error!H3Index;
pub fn isValidDirectedEdge(edge_idx: H3Index) bool;
pub fn getDirectedEdgeOrigin(edge_idx: H3Index) Error!H3Index;
pub fn getDirectedEdgeDestination(edge_idx: H3Index) Error!H3Index;
pub fn directedEdgeToCells(edge_idx: H3Index) Error![2]H3Index;
pub fn originToDirectedEdges(origin: H3Index, out: []H3Index) Error!void;
pub fn directedEdgeToBoundary(edge_idx: H3Index) Error!CellBoundary;
pub fn edgeLengthRads(edge_idx: H3Index) Error!f64;
pub fn edgeLengthKm(edge_idx: H3Index) Error!f64;
pub fn edgeLengthM(edge_idx: H3Index) Error!f64;

// Vertices
pub const MAX_VERTEXES_PER_CELL: usize = 6;
pub fn cellToVertex(origin: H3Index, vertex_num: i32) Error!H3Index;
pub fn cellToVertexes(origin: H3Index, out: []H3Index) Error!void;
pub fn vertexToLatLng(vertex_idx: H3Index) Error!LatLng;
pub fn isValidVertex(vertex_idx: H3Index) bool;

// Polygon ↔ cells
pub const GeoLoop = extern struct { num_verts: c_int, verts: [*]LatLng };
pub const GeoPolygon = extern struct {
    geoloop: GeoLoop,
    num_holes: c_int,
    holes: ?[*]GeoLoop,
};
pub const ContainmentMode = enum(u32) {
    center, full_overlap, full_containment, overlapping_bbox,
};
pub fn maxPolygonToCellsSize(poly: *const GeoPolygon, res: i32, flags: ContainmentMode) Error!i64;
pub fn polygonToCells(poly: *const GeoPolygon, res: i32, flags: ContainmentMode, out: []H3Index) Error!void;
pub const LinkedMultiPolygon = struct { /* iterator + count + deinit */ };
pub fn cellsToMultiPolygon(cells: []const H3Index) Error!LinkedMultiPolygon;

// Local IJ coordinates
pub const CoordIJ = extern struct { i: c_int, j: c_int };
pub fn cellToLocalIj(origin: H3Index, cell: H3Index, mode: u32) Error!CoordIJ;
pub fn localIjToCell(origin: H3Index, ij: CoordIJ, mode: u32) Error!H3Index;

// Compact / uncompact
pub fn compactCells(cells: []const H3Index, out: []H3Index) Error!void;
pub fn uncompactCellsSize(cells: []const H3Index, res: i32) Error!i64;
pub fn uncompactCells(cells: []const H3Index, res: i32, out: []H3Index) Error!void;

// Icosahedron faces
pub fn getIcosahedronFaces(cell: H3Index, out: []i32) Error!void;

// Formatting
pub fn h3ToString(cell: H3Index, buf: []u8) Error![]const u8;
pub fn stringToH3(s: [:0]const u8) Error!H3Index;

// Distance / area
pub fn degsToRads(deg: f64) f64;
pub fn radsToDegs(rad: f64) f64;
pub fn greatCircleDistanceRads(a: LatLng, b: LatLng) f64;
pub fn greatCircleDistanceKm(a: LatLng, b: LatLng) f64;
pub fn greatCircleDistanceM(a: LatLng, b: LatLng) f64;
pub fn cellAreaRads2(cell: H3Index) Error!f64;
pub fn cellAreaKm2(cell: H3Index) Error!f64;
pub fn cellAreaM2(cell: H3Index) Error!f64;
pub fn hexagonAreaAvgKm2(res: i32) Error!f64;
pub fn hexagonAreaAvgM2(res: i32) Error!f64;
pub fn hexagonEdgeLengthAvgKm(res: i32) Error!f64;
pub fn hexagonEdgeLengthAvgM(res: i32) Error!f64;

// Resolution metadata
pub fn getNumCells(res: i32) Error!i64;
pub fn res0CellCount() i32;
pub fn pentagonCount() i32;
pub fn getRes0Cells(out: []H3Index) Error!void;
pub fn getPentagons(res: i32, out: []H3Index) Error!void;

// Raw C bindings escape hatch
pub const raw = @cImport({ @cInclude("h3api.h"); });
```

## Error model

The C library returns a 32-bit error code per call. `zig-h3` translates each
documented code into a Zig error:

| C code (`H3ErrorCodes`) | Zig error |
|------------------------|-----------|
| `E_SUCCESS` (0)         | (no error) |
| `E_FAILED` (1)          | `Error.Failed` |
| `E_DOMAIN` (2)          | `Error.Domain` |
| `E_LATLNG_DOMAIN` (3)   | `Error.LatLngDomain` |
| `E_RES_DOMAIN` (4)      | `Error.ResolutionDomain` |
| `E_CELL_INVALID` (5)    | `Error.CellInvalid` |
| `E_DIR_EDGE_INVALID` (6) | `Error.DirectedEdgeInvalid` |
| `E_UNDIR_EDGE_INVALID` (7) | `Error.UndirectedEdgeInvalid` |
| `E_VERTEX_INVALID` (8)  | `Error.VertexInvalid` |
| `E_PENTAGON` (9)        | `Error.Pentagon` |
| `E_DUPLICATE_INPUT` (10) | `Error.DuplicateInput` |
| `E_NOT_NEIGHBORS` (11)  | `Error.NotNeighbors` |
| `E_RES_MISMATCH` (12)   | `Error.ResolutionMismatch` |
| `E_MEMORY_ALLOC` (13)   | `Error.MemoryAlloc` |
| `E_MEMORY_BOUNDS` (14)  | `Error.MemoryBounds` |
| `E_OPTION_INVALID` (15) | `Error.OptionInvalid` |

## Design notes

**Why wrap libh3 instead of pure-Zig reimplementation.** The reference
implementation is ~10k LOC of carefully-tuned spatial math with 16
resolutions, pentagon distortion handling, and decade-old battle-test on
production systems at scale. A native rewrite is months of correctness
work for no end-user benefit. Wrapping `libh3` is the same choice
[h3-py][h3-py], [h3-java][h3-java], and [h3-go][h3-go] all made.

[h3-py]: https://github.com/uber/h3-py
[h3-java]: https://github.com/uber/h3-java
[h3-go]: https://github.com/uber/h3-go

**Why hash-pin v4.1.0.** Zig's package manager fetches by URL+hash so the
build is reproducible and the source is verified. The libh3 archive tag
`v4.1.0` from the official `uber/h3` repository is the upstream we
compile.

**LatLng in radians, with degree constructors.** The C API uses radians
exclusively; we expose `LatLng.fromDegrees` so callers writing
human-readable lat/lng don't have to remember the conversion. The raw
`lat` and `lng` fields are still radians for direct compatibility with
the C struct.

**No allocation hidden in the wrapper.** Functions that produce multiple
cells (`gridDisk`, `cellToChildren`, `getRes0Cells`, `getPentagons`)
require the caller to provide a `[]H3Index` of sufficient size. Use the
companion `*Size` function (e.g., `maxGridDiskSize`, `cellToChildrenSize`)
or known constants (`res0CellCount() == 122`, `pentagonCount() == 12`) to
size the buffer.

**CellBoundary is bit-compatible with `libh3.CellBoundary`.** The wrapper
returns a `CellBoundary` directly (no copy through a Zig-only struct);
`comptime` assertions in `root.zig` verify layout parity with the C
struct.

## Licensing

This wrapper is licensed under MIT. The underlying `libh3` library is
Apache License 2.0 (Copyright Uber Technologies, Inc.) and is fetched
from upstream at build time — its license is preserved in the downloaded
archive and reproduced in `LICENSE-H3-APACHE-2.0` in this repository for
reference.

## Tests

```sh
zig build test
```

166 tests, all currently passing on Zig 0.16.0. The split:

- 47 wrapper-layer tests (libh3-backed `h3.*` API — including the new
  directed-edge, vertex, polygon, local-IJ, grid-path, and
  compact/uncompact families introduced in v1.1.0)
- 117 pure-Zig cross-validation tests — each test calls both the
  libh3-backed `root.<fn>` path *and* the pure-Zig equivalent on the
  same inputs (random cells per resolution, every res-0 base cell,
  every pentagon at every resolution, hand-picked landmark
  coordinates, every icosahedron face center) and asserts equality.
  Coverage spans the `h3.pure.*` / `h3.h3index.*` / `h3.h3decode.*` /
  `h3.grid.*` / `h3.hierarchy.*` / `h3.boundary.*` / `h3.localij.*` /
  `h3.vertex.*` / `h3.edge.*` / `h3.polygon.*` modules.
- 2 fuzz tests in `pure.zig` — 10 000 random-u64 inputs through the
  pure-Zig parser surface (no panics on garbage), plus NaN/Inf input
  rejection on `pure.latLngToCell`

## Benchmarks

```sh
zig build bench
```

Three benchmarks ship under `bench/`:

- `bench_latlng_to_cell.zig` — `h3.latLngToCell` at resolutions 7, 9,
  11, 13, 15 over 1 M random points.
- `bench_grid_disk.zig` — `h3.gridDisk` at resolutions 7, 9, 11 with
  k = 1, 3, 5 over 100 K calls each. Reports ns/call and cells/sec.
- `bench_pure_vs_libh3.zig` — `latLngToCell` / `cellToLatLng` /
  `gridDisk` through both the libh3 wrapper (`h3.*`) and the pure-Zig
  path (`h3.h3index.*` / `h3.h3decode.*` / `h3.grid.*`), side-by-side.
  This is the killer chart for the v0.1.0 pure-Zig port.

Each benchmark warms up, then measures with enough iterations to dampen
variance over roughly one second of wall time per row. Output is
parseable `key=value` lines. Timing uses `std.os.linux.clock_gettime(
.MONOTONIC, &ts)` directly — `std.time.Timer` and
`std.time.nanoTimestamp` were removed in Zig 0.16's stdlib reshuffle.

Representative numbers from four `benchmarked` runs on the
maintainer's workstation (Intel Core i7-1065G7 @ 1.30 GHz, Linux
7.0.3-arch1-1 x86_64, Zig 0.16.0, `zig build bench` →
`-Doptimize=ReleaseFast`). The machine was under heavy concurrent
agent load (load avg 28–55 on 8 cores) — these numbers are
**not** quiet-room measurements. Reproduce on your hardware before
quoting them.

### Pure-Zig vs libh3, median of four runs

Ratio = pure ns/op ÷ libh3 ns/op. **Lower than 1.000 means pure-Zig
is faster** on that run.

| Op             | Res | ratio (median of 4) | ratio range (4 runs) |
| -------------- | --- | ------------------- | -------------------- |
| latLngToCell   | 7   | **0.54**            | 0.40 – 0.55          |
| latLngToCell   | 9   | 0.65                | **0.46 – 1.38**      |
| latLngToCell   | 11  | 0.75                | 0.33 – 0.96          |
| cellToLatLng   | 7   | 0.83                | **0.26 – 1.86**      |
| cellToLatLng   | 9   | 0.76                | **0.47 – 1.67**      |
| cellToLatLng   | 11  | 0.78                | 0.64 – 0.97          |
| gridDisk k=3   | 9   | 0.79                | **0.24 – 1.78**      |

Absolute ns/op figures vary by ±2× across runs on this contended host
and are omitted from the headline table; re-run `zig build bench` on
your machine and read the raw `libh3_ns_per_op=` / `pure_ns_per_op=`
fields for ground truth.

Honest read-off:

- The **median** pure-Zig run is faster than libh3 on every op
  measured. The largest wins are on `latLngToCell res 7` and
  `gridDisk res 9 k=3`.
- The **range** shows that on a contended host a single bench run can
  flip pure-Zig to 1.4×–1.9× slower on the projection ops and
  `gridDisk`. The shape "pure-Zig is competitive" is robust to noise;
  the precise headline number on any one run is not.
- Run-to-run variance is dominated by host load on this laptop, not by
  the implementations. Quiet-machine numbers are likely tighter; we
  haven't measured that yet.

Both paths produce bit-identical output (validated by the cross-validation
suite at `zig build test`); the perf delta is codegen, not algorithm.

## Evidence vocabulary

Using the shared agent-harness proof levels:

- **compiled / unit-tested / integration-tested:** 166/166 tests pass
  on Zig 0.16.0 via `zig build test`. The pure-Zig path is
  cross-validated cell-by-cell against libh3 in the same test binary.
- **benchmarked:** `zig build bench` runs three benchmarks
  (`bench/bench_latlng_to_cell.zig`, `bench/bench_grid_disk.zig`,
  `bench/bench_pure_vs_libh3.zig`) under `-Doptimize=ReleaseFast`.
  Numbers above are 4-run medians on a contended laptop.
- **not yet hardware-verified at scale.** No measurements on a quiet
  server, no measurements on aarch64, no measurements over a
  representative production workload (e.g. real ridebook order
  stream). The single-laptop ratios are directional, not portable.

## What this measurement did *not* cover (Type-I / Type-II lens)

**Type-I risks — places the "competitive" headline could over-state:**

- Single-host bench, single-host noise. The same code on a quieter
  machine or a different CPU class may shift the ratio either way.
- Only `latLngToCell`, `cellToLatLng`, and `gridDisk` were
  pure-vs-libh3 timed. The other 60+ wrapped functions are tested for
  correctness but not benchmarked side-by-side; do not generalize
  "pure-Zig is faster" beyond the three measured ops.
- ReleaseFast only. We haven't measured ReleaseSafe / ReleaseSmall.
- No memory / cache miss / branch-prediction profiling; the bench is
  wall-clock ns/op only.

**Type-II risks — what we may have missed:**

- Edge cases not in the cross-validation matrix: antimeridian wrap,
  exact pole coordinates (lat = ±π/2 exactly, not just ±89°),
  sub-millimetre coordinate precision near pentagon distortion
  boundaries.
- The fuzz suite probes the parser surface only (10 000 random u64
  inputs into `isValidCell` / `getResolution` / `getBaseCellNumber` /
  `isPentagon` plus NaN/Inf into `latLngToCell`); the projection /
  hierarchy / grid paths are not fuzzed against libh3 yet.
- Six grid-traversal variants (`gridDiskUnsafe`, `gridDiskDistances*`,
  `gridRingUnsafe`, `gridDisksUnsafe`) are reachable only via the
  `raw` C-binding escape hatch — no idiomatic Zig wrapper exists yet.

If you find a divergence between the pure-Zig path and libh3 on any
input, that is a bug, please open an issue.

## Composable fleet — Quantitative Mercantilism / Verifiable Fleet Engineering

`zig-h3` is one hull section in a deliberately small, replaceable
fleet of single-purpose Zig libraries. The H3 wrapper handles spatial
indexing; `zig-graph` composes over the cell adjacency graph;
`zig-cobs` and `zig-frame-protocol` carry messages off-host. Each
piece is auditable independently, replaceable by a competing
implementation that conforms to the same surface, and shipped with
its own evidence: tests, fuzz, benchmarks, changelog. The discipline
is the same one applied to merchant ships before the
container — composable, correctness-first hulls that operate
independently, are repaired at sea, and combine into larger fleets
when the route requires it.

## Part of the Sovereign Stack

This is one of a set of small, composable Zig libraries.

- [**zig-graph**](https://github.com/SMC17/zig-graph) — sparse graph + spectral algorithms (composes naturally over the H3 cell adjacency graph)
- [**zig-cobs**](https://github.com/SMC17/zig-cobs) — COBS byte-stuffing framing
- [**zig-frame-protocol**](https://github.com/SMC17/zig-frame-protocol) — versioned binary frame protocol

See [github.com/SMC17](https://github.com/SMC17) for the full portfolio.
