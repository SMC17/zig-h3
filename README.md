# zig-h3

[![CI](https://github.com/SMC17/zig-h3/actions/workflows/ci.yml/badge.svg)](https://github.com/SMC17/zig-h3/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/SMC17/zig-h3?display_name=tag&sort=semver)](https://github.com/SMC17/zig-h3/releases) [![License](https://img.shields.io/github/license/SMC17/zig-h3)](LICENSE)

Idiomatic Zig bindings for [H3 v4][h3-site] — Uber's hexagonal hierarchical
spatial index. Wraps the official `libh3` C library (v4.1.0), vendored
transparently via Zig's package manager. Build it from source the first
time, cached thereafter.

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

**172 tests pass** across the wrapper layer (53), the pure-Zig
cross-validation matrix (117), and the adversarial-input fuzz suite (2 —
10 000 random-u64 inputs probed through the pure parser, plus
NaN/Inf-input rejection). Coverage includes degrees↔radians roundtrip,
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
- 117 pure-Zig tests including the 142-input cross-validation matrix
  (libh3 oracle vs `h3.pure.*` / `h3.h3index.*` / `h3.h3decode.*` /
  `h3.grid.*` / `h3.hierarchy.*` / `h3.boundary.*` / `h3.localij.*` /
  `h3.vertex.*` / `h3.edge.*` / `h3.polygon.*` paths)
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

Representative numbers on the maintainer's workstation (Intel Core
i7-1065G7 @ 1.30 GHz, Linux 7.0.3-arch1-1 x86_64, Zig 0.16.0,
`zig build bench` with `-Doptimize=ReleaseFast`):

### latLngToCell (libh3-wrapper path)

| Resolution | ns/op  | ops/sec |
| ---------- | ------ | ------- |
| 7          | 6 837  | 146 K   |
| 9          | 3 556  | 281 K   |
| 11         | 7 483  | 134 K   |
| 13         | 5 454  | 183 K   |
| 15         | 8 868  | 113 K   |

### gridDisk (libh3-wrapper path)

| Resolution | k | disk_size | ns/op   | cells/sec |
| ---------- | - | --------- | ------- | --------- |
| 7          | 1 | 7         | 696     |  10.1 M   |
| 7          | 3 | 37        | 8 560   |   4.3 M   |
| 7          | 5 | 91        | 20 955  |   4.3 M   |
| 9          | 1 | 7         | 898     |   7.8 M   |
| 9          | 3 | 37        | 4 805   |   7.7 M   |
| 9          | 5 | 91        | 14 109  |   6.4 M   |
| 11         | 1 | 7         | 2 111   |   3.3 M   |
| 11         | 3 | 37        | 10 074  |   3.7 M   |
| 11         | 5 | 91        | 23 854  |   3.8 M   |

### Pure-Zig vs libh3 (the killer chart)

| Op             | Res | libh3 ns/op | pure-Zig ns/op | pure/libh3 |
| -------------- | --- | ----------- | -------------- | ---------- |
| latLngToCell   |  7  | 4 954       | 2 981          | **0.60x**  |
| latLngToCell   |  9  | 5 497       | 4 619          | **0.84x**  |
| latLngToCell   | 11  | 7 795       | 3 333          | **0.43x**  |
| cellToLatLng   |  7  | 1 523       | 1 025          | **0.67x**  |
| cellToLatLng   |  9  | 2 805       | 1 175          | **0.42x**  |
| cellToLatLng   | 11  | 1 765       | 1 796          |   1.02x    |
| gridDisk k=3   |  9  | 5 909       | 4 669          | **0.79x**  |

**Pure-Zig is at parity or faster than libh3 on every measured op at
v0.1.0**, with the largest wins on `latLngToCell` at res 11 (2.3x
faster) and `cellToLatLng` at res 9 (2.4x faster). The `cellToLatLng`
res-11 row is the only "essentially tied" cell — pure is 2% slower
than the C reference, within run-to-run noise on this laptop.

The win is concentrated in the projection arithmetic: the pure-Zig
implementation uses a flatter call graph and lets LLVM inline through
the Phase 3 constant tables, whereas libh3 carries function-call
overhead between `latLngToCell` → `_geoToFaceIjk` → `_geoToHex2d` →
`_hex2dToCoordIJK` plus the C ABI on every step. Both paths produce
bit-identical output (validated by the 142-input cross-validation
matrix); the speedup is pure codegen.

These numbers are on a busy laptop running concurrent agents;
run-to-run variance is ±30% on the tighter rows (the ratio shape is
stable, the absolute ns numbers fluctuate). Bring your own data on a
quiet machine for steady measurements.

## Part of the Sovereign Stack

This is one of a set of small, composable Zig libraries.

- [**zig-graph**](https://github.com/SMC17/zig-graph) — sparse graph + spectral algorithms (composes naturally over the H3 cell adjacency graph)
- [**zig-cobs**](https://github.com/SMC17/zig-cobs) — COBS byte-stuffing framing
- [**zig-frame-protocol**](https://github.com/SMC17/zig-frame-protocol) — versioned binary frame protocol

See [github.com/SMC17](https://github.com/SMC17) for the full portfolio.
