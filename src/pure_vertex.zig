//! Pure-Zig H3 vertex API — Phase 5a.
//!
//! Translates `cellToVertex`, `cellToVertexes`, `vertexToLatLng`, and
//! `isValidVertex`. Reuses the substrate-grid vertex enumeration from
//! `pure_boundary.zig` to produce single-vertex lat/lng output instead of
//! looping through the full cell boundary.

const std = @import("std");
const root = @import("root.zig");
const pure = @import("pure.zig");
const proj = @import("pure_proj.zig");
const h3idx = @import("pure_h3index.zig");
const h3dec = @import("pure_h3decode.zig");
const hier = @import("pure_hierarchy.zig");
const grid = @import("pure_grid.zig");
const bnd = @import("pure_boundary.zig");
const localij = @import("pure_localij.zig");

pub const H3Index = root.H3Index;
pub const LatLng = root.LatLng;
pub const Error = root.Error;
pub const FaceIJK = h3idx.FaceIJK;
pub const Direction = h3idx.Direction;
pub const MAX_RES = h3idx.MAX_RES;

const NUM_HEX_VERTS: i32 = 6;
const NUM_PENT_VERTS: i32 = 5;
const NUM_PENTAGONS: usize = 12;
const NUM_BASE_CELLS: i32 = 122;
const INVALID_VERTEX_NUM: i32 = -1;

const H3_RES_OFFSET: u6 = 52;
const H3_BC_OFFSET: u6 = 45;
const H3_MODE_OFFSET: u6 = 59;
const H3_RESERVED_OFFSET: u6 = 56;
const H3_DIGIT_MASK: u64 = 7;
const VERTEX_MODE: u4 = 4;

inline fn getResolution(h: H3Index) i32 {
    return @intCast((h >> H3_RES_OFFSET) & 0xF);
}
inline fn getBaseCell(h: H3Index) i32 {
    return @intCast((h >> H3_BC_OFFSET) & 0x7F);
}
inline fn getMode(h: H3Index) u4 {
    return @intCast((h >> H3_MODE_OFFSET) & 0xF);
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
inline fn getIndexDigit(h: H3Index, res: i32) Direction {
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * 3);
    return @enumFromInt(@as(u3, @intCast((h >> shift) & H3_DIGIT_MASK)));
}

// =============================================================================
// pentagonDirectionFaces[12] table — verbatim from libh3 vertex.c
// =============================================================================

pub const PentagonDirectionFaces = struct {
    base_cell: i32,
    faces: [5]i32, // faces in directional order starting at J_AXES_DIGIT
};

pub const pentagonDirectionFaces = [_]PentagonDirectionFaces{
    .{ .base_cell = 4, .faces = .{ 4, 0, 2, 1, 3 } },
    .{ .base_cell = 14, .faces = .{ 6, 11, 2, 7, 1 } },
    .{ .base_cell = 24, .faces = .{ 5, 10, 1, 6, 0 } },
    .{ .base_cell = 38, .faces = .{ 7, 12, 3, 8, 2 } },
    .{ .base_cell = 49, .faces = .{ 9, 14, 0, 5, 4 } },
    .{ .base_cell = 58, .faces = .{ 8, 13, 4, 9, 3 } },
    .{ .base_cell = 63, .faces = .{ 11, 6, 15, 10, 16 } },
    .{ .base_cell = 72, .faces = .{ 12, 7, 16, 11, 17 } },
    .{ .base_cell = 83, .faces = .{ 10, 5, 19, 14, 15 } },
    .{ .base_cell = 97, .faces = .{ 13, 8, 17, 12, 18 } },
    .{ .base_cell = 107, .faces = .{ 14, 9, 18, 13, 19 } },
    .{ .base_cell = 117, .faces = .{ 15, 19, 17, 18, 16 } },
};

const DIRECTION_INDEX_OFFSET: i32 = 2;

inline fn isBaseCellPolarPentagon(bc: i32) bool {
    return bc == 4 or bc == 117;
}

// =============================================================================
// directionToVertexNumHex / Pent + reverse tables — verbatim
// =============================================================================

const INVALID_DIGIT_INT: i32 = 7;
const directionToVertexNumHex = [_]i32{ INVALID_DIGIT_INT, 3, 1, 2, 5, 4, 0 };
const directionToVertexNumPent = [_]i32{ INVALID_DIGIT_INT, INVALID_DIGIT_INT, 1, 2, 4, 3, 0 };

const vertexNumToDirectionHex = [_]Direction{
    .ij_axes, .j_axes, .jk_axes, .k_axes, .ik_axes, .i_axes,
};

const vertexNumToDirectionPent = [_]Direction{
    .ij_axes, .j_axes, .jk_axes, .ik_axes, .i_axes,
};

const VERTEX_DIRECTIONS = [_]Direction{
    .j_axes, .jk_axes, .k_axes, .ik_axes, .i_axes, .ij_axes,
};

const revNeighborDirectionsHex = [_]i32{ INVALID_DIGIT_INT, 5, 3, 4, 1, 0, 2 };

// =============================================================================
// baseCellToCCWrot60 — searches the faceIjkBaseCells table for the rotation
// =============================================================================

fn baseCellToCCWrot60(base_cell: i32, face: i32) i32 {
    if (face < 0 or face >= 20) return -1;
    var i: i32 = 0;
    while (i < 3) : (i += 1) {
        var j: i32 = 0;
        while (j < 3) : (j += 1) {
            var k: i32 = 0;
            while (k < 3) : (k += 1) {
                const idx: usize = @as(usize, @intCast(face)) * 27 +
                    @as(usize, @intCast(i)) * 9 + @as(usize, @intCast(j)) * 3 + @as(usize, @intCast(k));
                if (h3idx.faceIjkBaseCells[idx].base == base_cell) {
                    return h3idx.faceIjkBaseCells[idx].ccw_rot;
                }
            }
        }
    }
    return -1;
}

// =============================================================================
// vertexRotations — number of CCW rotations of cell's vertex numbering
// =============================================================================

pub fn vertexRotations(cell: H3Index) Error!i32 {
    var fijk: FaceIJK = undefined;
    try h3dec.h3ToFaceIjk(cell, &fijk);

    const base_cell = getBaseCell(cell);
    const leading = h3idx.h3LeadingNonZeroDigit(cell);

    const bcd = h3idx.baseCellData[@intCast(base_cell)];
    var ccw_rot60: i32 = baseCellToCCWrot60(base_cell, fijk.face);
    if (ccw_rot60 < 0) return Error.Failed;

    if (h3idx.isBaseCellPentagon(base_cell)) {
        // Find direction-face mapping for this pentagon
        var dir_faces: PentagonDirectionFaces = undefined;
        var found = false;
        for (pentagonDirectionFaces) |pdf| {
            if (pdf.base_cell == base_cell) {
                dir_faces = pdf;
                found = true;
                break;
            }
        }
        if (!found) return Error.Failed;

        // Additional rotations for polar or IK-axis neighbor faces
        if (fijk.face != bcd.home_face) {
            const ik_face_idx = @as(usize, @intCast(@intFromEnum(Direction.ik_axes) - DIRECTION_INDEX_OFFSET));
            if (isBaseCellPolarPentagon(base_cell) or fijk.face == dir_faces.faces[ik_face_idx]) {
                ccw_rot60 = @mod(ccw_rot60 + 1, 6);
            }
        }

        // Pentagon deleted-K crossing adjustments
        const ik_face = dir_faces.faces[@as(usize, @intCast(@intFromEnum(Direction.ik_axes) - DIRECTION_INDEX_OFFSET))];
        const jk_face = dir_faces.faces[@as(usize, @intCast(@intFromEnum(Direction.jk_axes) - DIRECTION_INDEX_OFFSET))];
        if (leading == .jk_axes and fijk.face == ik_face) {
            ccw_rot60 = @mod(ccw_rot60 + 5, 6);
        } else if (leading == .ik_axes and fijk.face == jk_face) {
            ccw_rot60 = @mod(ccw_rot60 + 1, 6);
        }
    }
    return ccw_rot60;
}

// =============================================================================
// vertexNumForDirection + directionForVertexNum
// =============================================================================

pub fn vertexNumForDirection(origin: H3Index, direction: Direction) i32 {
    const is_pent = pure.isPentagon(origin);
    if (direction == .center or direction == .invalid or (is_pent and direction == .k_axes)) {
        return INVALID_VERTEX_NUM;
    }
    const rotations = vertexRotations(origin) catch return INVALID_VERTEX_NUM;
    if (is_pent) {
        return @mod(directionToVertexNumPent[@intFromEnum(direction)] + NUM_PENT_VERTS - rotations, NUM_PENT_VERTS);
    } else {
        return @mod(directionToVertexNumHex[@intFromEnum(direction)] + NUM_HEX_VERTS - rotations, NUM_HEX_VERTS);
    }
}

pub fn directionForVertexNum(origin: H3Index, vertex_num: i32) Direction {
    const is_pent = pure.isPentagon(origin);
    const max_verts: i32 = if (is_pent) NUM_PENT_VERTS else NUM_HEX_VERTS;
    if (vertex_num < 0 or vertex_num > max_verts - 1) return .invalid;
    const rotations = vertexRotations(origin) catch return .invalid;
    if (is_pent) {
        return vertexNumToDirectionPent[@intCast(@mod(vertex_num + rotations, NUM_PENT_VERTS))];
    } else {
        return vertexNumToDirectionHex[@intCast(@mod(vertex_num + rotations, NUM_HEX_VERTS))];
    }
}

// =============================================================================
// directionForNeighbor — brute-force inverse of h3NeighborRotations
// =============================================================================

pub fn directionForNeighbor(origin: H3Index, neighbor: H3Index) Direction {
    var d: u3 = 1; // skip CENTER
    while (d < 7) : (d += 1) {
        var rot: i32 = 0;
        const test_neighbor = grid.h3NeighborRotations(origin, @enumFromInt(d), &rot) catch continue;
        if (test_neighbor == neighbor) return @enumFromInt(d);
    }
    return .invalid;
}

// =============================================================================
// cellToVertex — find owner cell + canonical vertex number
// =============================================================================

pub fn cellToVertex(cell: H3Index, vertex_num: i32) Error!H3Index {
    const is_pent = pure.isPentagon(cell);
    const num_verts: i32 = if (is_pent) NUM_PENT_VERTS else NUM_HEX_VERTS;
    const res = getResolution(cell);
    if (vertex_num < 0 or vertex_num > num_verts - 1) return Error.Domain;

    var owner = cell;
    var owner_vertex_num = vertex_num;

    if (res == 0 or getIndexDigit(cell, res) != .center) {
        const left = directionForVertexNum(cell, vertex_num);
        if (left == .invalid) return Error.Failed;
        var l_rot: i32 = 0;
        const left_neighbor = try grid.h3NeighborRotations(cell, left, &l_rot);
        if (left_neighbor < owner) owner = left_neighbor;

        if (res == 0 or getIndexDigit(left_neighbor, res) != .center) {
            const right = directionForVertexNum(cell, @mod(vertex_num - 1 + num_verts, num_verts));
            if (right == .invalid) return Error.Failed;
            var r_rot: i32 = 0;
            const right_neighbor = try grid.h3NeighborRotations(cell, right, &r_rot);
            if (right_neighbor < owner) {
                owner = right_neighbor;
                const dir = if (pure.isPentagon(owner))
                    directionForNeighbor(owner, cell)
                else
                    VERTEX_DIRECTIONS[@intCast(@mod(revNeighborDirectionsHex[@intFromEnum(right)] + r_rot, NUM_HEX_VERTS))];
                owner_vertex_num = vertexNumForDirection(owner, dir);
            }
        }

        if (owner == left_neighbor) {
            const owner_is_pent = pure.isPentagon(owner);
            const dir = if (owner_is_pent)
                directionForNeighbor(owner, cell)
            else
                VERTEX_DIRECTIONS[@intCast(@mod(revNeighborDirectionsHex[@intFromEnum(left)] + l_rot, NUM_HEX_VERTS))];
            owner_vertex_num = vertexNumForDirection(owner, dir) + 1;
            if (owner_vertex_num == NUM_HEX_VERTS or (owner_is_pent and owner_vertex_num == NUM_PENT_VERTS)) {
                owner_vertex_num = 0;
            }
        }
    }

    var vertex = owner;
    vertex = setMode(vertex, VERTEX_MODE);
    vertex = setReservedBits(vertex, @intCast(owner_vertex_num));
    return vertex;
}

// =============================================================================
// cellToVertexes — all (up to 6) vertices
// =============================================================================

pub fn cellToVertexes(cell: H3Index, vertexes: *[6]H3Index) Error!void {
    const is_pent = pure.isPentagon(cell);
    var i: i32 = 0;
    while (i < NUM_HEX_VERTS) : (i += 1) {
        if (i == 5 and is_pent) {
            vertexes[5] = 0;
        } else {
            vertexes[@intCast(i)] = try cellToVertex(cell, i);
        }
    }
}

// =============================================================================
// vertexToLatLng — single-vertex projection using substrate-grid enumeration
// =============================================================================

fn singleVertexLatLng(fijk_in: FaceIJK, res: i32, vertex_num: i32, is_pent: bool) LatLng {
    var fijk = fijk_in;
    var adj_res = res;
    var verts: [6]FaceIJK = undefined;
    if (is_pent) {
        var pverts: [5]FaceIJK = undefined;
        bnd.faceIjkPentToVerts(&fijk, &adj_res, &pverts);
        @memcpy(verts[0..5], &pverts);
    } else {
        bnd.faceIjkToVerts(&fijk, &adj_res, &verts);
    }
    var v = verts[@intCast(vertex_num)];
    if (is_pent) {
        _ = bnd.adjustPentVertOverage(&v, adj_res);
    } else {
        _ = h3dec.adjustOverageClassII(&v, adj_res, false, true);
    }
    const vec = proj.ijkToHex2d(v.coord);
    return h3dec.hex2dToGeo(vec, v.face, adj_res, true);
}

pub fn vertexToLatLng(vertex: H3Index) Error!LatLng {
    const vertex_num: i32 = getReservedBits(vertex);
    var owner = vertex;
    owner = setMode(owner, 1); // CELL_MODE
    owner = setReservedBits(owner, 0);

    var fijk: FaceIJK = undefined;
    try h3dec.h3ToFaceIjk(owner, &fijk);
    const res = getResolution(owner);
    const is_pent = pure.isPentagon(owner);
    return singleVertexLatLng(fijk, res, vertex_num, is_pent);
}

// =============================================================================
// isValidVertex — check mode + roundtrip through cellToVertex
// =============================================================================

pub fn isValidVertex(vertex: H3Index) bool {
    if (getMode(vertex) != VERTEX_MODE) return false;
    const vertex_num: i32 = getReservedBits(vertex);
    var owner = vertex;
    owner = setMode(owner, 1); // CELL_MODE
    owner = setReservedBits(owner, 0);
    if (!pure.isValidCell(owner)) return false;

    const canonical = cellToVertex(owner, vertex_num) catch return false;
    return vertex == canonical;
}

// =============================================================================
// Cross-validation tests
// =============================================================================

const testing = std.testing;

test "pure cellToVertex matches libh3 on random hex cells" {
    var rng = std.Random.DefaultPrng.init(0xFA11);
    var res: i32 = 4;
    while (res <= 10) : (res += 1) {
        for (0..15) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(cell)) continue;
            var v: i32 = 0;
            while (v < 6) : (v += 1) {
                const ours = try cellToVertex(cell, v);
                var theirs: H3Index = 0;
                const e = root.raw.cellToVertex(cell, v, &theirs);
                if (e != 0) continue;
                try testing.expectEqual(theirs, ours);
            }
        }
    }
}

test "pure cellToVertex matches libh3 on every pentagon" {
    var res: i32 = 3;
    while (res <= 8) : (res += 1) {
        var pents: [12]H3Index = undefined;
        try root.getPentagons(res, &pents);
        for (pents) |p| {
            var v: i32 = 0;
            while (v < 5) : (v += 1) {
                const ours = try cellToVertex(p, v);
                var theirs: H3Index = 0;
                const e = root.raw.cellToVertex(p, v, &theirs);
                if (e != 0) continue;
                try testing.expectEqual(theirs, ours);
            }
        }
    }
}

test "pure vertexToLatLng matches libh3 within tolerance" {
    var rng = std.Random.DefaultPrng.init(0xFAFE);
    var res: i32 = 4;
    while (res <= 9) : (res += 1) {
        for (0..10) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(cell)) continue;
            var v: i32 = 0;
            while (v < 6) : (v += 1) {
                const vert = try cellToVertex(cell, v);
                const ours = try vertexToLatLng(vert);
                var theirs: root.raw.LatLng = undefined;
                _ = root.raw.vertexToLatLng(vert, &theirs);
                try testing.expectApproxEqAbs(theirs.lat, ours.lat, 1e-9);
                const dlng = @abs(theirs.lng - ours.lng);
                try testing.expect(dlng < 1e-9 or @abs(dlng - 2.0 * std.math.pi) < 1e-9);
            }
        }
    }
}

test "pure cellToVertexes returns 6 for hex, 5 + 0 for pentagon" {
    const cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 7);
    var v6: [6]H3Index = undefined;
    try cellToVertexes(cell, &v6);
    var nonzero: usize = 0;
    for (v6) |x| if (x != 0) {
        nonzero += 1;
    };
    try testing.expectEqual(@as(usize, 6), nonzero);

    var pents: [12]H3Index = undefined;
    try root.getPentagons(5, &pents);
    try cellToVertexes(pents[0], &v6);
    nonzero = 0;
    for (v6) |x| if (x != 0) {
        nonzero += 1;
    };
    try testing.expectEqual(@as(usize, 5), nonzero);
}

test "pure isValidVertex roundtrips canonical vertices" {
    const cell = try root.latLngToCell(LatLng.fromDegrees(37.7749, -122.4194), 7);
    var v: i32 = 0;
    while (v < 6) : (v += 1) {
        const vert = try cellToVertex(cell, v);
        try testing.expect(isValidVertex(vert));
    }
    // Garbage rejection
    try testing.expect(!isValidVertex(0));
    try testing.expect(!isValidVertex(cell)); // cell mode, not vertex
}
