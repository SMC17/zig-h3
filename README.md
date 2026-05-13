# zig-h3

Idiomatic Zig bindings for [H3 v4][h3-site] — Uber's hexagonal hierarchical
spatial index. Wraps the official `libh3` C library (v4.1.0), vendored
transparently via Zig's package manager. Build it from source the first
time, cached thereafter.

[h3-site]: https://h3geo.org/

## Status

`v0.1.0` — covers ~30 of the ~70 H3 v4 public functions:

- Lat/lng ↔ cell conversions
- Cell boundary geometry
- Resolution / base cell / pentagon / Class III inspection
- Hierarchical traversal (parent, children, center child)
- Grid disk traversal + grid distance + neighbor check
- Formatting (h3 ↔ string)
- Great-circle distances (radians, km, m)
- Cell area (radians², km², m²) and average hexagon area / edge length
- Resolution metadata (`getNumCells`, `getRes0Cells`, `getPentagons`,
  `res0CellCount`, `pentagonCount`)

**24 unit tests pass**, covering: degrees↔radians roundtrip, closed-form
cell-count and grid-disk-size verification, NYC and SF cell resolution,
boundary vertex counts, hexagonal grid disk arithmetic, k=1 neighbor and
grid-distance round-trip, parent/children/center-child hierarchy roundtrip
(7² = 49 children at resolution-step 2), h3↔string roundtrip, San
Francisco → New York City great-circle distance (4100–4200 km), res-9 cell
area within published bounds, all 122 base cells valid and at resolution
0, all 12 pentagons valid at every tested resolution, malformed-string
rejection, and zero-cell rejection.

Deferred to v0.2: directed edges, vertices, polygon-to-cells / cells-to-
multi-polygon, local IJ coordinates, grid path cells, compact / uncompact.
The raw C bindings are exposed via the `raw` module export so callers can
use any unwrapped function today and PR an idiomatic wrapper.

Minimum Zig version: `0.16.0`.

## Install

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .h3 = .{
        .url = "https://example.invalid/zig-h3-v0.1.0.tar.gz",
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

// Grid traversal
pub fn maxGridDiskSize(k: i32) Error!i64;
pub fn gridDisk(origin: H3Index, k: i32, out: []H3Index) Error!void;
pub fn gridDistance(a: H3Index, b: H3Index) Error!i64;

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

24 tests, all currently passing on Zig 0.16.0.
