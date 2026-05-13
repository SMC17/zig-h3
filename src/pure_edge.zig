//! Pure-Zig H3 directed edge API — Phase 5b.
//!
//! Translates `cellsToDirectedEdge`, `getDirectedEdgeOrigin`,
//! `getDirectedEdgeDestination`, `isValidDirectedEdge`, `directedEdgeToCells`,
//! `originToDirectedEdges`, `directedEdgeToBoundary`, and
//! `edgeLengthRads`/`edgeLengthKm`/`edgeLengthM`.

const std = @import("std");
const root = @import("root.zig");
const pure = @import("pure.zig");
const proj = @import("pure_proj.zig");
const h3idx = @import("pure_h3index.zig");
const h3dec = @import("pure_h3decode.zig");
const grid = @import("pure_grid.zig");
const bnd = @import("pure_boundary.zig");
const vert = @import("pure_vertex.zig");

pub const H3Index = root.H3Index;
pub const LatLng = root.LatLng;
pub const Error = root.Error;
pub const CellBoundary = root.CellBoundary;
pub const Direction = h3idx.Direction;
pub const FaceIJK = h3idx.FaceIJK;

const H3_MODE_OFFSET: u6 = 59;
const H3_RES_OFFSET: u6 = 52;
const H3_RESERVED_OFFSET: u6 = 56;
const DIRECTEDEDGE_MODE: u4 = 2;
const CELL_MODE: u4 = 1;

inline fn getMode(h: H3Index) u4 {
    return @intCast((h >> H3_MODE_OFFSET) & 0xF);
}
inline fn getResolution(h: H3Index) i32 {
    return @intCast((h >> H3_RES_OFFSET) & 0xF);
}
inline fn getReservedBits(h: H3Index) u3 {
    return @intCast((h >> H3_RESERVED_OFFSET) & 0x7);
}
inline fn setMode(h: H3Index, m: u4) H3Index {
    return (h & ~(@as(H3Index, 0xF) << H3_MODE_OFFSET)) |
        (@as(H3Index, m) << H3_MODE_OFFSET);
}
inline fn setReservedBits(h: H3Index, v: u3) H3Index {
    return (h & ~(@as(H3Index, 0x7) << H3_RESERVED_OFFSET)) |
        (@as(H3Index, v) << H3_RESERVED_OFFSET);
}

const EARTH_RADIUS_KM: f64 = 6371.007180918475;

// =============================================================================
// cellsToDirectedEdge
// =============================================================================

pub fn cellsToDirectedEdge(origin: H3Index, destination: H3Index) Error!H3Index {
    const direction = vert.directionForNeighbor(origin, destination);
    if (direction == .invalid) return Error.NotNeighbors;
    var out = origin;
    out = setMode(out, DIRECTEDEDGE_MODE);
    out = setReservedBits(out, @intCast(@intFromEnum(direction)));
    return out;
}

// =============================================================================
// getDirectedEdgeOrigin
// =============================================================================

pub fn getDirectedEdgeOrigin(edge: H3Index) Error!H3Index {
    if (getMode(edge) != DIRECTEDEDGE_MODE) return Error.DirectedEdgeInvalid;
    var origin = edge;
    origin = setMode(origin, CELL_MODE);
    origin = setReservedBits(origin, 0);
    return origin;
}

// =============================================================================
// getDirectedEdgeDestination
// =============================================================================

pub fn getDirectedEdgeDestination(edge: H3Index) Error!H3Index {
    const dir_bits = getReservedBits(edge);
    const direction: Direction = @enumFromInt(dir_bits);
    const origin = try getDirectedEdgeOrigin(edge);
    var rot: i32 = 0;
    return try grid.h3NeighborRotations(origin, direction, &rot);
}

// =============================================================================
// directedEdgeToCells
// =============================================================================

pub fn directedEdgeToCells(edge: H3Index, out: *[2]H3Index) Error!void {
    out[0] = try getDirectedEdgeOrigin(edge);
    out[1] = try getDirectedEdgeDestination(edge);
}

// =============================================================================
// isValidDirectedEdge
// =============================================================================

pub fn isValidDirectedEdge(edge: H3Index) bool {
    if (getMode(edge) != DIRECTEDEDGE_MODE) return false;
    const dir_bits = getReservedBits(edge);
    if (dir_bits == 0 or dir_bits >= 7) return false; // 0 = CENTER, >=7 = INVALID
    const origin = getDirectedEdgeOrigin(edge) catch return false;
    if (pure.isPentagon(origin) and dir_bits == 1) return false; // K_AXES on pentagon
    return pure.isValidCell(origin);
}

// =============================================================================
// originToDirectedEdges
// =============================================================================

pub fn originToDirectedEdges(origin: H3Index, edges: *[6]H3Index) void {
    const is_pent = pure.isPentagon(origin);
    var i: u3 = 0;
    while (i < 6) : (i += 1) {
        if (is_pent and i == 0) {
            edges[i] = 0;
        } else {
            var e = origin;
            e = setMode(e, DIRECTEDEDGE_MODE);
            e = setReservedBits(e, @intCast(@as(u3, i) + 1));
            edges[i] = e;
        }
    }
}

// =============================================================================
// directedEdgeToBoundary
// =============================================================================

pub fn directedEdgeToBoundary(edge: H3Index) Error!CellBoundary {
    const dir_bits = getReservedBits(edge);
    const direction: Direction = @enumFromInt(dir_bits);
    const origin = try getDirectedEdgeOrigin(edge);

    const start_vertex = vert.vertexNumForDirection(origin, direction);
    if (start_vertex == -1) return Error.DirectedEdgeInvalid;

    var fijk: FaceIJK = undefined;
    try h3dec.h3ToFaceIjk(origin, &fijk);
    const res = getResolution(origin);
    const is_pent = pure.isPentagon(origin);

    var out: CellBoundary = undefined;
    if (is_pent) {
        bnd.faceIjkPentToCellBoundarySegment(&fijk, res, @intCast(start_vertex), 2, &out);
    } else {
        bnd.faceIjkToCellBoundarySegment(&fijk, res, @intCast(start_vertex), 2, &out);
    }
    return out;
}

// =============================================================================
// edgeLength variants — sum great-circle distances along the segment
// =============================================================================

pub fn edgeLengthRads(edge: H3Index) Error!f64 {
    const cb = try directedEdgeToBoundary(edge);
    var total: f64 = 0.0;
    var i: usize = 0;
    const n: usize = @intCast(cb.num_verts);
    while (i + 1 < n) : (i += 1) {
        total += pure.greatCircleDistanceRads(cb.verts[i], cb.verts[i + 1]);
    }
    return total;
}

pub fn edgeLengthKm(edge: H3Index) Error!f64 {
    return (try edgeLengthRads(edge)) * EARTH_RADIUS_KM;
}

pub fn edgeLengthM(edge: H3Index) Error!f64 {
    return (try edgeLengthKm(edge)) * 1000.0;
}

// =============================================================================
// Cross-validation tests
// =============================================================================

const testing = std.testing;

test "pure cellsToDirectedEdge matches libh3" {
    var rng = std.Random.DefaultPrng.init(0xED1);
    var res: i32 = 4;
    while (res <= 9) : (res += 1) {
        for (0..15) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const origin = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(origin)) continue;

            // Walk k=1 ring; for each neighbor, test the edge encoding.
            var ring: [7]H3Index = .{ 0, 0, 0, 0, 0, 0, 0 };
            grid.gridDiskUnsafe(origin, 1, &ring) catch continue;
            for (ring) |neighbor| {
                if (neighbor == 0 or neighbor == origin) continue;
                const ours = cellsToDirectedEdge(origin, neighbor) catch continue;
                var theirs: H3Index = 0;
                const e = root.raw.cellsToDirectedEdge(origin, neighbor, &theirs);
                if (e != 0) continue;
                try testing.expectEqual(theirs, ours);
            }
        }
    }
}

test "pure directedEdgeToCells inverts cellsToDirectedEdge" {
    var rng = std.Random.DefaultPrng.init(0xED2);
    for (0..30) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const origin = try root.latLngToCell(LatLng.fromDegrees(lat, lng), 6);
        if (pure.isPentagon(origin)) continue;
        var ring: [7]H3Index = .{ 0, 0, 0, 0, 0, 0, 0 };
        grid.gridDiskUnsafe(origin, 1, &ring) catch continue;
        for (ring) |neighbor| {
            if (neighbor == 0 or neighbor == origin) continue;
            const edge = cellsToDirectedEdge(origin, neighbor) catch continue;
            var pair: [2]H3Index = undefined;
            try directedEdgeToCells(edge, &pair);
            try testing.expectEqual(origin, pair[0]);
            try testing.expectEqual(neighbor, pair[1]);
        }
    }
}

test "pure isValidDirectedEdge accepts canonical edges and rejects cells" {
    const origin = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 5);
    var ring: [7]H3Index = .{ 0, 0, 0, 0, 0, 0, 0 };
    try grid.gridDiskUnsafe(origin, 1, &ring);
    for (ring) |neighbor| {
        if (neighbor == 0 or neighbor == origin) continue;
        const edge = try cellsToDirectedEdge(origin, neighbor);
        try testing.expect(isValidDirectedEdge(edge));
    }
    try testing.expect(!isValidDirectedEdge(origin));
    try testing.expect(!isValidDirectedEdge(0));
}

test "pure originToDirectedEdges produces 6 valid edges for hex (5 + null for pentagon)" {
    const hex = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 7);
    if (!pure.isPentagon(hex)) {
        var es: [6]H3Index = undefined;
        originToDirectedEdges(hex, &es);
        for (es) |e| {
            try testing.expect(e != 0);
            try testing.expect(isValidDirectedEdge(e));
        }
    }
    var pents: [12]H3Index = undefined;
    try root.getPentagons(5, &pents);
    var es: [6]H3Index = undefined;
    originToDirectedEdges(pents[0], &es);
    try testing.expectEqual(@as(H3Index, 0), es[0]);
    var i: usize = 1;
    while (i < 6) : (i += 1) {
        try testing.expect(es[i] != 0);
        try testing.expect(isValidDirectedEdge(es[i]));
    }
}

test "pure edgeLengthKm matches libh3 within tolerance" {
    var rng = std.Random.DefaultPrng.init(0xED3);
    for (0..15) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const origin = try root.latLngToCell(LatLng.fromDegrees(lat, lng), 7);
        if (pure.isPentagon(origin)) continue;
        var ring: [7]H3Index = .{ 0, 0, 0, 0, 0, 0, 0 };
        grid.gridDiskUnsafe(origin, 1, &ring) catch continue;
        for (ring) |neighbor| {
            if (neighbor == 0 or neighbor == origin) continue;
            const edge = cellsToDirectedEdge(origin, neighbor) catch continue;
            const ours = try edgeLengthKm(edge);
            var theirs: f64 = 0;
            _ = root.raw.edgeLengthKm(edge, &theirs);
            const tol = @max(@abs(theirs) * 1e-6, 1e-9);
            try testing.expectApproxEqAbs(theirs, ours, tol);
            break;
        }
    }
}
