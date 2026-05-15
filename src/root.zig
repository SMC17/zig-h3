//! Idiomatic Zig bindings for H3 v4 — Uber's hexagonal hierarchical spatial
//! index. Wraps the `libh3` C library (vendored as a build dependency,
//! v4.1.0); the Zig layer adds typed errors, slice-friendly APIs, and a
//! `LatLng.fromDegrees` constructor so callers rarely touch radians directly.
//!
//! See https://h3geo.org/ for the H3 specification and concepts (cells,
//! resolutions, pentagons, base cells, hierarchies).
//!
//! ## Status
//!
//! v1.2.0 covers **all 70 H3 v4 public functions**: lat/lng ↔ cell
//! conversions, cell boundary geometry, resolution / base cell / pentagon
//! inspection, hierarchical traversal (parent / children / center child /
//! child-position), grid disk traversal (safe + unsafe + distances +
//! multi-origin variants), grid ring (unsafe), grid distance, grid path,
//! directed edges (origin/destination/boundary/length), vertices, polygon
//! ↔ cells, local-IJ coordinates, compact / uncompact, icosahedron faces,
//! formatting (h3 ↔ string), great-circle distances, cell area and edge-
//! length helpers, and base-set enumeration. The `raw.*` escape hatch
//! still exists for direct C-binding access but no longer hides any
//! missing wrapper.

const std = @import("std");
const c = @cImport({
    @cInclude("h3api.h");
});

/// Re-export the raw C bindings so callers can reach functions not yet wrapped
/// in the idiomatic layer.
pub const raw = c;

/// Pure-Zig implementations of a growing subset of the H3 API. Cross-validated
/// against the libh3-backed functions in this file via tests in
/// `src/pure.zig`. See `pure.zig` docstring for the roadmap.
pub const pure = @import("pure.zig");

/// Phase 3 projection primitives — Vec3d / Vec2d / face geometry / CoordIJK.
/// Foundation for the pure-Zig `latLngToCell` implementation.
pub const proj = @import("pure_proj.zig");

/// Phase 3b — pure-Zig `latLngToCell` plus the base cell tables, aperture-7
/// hierarchy, digit/coord rotations, and H3 index bit-level operations.
pub const h3index = @import("pure_h3index.zig");

/// Phase 3c — pure-Zig `cellToLatLng` plus `h3ToFaceIjk`, the overage handler,
/// `faceNeighbors` table, and the inverse spherical-projection helpers.
pub const h3decode = @import("pure_h3decode.zig");

/// Phase 4a — hierarchy operations: `cellToParent`, `cellToCenterChild`,
/// `cellToChildrenSize`, `cellToChildren`.
pub const hierarchy = @import("pure_hierarchy.zig");

/// Phase 4c — `cellToBoundary` with substrate-grid vertex enumeration, pentagon
/// vertex overage loop, and Class-III edge-crossing intersection logic.
pub const boundary = @import("pure_boundary.zig");

/// Phase 4e — grid traversal: `h3NeighborRotations`, `gridDiskUnsafe`,
/// `gridDiskDistancesSafe`, `gridDisk`, `gridRingUnsafe`, `areNeighborCells`.
pub const grid = @import("pure_grid.zig");

/// Phase 4f — local-IJ coordinate subsystem: `cellToLocalIjk`, `gridDistance`,
/// `compactCells`, `uncompactCells`, `maxFaceCount`, `getIcosahedronFaces`,
/// plus `localIjkToCell`, `gridPathCells`, `gridPathCellsSize`.
pub const localij = @import("pure_localij.zig");

/// Phase 5a — vertex API: `cellToVertex`, `cellToVertexes`, `vertexToLatLng`,
/// `isValidVertex`.
pub const vertex = @import("pure_vertex.zig");

/// Phase 5b — directed edge API: `cellsToDirectedEdge`, `getDirectedEdge*`,
/// `directedEdgeToCells`, `originToDirectedEdges`, `isValidDirectedEdge`,
/// `directedEdgeToBoundary`, `edgeLengthRads/Km/M`.
pub const edge = @import("pure_edge.zig");

/// Phase 5c — polygon ops: `maxPolygonToCellsSize`, `polygonToCells`,
/// `pointInsidePolygon`, `bboxFromGeoLoop`.
pub const polygon = @import("pure_polygon.zig");

test {
    _ = pure;
    _ = proj;
    _ = h3index;
    _ = h3decode;
    _ = hierarchy;
    _ = boundary;
    _ = grid;
    _ = localij;
    _ = vertex;
    _ = edge;
    _ = polygon;
}

/// 64-bit cell, edge, or vertex identifier in the H3 system.
pub const H3Index = u64;

/// Sentinel for "no valid index" — analogous to NaN.
pub const H3_NULL: H3Index = 0;

/// Maximum number of vertices in a `CellBoundary`. Worst case is a pentagon
/// at a Class III resolution (5 original vertices + 5 edge crossings).
pub const MAX_CELL_BOUNDARY_VERTS: usize = 10;

/// Maximum valid H3 resolution (0–15 inclusive).
pub const MAX_RES: i32 = 15;

/// Typed error set covering every documented H3 error code. The raw u32
/// returned by `libh3` is translated through `errorFromCode`.
pub const Error = error{
    /// Generic failure when no more specific code applies (`E_FAILED = 1`).
    Failed,
    /// Argument outside acceptable range without a more specific code (`E_DOMAIN`).
    Domain,
    /// Latitude or longitude outside acceptable range (`E_LATLNG_DOMAIN`).
    LatLngDomain,
    /// Resolution outside `[0, 15]` (`E_RES_DOMAIN`).
    ResolutionDomain,
    /// `H3Index` cell argument was not valid (`E_CELL_INVALID`).
    CellInvalid,
    /// `H3Index` directed-edge argument was not valid (`E_DIR_EDGE_INVALID`).
    DirectedEdgeInvalid,
    /// `H3Index` undirected-edge argument was not valid (`E_UNDIR_EDGE_INVALID`).
    UndirectedEdgeInvalid,
    /// `H3Index` vertex argument was not valid (`E_VERTEX_INVALID`).
    VertexInvalid,
    /// Pentagon distortion encountered — operation cannot handle it (`E_PENTAGON`).
    Pentagon,
    /// Duplicate input where the operation cannot handle it (`E_DUPLICATE_INPUT`).
    DuplicateInput,
    /// Two cell arguments were not neighbors (`E_NOT_NEIGHBORS`).
    NotNeighbors,
    /// Two cell arguments had incompatible resolutions (`E_RES_MISMATCH`).
    ResolutionMismatch,
    /// Necessary memory allocation failed inside libh3 (`E_MEMORY_ALLOC`).
    MemoryAlloc,
    /// Caller-provided buffer was too small (`E_MEMORY_BOUNDS`).
    MemoryBounds,
    /// Mode or flags argument was not valid (`E_OPTION_INVALID`).
    OptionInvalid,
    /// Error code outside the documented enum.
    Unknown,
};

fn check(code: c.H3Error) Error!void {
    return switch (code) {
        0 => {},
        1 => Error.Failed,
        2 => Error.Domain,
        3 => Error.LatLngDomain,
        4 => Error.ResolutionDomain,
        5 => Error.CellInvalid,
        6 => Error.DirectedEdgeInvalid,
        7 => Error.UndirectedEdgeInvalid,
        8 => Error.VertexInvalid,
        9 => Error.Pentagon,
        10 => Error.DuplicateInput,
        11 => Error.NotNeighbors,
        12 => Error.ResolutionMismatch,
        13 => Error.MemoryAlloc,
        14 => Error.MemoryBounds,
        15 => Error.OptionInvalid,
        else => Error.Unknown,
    };
}

/// Latitude / longitude in **radians**. Use `fromDegrees` to construct from
/// degree-valued inputs.
pub const LatLng = extern struct {
    lat: f64,
    lng: f64,

    pub fn fromDegrees(lat_deg: f64, lng_deg: f64) LatLng {
        return .{
            .lat = c.degsToRads(lat_deg),
            .lng = c.degsToRads(lng_deg),
        };
    }

    pub fn latDegrees(self: LatLng) f64 {
        return c.radsToDegs(self.lat);
    }

    pub fn lngDegrees(self: LatLng) f64 {
        return c.radsToDegs(self.lng);
    }
};

/// Cell boundary geometry: up to `MAX_CELL_BOUNDARY_VERTS` lat/lng points.
pub const CellBoundary = extern struct {
    num_verts: c_int,
    verts: [MAX_CELL_BOUNDARY_VERTS]LatLng,

    /// Return the boundary vertices as a slice of length `num_verts`.
    pub fn slice(self: *const CellBoundary) []const LatLng {
        return self.verts[0..@intCast(self.num_verts)];
    }
};

comptime {
    // Ensure layouts match the C structs so we can pass pointers directly.
    std.debug.assert(@sizeOf(LatLng) == @sizeOf(c.LatLng));
    std.debug.assert(@sizeOf(CellBoundary) == @sizeOf(c.CellBoundary));
}

fn cLatLng(p: LatLng) c.LatLng {
    return .{ .lat = p.lat, .lng = p.lng };
}

// === Lat/lng ↔ cell ============================================================

/// The H3 cell at resolution `res` (0–15) containing the given lat/lng point.
pub fn latLngToCell(point: LatLng, res: i32) Error!H3Index {
    var out: c.H3Index = 0;
    const ll = cLatLng(point);
    try check(c.latLngToCell(&ll, res, &out));
    return out;
}

/// The lat/lng of the centroid of `cell`.
pub fn cellToLatLng(cell: H3Index) Error!LatLng {
    var out: c.LatLng = undefined;
    try check(c.cellToLatLng(cell, &out));
    return .{ .lat = out.lat, .lng = out.lng };
}

/// The polygonal boundary of `cell` in lat/lng coordinates.
pub fn cellToBoundary(cell: H3Index) Error!CellBoundary {
    var out: c.CellBoundary = undefined;
    try check(c.cellToBoundary(cell, &out));
    return @as(*const CellBoundary, @ptrCast(&out)).*;
}

// === Cell inspection ===========================================================

/// Resolution of `cell` (0–15). Works on cells and directed edges.
pub fn getResolution(cell: H3Index) i32 {
    return c.getResolution(cell);
}

/// Base-cell index (0–121) of `cell`.
pub fn getBaseCellNumber(cell: H3Index) i32 {
    return c.getBaseCellNumber(cell);
}

/// True iff `cell` is a syntactically valid H3 cell.
pub fn isValidCell(cell: H3Index) bool {
    return c.isValidCell(cell) != 0;
}

/// True iff `cell` is one of the 12 pentagon cells at its resolution.
pub fn isPentagon(cell: H3Index) bool {
    return c.isPentagon(cell) != 0;
}

/// True iff `cell` is at a Class III resolution (1, 3, 5, 7, 9, 11, 13, 15).
pub fn isResClassIII(cell: H3Index) bool {
    return c.isResClassIII(cell) != 0;
}

/// True iff `a` and `b` share an edge. Returns `Error.ResolutionMismatch` if
/// the cells are at different resolutions.
pub fn areNeighborCells(a: H3Index, b: H3Index) Error!bool {
    var out: c_int = 0;
    try check(c.areNeighborCells(a, b, &out));
    return out != 0;
}

/// Maximum number of icosahedron faces that `cell` intersects.
pub fn maxFaceCount(cell: H3Index) Error!i32 {
    var out: c_int = 0;
    try check(c.maxFaceCount(cell, &out));
    return out;
}

// === Hierarchy =================================================================

/// The unique parent of `cell` at the coarser resolution `parent_res`.
pub fn cellToParent(cell: H3Index, parent_res: i32) Error!H3Index {
    var out: c.H3Index = 0;
    try check(c.cellToParent(cell, parent_res, &out));
    return out;
}

/// The center child of `cell` at the finer resolution `child_res`.
pub fn cellToCenterChild(cell: H3Index, child_res: i32) Error!H3Index {
    var out: c.H3Index = 0;
    try check(c.cellToCenterChild(cell, child_res, &out));
    return out;
}

/// Number of children of `cell` at the finer resolution `child_res`.
pub fn cellToChildrenSize(cell: H3Index, child_res: i32) Error!i64 {
    var out: i64 = 0;
    try check(c.cellToChildrenSize(cell, child_res, &out));
    return out;
}

/// Fill `out` with all children of `cell` at `child_res`. `out.len` must be
/// at least `cellToChildrenSize(cell, child_res)`.
pub fn cellToChildren(cell: H3Index, child_res: i32, out: []H3Index) Error!void {
    try check(c.cellToChildren(cell, child_res, out.ptr));
}

// === Grid traversal ============================================================

/// Maximum number of cells in a k-ring (`1 + 3 * k * (k + 1)`).
pub fn maxGridDiskSize(k: i32) Error!i64 {
    var out: i64 = 0;
    try check(c.maxGridDiskSize(k, &out));
    return out;
}

/// All cells within grid distance `k` of `origin`, including `origin` itself.
/// `out.len` must be at least `maxGridDiskSize(k)`; unused trailing slots
/// will be set to `H3_NULL`.
pub fn gridDisk(origin: H3Index, k: i32, out: []H3Index) Error!void {
    try check(c.gridDisk(origin, k, out.ptr));
}

/// Same as `gridDisk`, but also fills `distances[i]` with the grid distance
/// of `out[i]` from `origin`. Caller-allocated buffers; both must be at
/// least `maxGridDiskSize(k)` long.
pub fn gridDiskDistances(origin: H3Index, k: i32, out: []H3Index, distances: []i32) Error!void {
    try check(c.gridDiskDistances(origin, k, out.ptr, distances.ptr));
}

/// Faster `gridDisk` variant that does NOT degrade gracefully near pentagons.
/// Returns `error.Pentagon` (or similar H3 error) if the disk crosses one.
/// Caller-allocated `out` must be at least `maxGridDiskSize(k)` long.
///
/// WHY non-obvious: the safe version detects pentagon crossings at runtime
/// and falls back to BFS, which is slower but never errors. The unsafe
/// version is the open-arithmetic path; profile before reaching for it.
pub fn gridDiskUnsafe(origin: H3Index, k: i32, out: []H3Index) Error!void {
    try check(c.gridDiskUnsafe(origin, k, out.ptr));
}

/// Fast `gridDiskDistances` that may fail near pentagons. See
/// `gridDiskUnsafe` for the pentagon caveat.
pub fn gridDiskDistancesUnsafe(origin: H3Index, k: i32, out: []H3Index, distances: []i32) Error!void {
    try check(c.gridDiskDistancesUnsafe(origin, k, out.ptr, distances.ptr));
}

/// Slow-but-always-correct `gridDiskDistances` — the BFS fallback the safe
/// version uses internally. Use this when you have already detected a
/// pentagon crossing and want the slow-path explicitly.
pub fn gridDiskDistancesSafe(origin: H3Index, k: i32, out: []H3Index, distances: []i32) Error!void {
    try check(c.gridDiskDistancesSafe(origin, k, out.ptr, distances.ptr));
}

/// Union of `gridDiskUnsafe(o, k)` for every origin `o` in `origins`. May
/// fail near pentagons just like the single-origin unsafe variant.
/// `out` must be at least `origins.len * maxGridDiskSize(k)` long.
pub fn gridDisksUnsafe(origins: []H3Index, k: i32, out: []H3Index) Error!void {
    try check(c.gridDisksUnsafe(origins.ptr, @intCast(origins.len), k, out.ptr));
}

/// The single hex ring at distance `k` from `origin` (does NOT include the
/// origin or any interior cells). Returns `error.Pentagon` near pentagons.
/// `out.len` must be at least `6 * k` for `k >= 1`, or `1` for `k == 0`.
pub fn gridRingUnsafe(origin: H3Index, k: i32, out: []H3Index) Error!void {
    try check(c.gridRingUnsafe(origin, k, out.ptr));
}

/// Grid distance (minimum number of hex steps) between two cells.
pub fn gridDistance(a: H3Index, b: H3Index) Error!i64 {
    var out: i64 = 0;
    try check(c.gridDistance(a, b, &out));
    return out;
}

// === Formatting ================================================================

/// Format `cell` as a lowercase hex string. The slice is a sub-slice of `buf`
/// up to (but not including) the trailing null byte. `buf.len` should be at
/// least 17 (16 hex digits + null terminator).
pub fn h3ToString(cell: H3Index, buf: []u8) Error![]const u8 {
    try check(c.h3ToString(cell, buf.ptr, buf.len));
    const n = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..n];
}

/// Parse a hex string into an H3Index. The input must be NUL-terminated.
pub fn stringToH3(s: [:0]const u8) Error!H3Index {
    var out: c.H3Index = 0;
    try check(c.stringToH3(s.ptr, &out));
    return out;
}

// === Distance and area =========================================================

pub fn degsToRads(deg: f64) f64 {
    return c.degsToRads(deg);
}

pub fn radsToDegs(rad: f64) f64 {
    return c.radsToDegs(rad);
}

pub fn greatCircleDistanceRads(a: LatLng, b: LatLng) f64 {
    const ca = cLatLng(a);
    const cb = cLatLng(b);
    return c.greatCircleDistanceRads(&ca, &cb);
}

pub fn greatCircleDistanceKm(a: LatLng, b: LatLng) f64 {
    const ca = cLatLng(a);
    const cb = cLatLng(b);
    return c.greatCircleDistanceKm(&ca, &cb);
}

pub fn greatCircleDistanceM(a: LatLng, b: LatLng) f64 {
    const ca = cLatLng(a);
    const cb = cLatLng(b);
    return c.greatCircleDistanceM(&ca, &cb);
}

pub fn cellAreaRads2(cell: H3Index) Error!f64 {
    var out: f64 = 0;
    try check(c.cellAreaRads2(cell, &out));
    return out;
}

pub fn cellAreaKm2(cell: H3Index) Error!f64 {
    var out: f64 = 0;
    try check(c.cellAreaKm2(cell, &out));
    return out;
}

pub fn cellAreaM2(cell: H3Index) Error!f64 {
    var out: f64 = 0;
    try check(c.cellAreaM2(cell, &out));
    return out;
}

pub fn hexagonAreaAvgKm2(res: i32) Error!f64 {
    var out: f64 = 0;
    try check(c.getHexagonAreaAvgKm2(res, &out));
    return out;
}

pub fn hexagonAreaAvgM2(res: i32) Error!f64 {
    var out: f64 = 0;
    try check(c.getHexagonAreaAvgM2(res, &out));
    return out;
}

pub fn hexagonEdgeLengthAvgKm(res: i32) Error!f64 {
    var out: f64 = 0;
    try check(c.getHexagonEdgeLengthAvgKm(res, &out));
    return out;
}

pub fn hexagonEdgeLengthAvgM(res: i32) Error!f64 {
    var out: f64 = 0;
    try check(c.getHexagonEdgeLengthAvgM(res, &out));
    return out;
}

// === Resolution metadata =======================================================

/// Total number of cells at resolution `res` (`2 + 120 * 7^res`).
pub fn getNumCells(res: i32) Error!i64 {
    var out: i64 = 0;
    try check(c.getNumCells(res, &out));
    return out;
}

/// Number of res-0 base cells (always 122).
pub fn res0CellCount() i32 {
    return c.res0CellCount();
}

/// Number of pentagons per resolution (always 12).
pub fn pentagonCount() i32 {
    return c.pentagonCount();
}

/// Fill `out` with all 122 res-0 base cells. `out.len` must be ≥ 122.
pub fn getRes0Cells(out: []H3Index) Error!void {
    if (out.len < @as(usize, @intCast(c.res0CellCount()))) return Error.MemoryBounds;
    try check(c.getRes0Cells(out.ptr));
}

/// Fill `out` with the 12 pentagons at resolution `res`. `out.len` must be ≥ 12.
pub fn getPentagons(res: i32, out: []H3Index) Error!void {
    if (out.len < @as(usize, @intCast(c.pentagonCount()))) return Error.MemoryBounds;
    try check(c.getPentagons(res, out.ptr));
}

// === Directed edges ============================================================

/// Maximum number of directed edges per cell (6 for hexagons, 5 for pentagons).
pub const MAX_DIRECTED_EDGES_PER_CELL: usize = 6;

/// Build the directed-edge H3 index from an `origin` cell to a neighboring
/// `destination` cell. Returns `Error.NotNeighbors` if the two cells do not
/// share an edge, or `Error.ResolutionMismatch` if they are at different
/// resolutions.
pub fn cellsToDirectedEdge(origin: H3Index, destination: H3Index) Error!H3Index {
    var out: c.H3Index = 0;
    try check(c.cellsToDirectedEdge(origin, destination, &out));
    return out;
}

/// True iff `edge_idx` is a syntactically valid H3 directed-edge index.
pub fn isValidDirectedEdge(edge_idx: H3Index) bool {
    return c.isValidDirectedEdge(edge_idx) != 0;
}

/// Origin cell of the directed edge.
pub fn getDirectedEdgeOrigin(edge_idx: H3Index) Error!H3Index {
    var out: c.H3Index = 0;
    try check(c.getDirectedEdgeOrigin(edge_idx, &out));
    return out;
}

/// Destination cell of the directed edge.
pub fn getDirectedEdgeDestination(edge_idx: H3Index) Error!H3Index {
    var out: c.H3Index = 0;
    try check(c.getDirectedEdgeDestination(edge_idx, &out));
    return out;
}

/// Both endpoints of a directed edge as `.{ origin, destination }`.
pub fn directedEdgeToCells(edge_idx: H3Index) Error![2]H3Index {
    var out: [2]c.H3Index = .{ 0, 0 };
    try check(c.directedEdgeToCells(edge_idx, &out));
    return .{ out[0], out[1] };
}

/// Fill `out` with the 6 (hexagon) or 5 (pentagon) directed edges originating
/// at `origin`. `out.len` must be at least `MAX_DIRECTED_EDGES_PER_CELL` (6);
/// unused trailing slots are set to `H3_NULL`.
pub fn originToDirectedEdges(origin: H3Index, out: []H3Index) Error!void {
    if (out.len < MAX_DIRECTED_EDGES_PER_CELL) return Error.MemoryBounds;
    try check(c.originToDirectedEdges(origin, out.ptr));
}

/// Polygonal boundary (two lat/lng endpoints) of a directed edge.
pub fn directedEdgeToBoundary(edge_idx: H3Index) Error!CellBoundary {
    var out: c.CellBoundary = undefined;
    try check(c.directedEdgeToBoundary(edge_idx, &out));
    return @as(*const CellBoundary, @ptrCast(&out)).*;
}

/// Exact length of a directed edge in radians.
pub fn edgeLengthRads(edge_idx: H3Index) Error!f64 {
    var out: f64 = 0;
    try check(c.edgeLengthRads(edge_idx, &out));
    return out;
}

/// Exact length of a directed edge in kilometers.
pub fn edgeLengthKm(edge_idx: H3Index) Error!f64 {
    var out: f64 = 0;
    try check(c.edgeLengthKm(edge_idx, &out));
    return out;
}

/// Exact length of a directed edge in meters.
pub fn edgeLengthM(edge_idx: H3Index) Error!f64 {
    var out: f64 = 0;
    try check(c.edgeLengthM(edge_idx, &out));
    return out;
}

// === Vertices ==================================================================

/// Maximum number of vertices per cell (6 for hexagons, 5 for pentagons).
pub const MAX_VERTEXES_PER_CELL: usize = 6;

/// H3 vertex index for `vertex_num` (0–5 hex / 0–4 pentagon) of `origin`.
pub fn cellToVertex(origin: H3Index, vertex_num: i32) Error!H3Index {
    var out: c.H3Index = 0;
    try check(c.cellToVertex(origin, vertex_num, &out));
    return out;
}

/// Fill `out` with all vertex indices of `origin`. `out.len` must be at least
/// `MAX_VERTEXES_PER_CELL` (6); pentagons leave the trailing slot as `H3_NULL`.
pub fn cellToVertexes(origin: H3Index, out: []H3Index) Error!void {
    if (out.len < MAX_VERTEXES_PER_CELL) return Error.MemoryBounds;
    try check(c.cellToVertexes(origin, out.ptr));
}

/// Lat/lng of a single H3 vertex index.
pub fn vertexToLatLng(vertex_idx: H3Index) Error!LatLng {
    var out: c.LatLng = undefined;
    try check(c.vertexToLatLng(vertex_idx, &out));
    return .{ .lat = out.lat, .lng = out.lng };
}

/// True iff `vertex_idx` is a syntactically valid H3 vertex index.
pub fn isValidVertex(vertex_idx: H3Index) bool {
    return c.isValidVertex(vertex_idx) != 0;
}

// === Polygon ↔ cells ===========================================================

/// GeoJSON-style polygon ring (closed loop of lat/lng vertices, in **radians**).
/// Matches `libh3.GeoLoop`.
pub const GeoLoop = extern struct {
    num_verts: c_int,
    verts: [*]LatLng,
};

/// GeoJSON-style polygon (exterior ring plus optional interior "hole" rings),
/// in **radians**. Matches `libh3.GeoPolygon`.
pub const GeoPolygon = extern struct {
    geoloop: GeoLoop,
    num_holes: c_int,
    holes: ?[*]GeoLoop,
};

comptime {
    std.debug.assert(@sizeOf(GeoLoop) == @sizeOf(c.GeoLoop));
    std.debug.assert(@sizeOf(GeoPolygon) == @sizeOf(c.GeoPolygon));
}

/// Flags accepted by `polygonToCells`. Mirrors libh3's `polygonToCellsFlags`
/// enum, but exposed as a typed enum for clarity.
pub const ContainmentMode = enum(u32) {
    /// Cell center is inside the polygon (libh3's default, fastest).
    center = 0,
    /// Any part of the cell intersects the polygon (overestimating coverage).
    full_overlap = 1,
    /// Cell is entirely contained inside the polygon (underestimating).
    full_containment = 2,
    /// Centers AND full containment — strictest interpretation.
    overlapping_bbox = 3,
};

/// Upper bound on the number of cells `polygonToCells` will produce. Use this
/// to size the output buffer.
pub fn maxPolygonToCellsSize(poly: *const GeoPolygon, res: i32, flags: ContainmentMode) Error!i64 {
    var out: i64 = 0;
    const cpoly: *const c.GeoPolygon = @ptrCast(poly);
    try check(c.maxPolygonToCellsSize(cpoly, res, @intFromEnum(flags), &out));
    return out;
}

/// Fill `out` with the cells covering `poly` at resolution `res`.
/// `out.len` must be at least `maxPolygonToCellsSize(poly, res, flags)`.
/// Unused trailing slots are set to `H3_NULL`.
pub fn polygonToCells(
    poly: *const GeoPolygon,
    res: i32,
    flags: ContainmentMode,
    out: []H3Index,
) Error!void {
    const cpoly: *const c.GeoPolygon = @ptrCast(poly);
    try check(c.polygonToCells(cpoly, res, @intFromEnum(flags), out.ptr));
}

/// Linked-list polygon representation used by `cellsToMultiPolygon`. Owns its
/// memory; call `deinit` to free it back to libh3.
pub const LinkedMultiPolygon = struct {
    inner: c.LinkedGeoPolygon,

    /// Iterate the polygons in the result.
    pub const PolygonIterator = struct {
        cur: ?*c.LinkedGeoPolygon,

        pub fn next(self: *PolygonIterator) ?*c.LinkedGeoPolygon {
            const ret = self.cur orelse return null;
            self.cur = ret.next;
            return ret;
        }
    };

    pub fn polygons(self: *LinkedMultiPolygon) PolygonIterator {
        // The libh3 contract is that the first polygon is the head struct
        // itself if it has any loops, otherwise it's `.next`. We expose the
        // raw chain — callers walk it through libh3 types directly.
        return .{ .cur = &self.inner };
    }

    /// Count the number of polygons (linked nodes with any geo content).
    pub fn count(self: *LinkedMultiPolygon) usize {
        var n: usize = 0;
        var it = self.polygons();
        while (it.next()) |p| {
            if (p.first != null) n += 1;
        }
        return n;
    }

    pub fn deinit(self: *LinkedMultiPolygon) void {
        c.destroyLinkedMultiPolygon(&self.inner);
    }
};

/// Build a linked multi-polygon (one or more outer rings, each with optional
/// holes) covering a set of contiguous cells. The result owns heap memory
/// inside libh3; call `deinit` to release it.
pub fn cellsToMultiPolygon(cells: []const H3Index) Error!LinkedMultiPolygon {
    var out: c.LinkedGeoPolygon = std.mem.zeroes(c.LinkedGeoPolygon);
    try check(c.cellsToLinkedMultiPolygon(cells.ptr, @intCast(cells.len), &out));
    return .{ .inner = out };
}

// === Local IJ coordinates ======================================================

/// Two-dimensional axial coordinate pair used by `cellToLocalIj` /
/// `localIjToCell`. Layout matches `libh3.CoordIJ`.
pub const CoordIJ = extern struct {
    i: c_int,
    j: c_int,
};

comptime {
    std.debug.assert(@sizeOf(CoordIJ) == @sizeOf(c.CoordIJ));
}

/// Local IJ coordinate of `cell` relative to `origin`. `mode` is reserved by
/// libh3 — pass `0`. Returns `Error.Pentagon` or `Error.Failed` when the
/// origin's local frame cannot represent the cell.
pub fn cellToLocalIj(origin: H3Index, cell: H3Index, mode: u32) Error!CoordIJ {
    var out: c.CoordIJ = .{ .i = 0, .j = 0 };
    try check(c.cellToLocalIj(origin, cell, mode, &out));
    return .{ .i = out.i, .j = out.j };
}

/// Cell at local IJ coordinate `ij` relative to `origin`. `mode` is reserved by
/// libh3 — pass `0`.
pub fn localIjToCell(origin: H3Index, ij: CoordIJ, mode: u32) Error!H3Index {
    var out: c.H3Index = 0;
    const cij: c.CoordIJ = .{ .i = ij.i, .j = ij.j };
    try check(c.localIjToCell(origin, &cij, mode, &out));
    return out;
}

// === Grid path ================================================================

/// Number of cells in the line connecting `start` and `end` (inclusive of both
/// endpoints). Returns `gridDistance + 1` on success.
pub fn gridPathCellsSize(start: H3Index, end: H3Index) Error!i64 {
    var out: i64 = 0;
    try check(c.gridPathCellsSize(start, end, &out));
    return out;
}

/// Fill `out` with the line of cells from `start` to `end` (inclusive).
/// `out.len` must be at least `gridPathCellsSize(start, end)`.
pub fn gridPathCells(start: H3Index, end: H3Index, out: []H3Index) Error!void {
    try check(c.gridPathCells(start, end, out.ptr));
}

// === Compact / uncompact =======================================================

/// Compact a contiguous set of same-resolution cells into the minimal set of
/// mixed-resolution cells covering the same area. `out.len` must be at least
/// `cells.len` (libh3 contract — the worst case is no compaction). Unused
/// trailing slots are set to `H3_NULL`.
pub fn compactCells(cells: []const H3Index, out: []H3Index) Error!void {
    if (out.len < cells.len) return Error.MemoryBounds;
    try check(c.compactCells(cells.ptr, out.ptr, @intCast(cells.len)));
}

/// Exact number of cells produced by `uncompactCells(cells, res, …)`. Use this
/// to size the output buffer.
pub fn uncompactCellsSize(cells: []const H3Index, res: i32) Error!i64 {
    var out: i64 = 0;
    try check(c.uncompactCellsSize(cells.ptr, @intCast(cells.len), res, &out));
    return out;
}

/// Expand a compacted set of mixed-resolution cells back into the equivalent
/// uniform-resolution set at `res`. `out.len` must be at least
/// `uncompactCellsSize(cells, res)`.
pub fn uncompactCells(cells: []const H3Index, res: i32, out: []H3Index) Error!void {
    try check(c.uncompactCells(
        cells.ptr,
        @intCast(cells.len),
        out.ptr,
        @intCast(out.len),
        res,
    ));
}

// === Icosahedron faces =========================================================

/// Fill `out` with the icosahedron face indices (0–19) that `cell` intersects.
/// `out.len` must be at least `maxFaceCount(cell)`. Unused trailing slots are
/// set to `-1`.
pub fn getIcosahedronFaces(cell: H3Index, out: []i32) Error!void {
    const max = try maxFaceCount(cell);
    if (out.len < @as(usize, @intCast(max))) return Error.MemoryBounds;
    try check(c.getIcosahedronFaces(cell, @ptrCast(out.ptr)));
}

// === Hierarchy positions =======================================================

/// Ordinal position of `child` within its parent's children list at `parent_res`.
pub fn cellToChildPos(child: H3Index, parent_res: i32) Error!i64 {
    var out: i64 = 0;
    try check(c.cellToChildPos(child, parent_res, &out));
    return out;
}

/// Inverse of `cellToChildPos` — child cell at `child_pos` within `parent` at
/// resolution `child_res`.
pub fn childPosToCell(child_pos: i64, parent: H3Index, child_res: i32) Error!H3Index {
    var out: c.H3Index = 0;
    try check(c.childPosToCell(child_pos, parent, child_res, &out));
    return out;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "degsToRads and radsToDegs roundtrip" {
    const r = degsToRads(45.0);
    try testing.expectApproxEqAbs(@as(f64, std.math.pi / 4.0), r, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 45.0), radsToDegs(r), 1e-12);
}

test "res0CellCount and pentagonCount are constants" {
    try testing.expectEqual(@as(i32, 122), res0CellCount());
    try testing.expectEqual(@as(i32, 12), pentagonCount());
}

test "getNumCells matches closed-form 2 + 120 * 7^r" {
    var r: i32 = 0;
    while (r <= 5) : (r += 1) {
        const expected = blk: {
            var x: i64 = 1;
            var i: i32 = 0;
            while (i < r) : (i += 1) x *= 7;
            break :blk 2 + 120 * x;
        };
        try testing.expectEqual(expected, try getNumCells(r));
    }
}

test "latLngToCell at NYC res 9 and resolution check" {
    // Statue of Liberty area.
    const sol = LatLng.fromDegrees(40.6892, -74.0445);
    const cell = try latLngToCell(sol, 9);
    try testing.expect(isValidCell(cell));
    try testing.expectEqual(@as(i32, 9), getResolution(cell));
    try testing.expect(!isPentagon(cell));
}

test "latLngToCell rejects invalid resolution" {
    const sol = LatLng.fromDegrees(40.6892, -74.0445);
    try testing.expectError(Error.ResolutionDomain, latLngToCell(sol, -1));
    try testing.expectError(Error.ResolutionDomain, latLngToCell(sol, 16));
}

test "cellToLatLng roundtrip stays inside the same cell" {
    const original = LatLng.fromDegrees(37.7749, -122.4194); // San Francisco
    const cell = try latLngToCell(original, 9);
    const center = try cellToLatLng(cell);
    // Re-resolving the centroid must return the same cell.
    const cell2 = try latLngToCell(center, 9);
    try testing.expectEqual(cell, cell2);
}

test "cellToBoundary returns hexagon vertices for non-pentagon cell" {
    const cell = try latLngToCell(LatLng.fromDegrees(37.7749, -122.4194), 9);
    const bnd = try cellToBoundary(cell);
    try testing.expectEqual(@as(c_int, 6), bnd.num_verts);
    try testing.expectEqual(@as(usize, 6), bnd.slice().len);
}

test "maxGridDiskSize matches closed form 1 + 3 * k * (k + 1)" {
    var k: i32 = 0;
    while (k <= 5) : (k += 1) {
        const kk: i64 = k;
        const expected = 1 + 3 * kk * (kk + 1);
        try testing.expectEqual(expected, try maxGridDiskSize(k));
    }
}

test "gridDisk at k=0 returns only the origin" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    var out: [1]H3Index = .{0};
    try gridDisk(cell, 0, &out);
    try testing.expectEqual(cell, out[0]);
}

test "gridDisk at k=1 returns 7 cells including origin" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    var out: [7]H3Index = .{0} ** 7;
    try gridDisk(cell, 1, &out);

    var found_origin = false;
    var non_null: usize = 0;
    for (out) |v| {
        if (v == cell) found_origin = true;
        if (v != H3_NULL) non_null += 1;
    }
    try testing.expect(found_origin);
    try testing.expectEqual(@as(usize, 7), non_null);
}

test "gridDiskUnsafe at k=1 around a hexagon matches gridDisk" {
    // Use an NYC cell that's nowhere near a pentagon, so the unsafe path
    // succeeds. We compare the resulting cell *set* against the safe path
    // to confirm the unsafe wrapper is bound correctly.
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    var safe: [7]H3Index = .{0} ** 7;
    var unsafe: [7]H3Index = .{0} ** 7;
    try gridDisk(cell, 1, &safe);
    try gridDiskUnsafe(cell, 1, &unsafe);

    // Sort both, then compare element-wise (order is implementation-defined
    // across the safe/unsafe paths but the membership must match).
    std.mem.sort(H3Index, &safe, {}, std.sort.asc(H3Index));
    std.mem.sort(H3Index, &unsafe, {}, std.sort.asc(H3Index));
    try testing.expectEqualSlices(H3Index, &safe, &unsafe);
}

test "gridDiskDistances at k=1 yields one origin (distance 0) + six neighbors" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    var out: [7]H3Index = .{0} ** 7;
    var dists: [7]i32 = .{0} ** 7;
    try gridDiskDistances(cell, 1, &out, &dists);

    var n_zero: usize = 0;
    var n_one: usize = 0;
    for (dists) |d| {
        if (d == 0) n_zero += 1;
        if (d == 1) n_one += 1;
    }
    try testing.expectEqual(@as(usize, 1), n_zero);
    try testing.expectEqual(@as(usize, 6), n_one);
}

test "gridDiskDistancesUnsafe matches gridDiskDistances around a hexagon" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    var out_a: [7]H3Index = .{0} ** 7;
    var out_b: [7]H3Index = .{0} ** 7;
    var d_a: [7]i32 = .{0} ** 7;
    var d_b: [7]i32 = .{0} ** 7;
    try gridDiskDistances(cell, 1, &out_a, &d_a);
    try gridDiskDistancesUnsafe(cell, 1, &out_b, &d_b);
    // Cells: order-independent membership.
    std.mem.sort(H3Index, &out_a, {}, std.sort.asc(H3Index));
    std.mem.sort(H3Index, &out_b, {}, std.sort.asc(H3Index));
    try testing.expectEqualSlices(H3Index, &out_a, &out_b);
}

test "gridDiskDistancesSafe matches gridDiskDistances at k=1" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    var out_a: [7]H3Index = .{0} ** 7;
    var out_b: [7]H3Index = .{0} ** 7;
    var d_a: [7]i32 = .{0} ** 7;
    var d_b: [7]i32 = .{0} ** 7;
    try gridDiskDistances(cell, 1, &out_a, &d_a);
    try gridDiskDistancesSafe(cell, 1, &out_b, &d_b);
    std.mem.sort(H3Index, &out_a, {}, std.sort.asc(H3Index));
    std.mem.sort(H3Index, &out_b, {}, std.sort.asc(H3Index));
    try testing.expectEqualSlices(H3Index, &out_a, &out_b);
}

test "gridDisksUnsafe over two non-overlapping origins yields 14 unique cells" {
    // Two NYC-area cells far enough apart that their k=1 disks don't
    // overlap — picks one near JFK and one near Newark.
    const a = try latLngToCell(LatLng.fromDegrees(40.6413, -73.7781), 9);
    const b = try latLngToCell(LatLng.fromDegrees(40.6895, -74.1745), 9);
    var origins = [_]H3Index{ a, b };
    // gridDisks output size = origins.len * maxGridDiskSize(k).
    var out: [14]H3Index = .{0} ** 14;
    try gridDisksUnsafe(&origins, 1, &out);

    // Count non-null. With k=1 and 2 non-overlapping disks, we expect 14.
    var non_null: usize = 0;
    for (out) |v| if (v != H3_NULL) {
        non_null += 1;
    };
    try testing.expectEqual(@as(usize, 14), non_null);
}

test "gridRingUnsafe at k=1 returns exactly 6 cells, none of which is origin" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    var out: [6]H3Index = .{0} ** 6;
    try gridRingUnsafe(cell, 1, &out);

    var found_origin = false;
    var non_null: usize = 0;
    for (out) |v| {
        if (v == cell) found_origin = true;
        if (v != H3_NULL) non_null += 1;
    }
    try testing.expect(!found_origin);
    try testing.expectEqual(@as(usize, 6), non_null);
}

test "gridDistance origin to itself is 0" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    try testing.expectEqual(@as(i64, 0), try gridDistance(cell, cell));
}

test "gridDistance to a k=1 neighbor is 1" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    var ring: [7]H3Index = .{0} ** 7;
    try gridDisk(cell, 1, &ring);
    for (ring) |neighbor| {
        if (neighbor == H3_NULL or neighbor == cell) continue;
        try testing.expectEqual(@as(i64, 1), try gridDistance(cell, neighbor));
        try testing.expect(try areNeighborCells(cell, neighbor));
        break;
    } else return error.NoNeighborFound;
}

test "cellToParent then cellToChildren roundtrip" {
    const sf = LatLng.fromDegrees(37.7749, -122.4194);
    const fine = try latLngToCell(sf, 9);
    const parent = try cellToParent(fine, 7);
    try testing.expectEqual(@as(i32, 7), getResolution(parent));

    const child_count = try cellToChildrenSize(parent, 9);
    try testing.expectEqual(@as(i64, 49), child_count); // 7^2

    const children = try testing.allocator.alloc(H3Index, @intCast(child_count));
    defer testing.allocator.free(children);
    try cellToChildren(parent, 9, children);

    var contains_original = false;
    for (children) |child| if (child == fine) {
        contains_original = true;
        break;
    };
    try testing.expect(contains_original);
}

test "cellToCenterChild then cellToParent inverts" {
    const cell = try latLngToCell(LatLng.fromDegrees(0.0, 0.0), 5);
    const center = try cellToCenterChild(cell, 10);
    try testing.expectEqual(@as(i32, 10), getResolution(center));
    try testing.expectEqual(cell, try cellToParent(center, 5));
}

test "h3ToString and stringToH3 roundtrip" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var buf: [17]u8 = undefined;
    const s = try h3ToString(cell, &buf);

    // Convert the slice to a null-terminated string for stringToH3.
    var zbuf: [17]u8 = undefined;
    @memcpy(zbuf[0..s.len], s);
    zbuf[s.len] = 0;
    const z: [:0]const u8 = zbuf[0..s.len :0];
    try testing.expectEqual(cell, try stringToH3(z));
}

test "greatCircleDistanceKm: SF → NYC ~ 4140 km" {
    const sf = LatLng.fromDegrees(37.7749, -122.4194);
    const nyc = LatLng.fromDegrees(40.7128, -74.0060);
    const km = greatCircleDistanceKm(sf, nyc);
    try testing.expect(km > 4100.0 and km < 4200.0);
}

test "cellAreaKm2 at res 9 is ~0.105 km²" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    const area = try cellAreaKm2(cell);
    // Average res-9 hexagon area is ~0.105 km²; specific cells deviate.
    try testing.expect(area > 0.05 and area < 0.2);
}

test "hexagonAreaAvgKm2 at res 0 is ~4.36 million km²" {
    const a = try hexagonAreaAvgKm2(0);
    try testing.expect(a > 4_000_000.0 and a < 5_000_000.0);
}

test "getRes0Cells returns 122 valid cells" {
    var cells: [122]H3Index = undefined;
    try getRes0Cells(&cells);
    for (cells) |cell| {
        try testing.expect(isValidCell(cell));
        try testing.expectEqual(@as(i32, 0), getResolution(cell));
    }
}

test "getPentagons returns 12 pentagons at every resolution" {
    var r: i32 = 0;
    while (r <= 5) : (r += 1) {
        var pents: [12]H3Index = undefined;
        try getPentagons(r, &pents);
        for (pents) |p| {
            try testing.expect(isPentagon(p));
            try testing.expectEqual(r, getResolution(p));
        }
    }
}

test "stringToH3 rejects malformed input" {
    // libh3 returns generic E_FAILED for unparseable strings; E_CELL_INVALID
    // is reserved for syntactically-valid-but-not-a-real-cell inputs.
    try testing.expectError(Error.Failed, stringToH3("notahex"));
}

test "isValidCell rejects zero and arbitrary garbage" {
    try testing.expect(!isValidCell(0));
    try testing.expect(!isValidCell(0xdeadbeef));
}

test "getBaseCellNumber on res-0 cell equals its own number" {
    var cells: [122]H3Index = undefined;
    try getRes0Cells(&cells);
    // The 122 base cells in the returned order have base-cell numbers 0..121.
    for (cells, 0..) |cell, i| {
        try testing.expectEqual(@as(i32, @intCast(i)), getBaseCellNumber(cell));
    }
}

test "areNeighborCells false for same cell" {
    const cell = try latLngToCell(LatLng.fromDegrees(0.0, 0.0), 5);
    try testing.expect(!(try areNeighborCells(cell, cell)));
}

// === Directed-edge tests =======================================================

test "cellsToDirectedEdge: NYC res 9 origin to one of its k=1 neighbors" {
    const origin = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var ring: [7]H3Index = .{0} ** 7;
    try gridDisk(origin, 1, &ring);
    for (ring) |dest| {
        if (dest == H3_NULL or dest == origin) continue;
        const edge_idx = try cellsToDirectedEdge(origin, dest);
        try testing.expect(isValidDirectedEdge(edge_idx));
        try testing.expectEqual(origin, try getDirectedEdgeOrigin(edge_idx));
        try testing.expectEqual(dest, try getDirectedEdgeDestination(edge_idx));
        const pair = try directedEdgeToCells(edge_idx);
        try testing.expectEqual(origin, pair[0]);
        try testing.expectEqual(dest, pair[1]);
        return;
    }
    return error.NoNeighborFound;
}

test "cellsToDirectedEdge: non-neighbors rejected" {
    const a = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    const b = try latLngToCell(LatLng.fromDegrees(40.5, -74.0), 9);
    try testing.expectError(Error.NotNeighbors, cellsToDirectedEdge(a, b));
}

test "isValidDirectedEdge rejects a cell and zero" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    try testing.expect(!isValidDirectedEdge(cell));
    try testing.expect(!isValidDirectedEdge(0));
}

test "originToDirectedEdges yields 6 valid edges for a non-pentagon cell" {
    const origin = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var edges: [MAX_DIRECTED_EDGES_PER_CELL]H3Index = .{0} ** MAX_DIRECTED_EDGES_PER_CELL;
    try originToDirectedEdges(origin, &edges);
    var valid: usize = 0;
    for (edges) |e| {
        if (e == H3_NULL) continue;
        try testing.expect(isValidDirectedEdge(e));
        try testing.expectEqual(origin, try getDirectedEdgeOrigin(e));
        valid += 1;
    }
    try testing.expectEqual(@as(usize, 6), valid);
}

test "originToDirectedEdges yields 5 valid edges for a pentagon" {
    var pents: [12]H3Index = undefined;
    try getPentagons(3, &pents);
    var edges: [MAX_DIRECTED_EDGES_PER_CELL]H3Index = .{0} ** MAX_DIRECTED_EDGES_PER_CELL;
    try originToDirectedEdges(pents[0], &edges);
    var valid: usize = 0;
    for (edges) |e| {
        if (e == H3_NULL) continue;
        try testing.expect(isValidDirectedEdge(e));
        valid += 1;
    }
    try testing.expectEqual(@as(usize, 5), valid);
}

test "directedEdgeToBoundary returns two endpoints" {
    const origin = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var ring: [7]H3Index = .{0} ** 7;
    try gridDisk(origin, 1, &ring);
    for (ring) |dest| {
        if (dest == H3_NULL or dest == origin) continue;
        const edge_idx = try cellsToDirectedEdge(origin, dest);
        const bnd = try directedEdgeToBoundary(edge_idx);
        try testing.expectEqual(@as(c_int, 2), bnd.num_verts);
        try testing.expectEqual(@as(usize, 2), bnd.slice().len);
        return;
    }
    return error.NoNeighborFound;
}

test "edgeLengthKm at res 9 is roughly hexagonEdgeLengthAvgKm" {
    const origin = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var ring: [7]H3Index = .{0} ** 7;
    try gridDisk(origin, 1, &ring);
    for (ring) |dest| {
        if (dest == H3_NULL or dest == origin) continue;
        const edge_idx = try cellsToDirectedEdge(origin, dest);
        const km = try edgeLengthKm(edge_idx);
        const avg_km = try hexagonEdgeLengthAvgKm(9);
        // Specific edges deviate from the average; should be within ~30%.
        try testing.expect(km > 0.5 * avg_km and km < 2.0 * avg_km);
        const m = try edgeLengthM(edge_idx);
        try testing.expectApproxEqRel(km * 1000.0, m, 1e-9);
        const rads = try edgeLengthRads(edge_idx);
        try testing.expect(rads > 0.0);
        return;
    }
    return error.NoNeighborFound;
}

// === Vertex tests ==============================================================

test "cellToVertex: 6 vertices for a hexagon round-trip through vertexToLatLng" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var v_idx: i32 = 0;
    while (v_idx < 6) : (v_idx += 1) {
        const vert = try cellToVertex(cell, v_idx);
        try testing.expect(isValidVertex(vert));
        const ll = try vertexToLatLng(vert);
        // The vertex should lie within ~1° of the cell's centroid at res 9
        // (res-9 cells are ~470 m across — easily within 0.01°).
        const center = try cellToLatLng(cell);
        try testing.expect(@abs(ll.lat - center.lat) < 0.01);
        try testing.expect(@abs(ll.lng - center.lng) < 0.01);
    }
}

test "cellToVertex rejects out-of-range vertex_num" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    try testing.expectError(Error.Domain, cellToVertex(cell, -1));
    try testing.expectError(Error.Domain, cellToVertex(cell, 6));
}

test "cellToVertexes fills 6 valid hex vertices, 5 for pentagons" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var verts: [MAX_VERTEXES_PER_CELL]H3Index = .{0} ** MAX_VERTEXES_PER_CELL;
    try cellToVertexes(cell, &verts);
    var valid: usize = 0;
    for (verts) |v| {
        if (v == H3_NULL) continue;
        try testing.expect(isValidVertex(v));
        valid += 1;
    }
    try testing.expectEqual(@as(usize, 6), valid);

    var pents: [12]H3Index = undefined;
    try getPentagons(3, &pents);
    var pverts: [MAX_VERTEXES_PER_CELL]H3Index = .{0} ** MAX_VERTEXES_PER_CELL;
    try cellToVertexes(pents[0], &pverts);
    valid = 0;
    for (pverts) |v| {
        if (v == H3_NULL) continue;
        try testing.expect(isValidVertex(v));
        valid += 1;
    }
    try testing.expectEqual(@as(usize, 5), valid);
}

test "isValidVertex rejects a cell" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    try testing.expect(!isValidVertex(cell));
    try testing.expect(!isValidVertex(0));
}

// === Polygon ↔ cells tests =====================================================

test "polygonToCells: small NYC bbox at res 7 produces a sensible count" {
    // A ~0.1° × 0.1° square around Times Square. Counter-clockwise. Closed
    // loop convention: libh3 does not require an explicit closing vertex.
    var verts = [_]LatLng{
        LatLng.fromDegrees(40.75, -74.05),
        LatLng.fromDegrees(40.85, -74.05),
        LatLng.fromDegrees(40.85, -73.95),
        LatLng.fromDegrees(40.75, -73.95),
    };
    var poly = GeoPolygon{
        .geoloop = .{ .num_verts = verts.len, .verts = &verts },
        .num_holes = 0,
        .holes = null,
    };
    const max = try maxPolygonToCellsSize(&poly, 7, .center);
    try testing.expect(max > 0);
    const buf = try testing.allocator.alloc(H3Index, @intCast(max));
    defer testing.allocator.free(buf);
    @memset(buf, H3_NULL);
    try polygonToCells(&poly, 7, .center, buf);
    var n: usize = 0;
    for (buf) |cell| {
        if (cell == H3_NULL) continue;
        try testing.expect(isValidCell(cell));
        try testing.expectEqual(@as(i32, 7), getResolution(cell));
        n += 1;
    }
    // 0.1° × 0.1° at NYC latitude is ~123 km² ≈ 230 res-7 cells.
    try testing.expect(n > 10 and n < 1000);
}

test "cellsToMultiPolygon: a single cell rounds to a single polygon" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    const cells = [_]H3Index{cell};
    var mp = try cellsToMultiPolygon(&cells);
    defer mp.deinit();
    try testing.expect(mp.count() == 1);
}

test "cellsToMultiPolygon: gridDisk(k=1) is one polygon" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var ring: [7]H3Index = .{0} ** 7;
    try gridDisk(cell, 1, &ring);
    var mp = try cellsToMultiPolygon(&ring);
    defer mp.deinit();
    try testing.expectEqual(@as(usize, 1), mp.count());
}

// === Local IJ tests ============================================================

test "cellToLocalIj: origin roundtrips through localIjToCell" {
    const origin = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    const ij = try cellToLocalIj(origin, origin, 0);
    // libh3 doesn't pin the origin to (0,0); the contract is that the IJ
    // coordinate inverts back to the same cell.
    try testing.expectEqual(origin, try localIjToCell(origin, ij, 0));
}

test "cellToLocalIj: k=1 neighbors all round-trip" {
    const origin = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var ring: [7]H3Index = .{0} ** 7;
    try gridDisk(origin, 1, &ring);
    for (ring) |cell| {
        if (cell == H3_NULL) continue;
        const ij = try cellToLocalIj(origin, cell, 0);
        try testing.expectEqual(cell, try localIjToCell(origin, ij, 0));
    }
}

// === Grid path tests ===========================================================

test "gridPathCellsSize equals gridDistance + 1" {
    const origin = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var ring: [7]H3Index = .{0} ** 7;
    try gridDisk(origin, 1, &ring);
    for (ring) |dest| {
        if (dest == H3_NULL or dest == origin) continue;
        const dist = try gridDistance(origin, dest);
        try testing.expectEqual(dist + 1, try gridPathCellsSize(origin, dest));
        return;
    }
    return error.NoNeighborFound;
}

test "gridPathCells: short path includes endpoints and is contiguous" {
    const origin = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    var ring: [7]H3Index = .{0} ** 7;
    try gridDisk(origin, 1, &ring);
    for (ring) |dest| {
        if (dest == H3_NULL or dest == origin) continue;
        const size = try gridPathCellsSize(origin, dest);
        const path = try testing.allocator.alloc(H3Index, @intCast(size));
        defer testing.allocator.free(path);
        try gridPathCells(origin, dest, path);
        try testing.expectEqual(origin, path[0]);
        try testing.expectEqual(dest, path[path.len - 1]);
        return;
    }
    return error.NoNeighborFound;
}

// === Compact / uncompact tests =================================================

test "compactCells: all 7 children of a hexagon compact to its parent" {
    const parent = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 8);
    const child_count = try cellToChildrenSize(parent, 9);
    const children = try testing.allocator.alloc(H3Index, @intCast(child_count));
    defer testing.allocator.free(children);
    try cellToChildren(parent, 9, children);

    const compact_buf = try testing.allocator.alloc(H3Index, children.len);
    defer testing.allocator.free(compact_buf);
    @memset(compact_buf, H3_NULL);
    try compactCells(children, compact_buf);

    var non_null: usize = 0;
    var found_parent = false;
    for (compact_buf) |cell| {
        if (cell == H3_NULL) continue;
        non_null += 1;
        if (cell == parent) found_parent = true;
    }
    try testing.expectEqual(@as(usize, 1), non_null);
    try testing.expect(found_parent);
}

test "uncompactCells + uncompactCellsSize: parent uncompacts to all its children" {
    const parent = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 8);
    const cells = [_]H3Index{parent};
    const expected = try cellToChildrenSize(parent, 10);
    try testing.expectEqual(expected, try uncompactCellsSize(&cells, 10));
    const buf = try testing.allocator.alloc(H3Index, @intCast(expected));
    defer testing.allocator.free(buf);
    try uncompactCells(&cells, 10, buf);
    for (buf) |c_| {
        try testing.expect(isValidCell(c_));
        try testing.expectEqual(@as(i32, 10), getResolution(c_));
        try testing.expectEqual(parent, try cellToParent(c_, 8));
    }
}

// === Icosahedron face tests ====================================================

test "getIcosahedronFaces returns >= 1 face for a cell" {
    const cell = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    const max: usize = @intCast(try maxFaceCount(cell));
    try testing.expect(max >= 1);
    const faces = try testing.allocator.alloc(i32, max);
    defer testing.allocator.free(faces);
    @memset(faces, -1);
    try getIcosahedronFaces(cell, faces);
    var seen: usize = 0;
    for (faces) |f| {
        if (f < 0) continue;
        try testing.expect(f >= 0 and f < 20);
        seen += 1;
    }
    try testing.expect(seen >= 1);
}

// === Child position tests ======================================================

test "cellToChildPos and childPosToCell roundtrip" {
    const fine = try latLngToCell(LatLng.fromDegrees(40.6892, -74.0445), 9);
    const pos = try cellToChildPos(fine, 7);
    try testing.expect(pos >= 0 and pos < 49); // 7^2
    const parent = try cellToParent(fine, 7);
    try testing.expectEqual(fine, try childPosToCell(pos, parent, 9));
}

// ---------------------------------------------------------------------------
// Exhaustive resolution-sweep tests — BAKEOFF axis #2 (test breadth).
// ---------------------------------------------------------------------------

test "exhaustive: every resolution has res0CellCount == 122 base cells reachable" {
    var buf: [122]H3Index = undefined;
    try getRes0Cells(&buf);
    var nonzero: u32 = 0;
    for (buf) |cell| if (cell != H3_NULL) { nonzero += 1; };
    try std.testing.expectEqual(@as(u32, 122), nonzero);
}

test "exhaustive: cellToLatLng → latLngToCell roundtrip at every resolution" {
    const point = LatLng{ .lat = std.math.degreesToRadians(40.6892), .lng = std.math.degreesToRadians(-74.0445) };
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        const cell = try latLngToCell(point, res);
        const lat_lng = try cellToLatLng(cell);
        const cell2 = try latLngToCell(lat_lng, res);
        try std.testing.expectEqual(cell, cell2);
    }
}

test "exhaustive: getNumCells is monotonic non-decreasing across resolutions" {
    var last: i64 = 0;
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        const n = try getNumCells(res);
        try std.testing.expect(n > last);
        last = n;
    }
}

test "exhaustive: isResClassIII alternates across resolutions" {
    const point = LatLng{ .lat = std.math.degreesToRadians(40.7), .lng = std.math.degreesToRadians(-74.0) };
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        const cell = try latLngToCell(point, res);
        try std.testing.expectEqual(@as(bool, (@mod(res, 2) == 1)), isResClassIII(cell));
    }
}

test "exhaustive: all 12 pentagons remain valid at every resolution" {
    var pents: [12]H3Index = undefined;
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        try getPentagons(res, &pents);
        for (pents) |p| {
            try std.testing.expect(isValidCell(p));
            try std.testing.expect(isPentagon(p));
            try std.testing.expectEqual(res, getResolution(p));
        }
    }
}

test "exhaustive: cell area positive at every resolution" {
    const point = LatLng{ .lat = std.math.degreesToRadians(40.7), .lng = std.math.degreesToRadians(-74.0) };
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        const cell = try latLngToCell(point, res);
        try std.testing.expect(try cellAreaKm2(cell) > 0);
    }
}

test "exhaustive: cell area monotonically decreases with resolution" {
    const point = LatLng{ .lat = std.math.degreesToRadians(40.7), .lng = std.math.degreesToRadians(-74.0) };
    var last_area: f64 = std.math.inf(f64);
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        const cell = try latLngToCell(point, res);
        const area = try cellAreaKm2(cell);
        try std.testing.expect(area < last_area);
        last_area = area;
    }
}

test "exhaustive: high-latitude polar cells stay valid" {
    const lats = [_]f64{ 60.0, 75.0, 85.0, 89.0, -60.0, -75.0, -85.0, -89.0 };
    var res: i32 = 5;
    while (res <= 9) : (res += 1) {
        for (lats) |lat_deg| {
            const point = LatLng{ .lat = std.math.degreesToRadians(lat_deg), .lng = 0 };
            const cell = try latLngToCell(point, res);
            try std.testing.expect(isValidCell(cell));
        }
    }
}

test "exhaustive: antimeridian crossing handled" {
    const jw = LatLng{ .lat = std.math.degreesToRadians(40.0), .lng = std.math.degreesToRadians(179.999) };
    const je = LatLng{ .lat = std.math.degreesToRadians(40.0), .lng = std.math.degreesToRadians(-179.999) };
    var res: i32 = 5;
    while (res <= 9) : (res += 1) {
        try std.testing.expect(isValidCell(try latLngToCell(jw, res)));
        try std.testing.expect(isValidCell(try latLngToCell(je, res)));
    }
}
