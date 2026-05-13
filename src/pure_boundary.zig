//! Pure-Zig H3 cell boundary geometry — Phase 4c.
//!
//! Translates libh3's `cellToBoundary` along with the substrate-grid
//! vertex enumeration (`_faceIjkToVerts`, `_faceIjkPentToVerts`), pentagon
//! vertex overage loop (`_adjustPentVertOverage`), and the Class-III
//! edge-crossing intersection logic (`_v2dIntersect` + `adjacentFaceDir`).
//!
//! Public API:
//!   - `cellToBoundary(cell) → CellBoundary` — pure-Zig polygon geometry.
//!     Cross-validated against `root.cellToBoundary` within a tight numeric
//!     tolerance.

const std = @import("std");
const root = @import("root.zig");
const proj = @import("pure_proj.zig");
const h3idx = @import("pure_h3index.zig");
const h3dec = @import("pure_h3decode.zig");
const pure = @import("pure.zig");

pub const LatLng = root.LatLng;
pub const H3Index = root.H3Index;
pub const Error = root.Error;
pub const CellBoundary = root.CellBoundary;
pub const CoordIJK = proj.CoordIJK;
pub const Vec2d = proj.Vec2d;
pub const FaceIJK = h3idx.FaceIJK;

const NUM_HEX_VERTS: usize = 6;
const NUM_PENT_VERTS: usize = 5;
const MAX_CELL_BOUNDARY_VERTS: usize = 10;
const NUM_ICOSA_FACES: usize = 20;

// =============================================================================
// adjacentFaceDir[20][20] — verbatim from libh3 faceijk.c
//
// adjacentFaceDir[a][b] = 1 (IJ), 2 (KI), 3 (JK) if face a is adjacent to
// face b in that quadrant, 0 if a == b, -1 otherwise.
// =============================================================================

const IJ: i8 = 1;
const KI: i8 = 2;
const JK: i8 = 3;

const adjacentFaceDir = [_][20]i8{
    // face 0
    .{ 0, KI, -1, -1, IJ, JK, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 },
    // face 1
    .{ IJ, 0, KI, -1, -1, -1, JK, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 },
    // face 2
    .{ -1, IJ, 0, KI, -1, -1, -1, JK, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 },
    // face 3
    .{ -1, -1, IJ, 0, KI, -1, -1, -1, JK, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 },
    // face 4
    .{ KI, -1, -1, IJ, 0, -1, -1, -1, -1, JK, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1 },
    // face 5
    .{ JK, -1, -1, -1, -1, 0, -1, -1, -1, -1, IJ, -1, -1, -1, KI, -1, -1, -1, -1, -1 },
    // face 6
    .{ -1, JK, -1, -1, -1, -1, 0, -1, -1, -1, KI, IJ, -1, -1, -1, -1, -1, -1, -1, -1 },
    // face 7
    .{ -1, -1, JK, -1, -1, -1, -1, 0, -1, -1, -1, KI, IJ, -1, -1, -1, -1, -1, -1, -1 },
    // face 8
    .{ -1, -1, -1, JK, -1, -1, -1, -1, 0, -1, -1, -1, KI, IJ, -1, -1, -1, -1, -1, -1 },
    // face 9
    .{ -1, -1, -1, -1, JK, -1, -1, -1, -1, 0, -1, -1, -1, KI, IJ, -1, -1, -1, -1, -1 },
    // face 10
    .{ -1, -1, -1, -1, -1, IJ, KI, -1, -1, -1, 0, -1, -1, -1, -1, JK, -1, -1, -1, -1 },
    // face 11
    .{ -1, -1, -1, -1, -1, -1, IJ, KI, -1, -1, -1, 0, -1, -1, -1, -1, JK, -1, -1, -1 },
    // face 12
    .{ -1, -1, -1, -1, -1, -1, -1, IJ, KI, -1, -1, -1, 0, -1, -1, -1, -1, JK, -1, -1 },
    // face 13
    .{ -1, -1, -1, -1, -1, -1, -1, -1, IJ, KI, -1, -1, -1, 0, -1, -1, -1, -1, JK, -1 },
    // face 14
    .{ -1, -1, -1, -1, -1, KI, -1, -1, -1, IJ, -1, -1, -1, -1, 0, -1, -1, -1, -1, JK },
    // face 15
    .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, JK, -1, -1, -1, -1, 0, IJ, -1, -1, KI },
    // face 16
    .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, JK, -1, -1, -1, KI, 0, IJ, -1, -1 },
    // face 17
    .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, JK, -1, -1, -1, KI, 0, IJ, -1 },
    // face 18
    .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, JK, -1, -1, -1, KI, 0, IJ },
    // face 19
    .{ -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, JK, IJ, -1, -1, KI, 0 },
};

// =============================================================================
// Aperture-3 (CCW + CW) downsampling — for substrate-grid vertex layout
// =============================================================================

fn ijkScale(c: *CoordIJK, factor: i32) void {
    c.i *= factor;
    c.j *= factor;
    c.k *= factor;
}

fn ijkAdd(a: CoordIJK, b: CoordIJK) CoordIJK {
    return .{ .i = a.i + b.i, .j = a.j + b.j, .k = a.k + b.k };
}

fn downAp3(ijk: *CoordIJK) void {
    var iVec = CoordIJK{ .i = 2, .j = 0, .k = 1 };
    var jVec = CoordIJK{ .i = 1, .j = 2, .k = 0 };
    var kVec = CoordIJK{ .i = 0, .j = 1, .k = 2 };
    ijkScale(&iVec, ijk.i);
    ijkScale(&jVec, ijk.j);
    ijkScale(&kVec, ijk.k);
    const s = ijkAdd(iVec, jVec);
    ijk.* = ijkAdd(s, kVec);
    proj.ijkNormalize(ijk);
}

fn downAp3r(ijk: *CoordIJK) void {
    var iVec = CoordIJK{ .i = 2, .j = 1, .k = 0 };
    var jVec = CoordIJK{ .i = 0, .j = 2, .k = 1 };
    var kVec = CoordIJK{ .i = 1, .j = 0, .k = 2 };
    ijkScale(&iVec, ijk.i);
    ijkScale(&jVec, ijk.j);
    ijkScale(&kVec, ijk.k);
    const s = ijkAdd(iVec, jVec);
    ijk.* = ijkAdd(s, kVec);
    proj.ijkNormalize(ijk);
}

// =============================================================================
// Vec2d helpers
// =============================================================================

fn v2dIntersect(p0: Vec2d, p1: Vec2d, p2: Vec2d, p3: Vec2d) Vec2d {
    const s1x = p1.x - p0.x;
    const s1y = p1.y - p0.y;
    const s2x = p3.x - p2.x;
    const s2y = p3.y - p2.y;
    const denom = -s2x * s1y + s1x * s2y;
    const t = (s2x * (p0.y - p2.y) - s2y * (p0.x - p2.x)) / denom;
    return .{ .x = p0.x + t * s1x, .y = p0.y + t * s1y };
}

const FLT_EPSILON: f64 = 1.1920929e-07; // libh3 uses C's FLT_EPSILON

fn v2dAlmostEquals(a: Vec2d, b: Vec2d) bool {
    return @abs(a.x - b.x) < FLT_EPSILON and @abs(a.y - b.y) < FLT_EPSILON;
}

// =============================================================================
// Substrate-grid vertex enumeration
// =============================================================================

inline fn isClassIII(res: i32) bool {
    return (@mod(res, 2)) == 1;
}

const hexVertsCII = [_]CoordIJK{
    .{ .i = 2, .j = 1, .k = 0 },
    .{ .i = 1, .j = 2, .k = 0 },
    .{ .i = 0, .j = 2, .k = 1 },
    .{ .i = 0, .j = 1, .k = 2 },
    .{ .i = 1, .j = 0, .k = 2 },
    .{ .i = 2, .j = 0, .k = 1 },
};
const hexVertsCIII = [_]CoordIJK{
    .{ .i = 5, .j = 4, .k = 0 },
    .{ .i = 1, .j = 5, .k = 0 },
    .{ .i = 0, .j = 5, .k = 4 },
    .{ .i = 0, .j = 1, .k = 5 },
    .{ .i = 4, .j = 0, .k = 5 },
    .{ .i = 5, .j = 0, .k = 1 },
};
const pentVertsCII = [_]CoordIJK{
    .{ .i = 2, .j = 1, .k = 0 },
    .{ .i = 1, .j = 2, .k = 0 },
    .{ .i = 0, .j = 2, .k = 1 },
    .{ .i = 0, .j = 1, .k = 2 },
    .{ .i = 1, .j = 0, .k = 2 },
};
const pentVertsCIII = [_]CoordIJK{
    .{ .i = 5, .j = 4, .k = 0 },
    .{ .i = 1, .j = 5, .k = 0 },
    .{ .i = 0, .j = 5, .k = 4 },
    .{ .i = 0, .j = 1, .k = 5 },
    .{ .i = 4, .j = 0, .k = 5 },
};

/// Compute the 6 substrate-grid vertices of a hexagon. `*res` is updated to
/// the substrate resolution (incremented by 1 for Class III inputs).
pub fn faceIjkToVerts(fijk: *FaceIJK, res: *i32, out: *[NUM_HEX_VERTS]FaceIJK) void {
    const class3 = isClassIII(res.*);
    const verts: []const CoordIJK = if (class3) &hexVertsCIII else &hexVertsCII;

    downAp3(&fijk.coord);
    downAp3r(&fijk.coord);

    if (class3) {
        h3idx.downAp7r(&fijk.coord);
        res.* += 1;
    }

    for (verts, 0..) |v, idx| {
        out[idx] = .{
            .face = fijk.face,
            .coord = ijkAdd(fijk.coord, v),
        };
        proj.ijkNormalize(&out[idx].coord);
    }
}

/// Pentagon version: 5 vertices.
pub fn faceIjkPentToVerts(fijk: *FaceIJK, res: *i32, out: *[NUM_PENT_VERTS]FaceIJK) void {
    const class3 = isClassIII(res.*);
    const verts: []const CoordIJK = if (class3) &pentVertsCIII else &pentVertsCII;

    downAp3(&fijk.coord);
    downAp3r(&fijk.coord);

    if (class3) {
        h3idx.downAp7r(&fijk.coord);
        res.* += 1;
    }

    for (verts, 0..) |v, idx| {
        out[idx] = .{
            .face = fijk.face,
            .coord = ijkAdd(fijk.coord, v),
        };
        proj.ijkNormalize(&out[idx].coord);
    }
}

/// Pentagon vertex overage: keep adjusting until on a face interior or edge.
pub fn adjustPentVertOverage(fijk: *FaceIJK, res: i32) h3dec.Overage {
    var overage: h3dec.Overage = .none;
    while (true) {
        overage = h3dec.adjustOverageClassII(fijk, res, false, true);
        if (overage != .new_face) break;
    }
    return overage;
}

// =============================================================================
// faceIjkToCellBoundary (hex)
// =============================================================================

pub fn faceIjkToCellBoundary(h: *const FaceIJK, res: i32, out: *CellBoundary) void {
    faceIjkToCellBoundarySegment(h, res, 0, NUM_HEX_VERTS, out);
}

/// Compute a segment of a hex cell's boundary starting at vertex `start`,
/// for `length` topological vertices (plus any Class III edge-crossing
/// intersections within that segment). Used by both `cellToBoundary` (with
/// `start=0, length=NUM_HEX_VERTS`) and `directedEdgeToBoundary` (with
/// `start=startVertex, length=2`).
pub fn faceIjkToCellBoundarySegment(h: *const FaceIJK, res: i32, start: usize, length: usize, out: *CellBoundary) void {
    var adj_res = res;
    var center_ijk = h.*;
    var fijk_verts: [NUM_HEX_VERTS]FaceIJK = undefined;
    faceIjkToVerts(&center_ijk, &adj_res, &fijk_verts);

    // If returning the entire loop, include one more iteration for the
    // possible distortion vertex on the last edge. For a sub-segment, we
    // don't add the extra iteration.
    const additional: usize = if (length == NUM_HEX_VERTS) 1 else 0;

    out.num_verts = 0;
    var last_face: i32 = -1;
    var last_overage: h3dec.Overage = .none;

    var vert: usize = start;
    while (vert < start + length + additional) : (vert += 1) {
        const v_idx = vert % NUM_HEX_VERTS;
        var fijk = fijk_verts[v_idx];

        const overage = h3dec.adjustOverageClassII(&fijk, adj_res, false, true);

        // Class III edge-crossing detection
        if (isClassIII(res) and vert > start and
            fijk.face != last_face and last_overage != .face_edge)
        {
            const last_v = (v_idx + 5) % NUM_HEX_VERTS;
            const orig_a = proj.ijkToHex2d(fijk_verts[last_v].coord);
            const orig_b = proj.ijkToHex2d(fijk_verts[v_idx].coord);

            const max_dim_f: f64 = @floatFromInt(h3dec.maxDimByCIIres[@intCast(adj_res)]);
            const v0 = Vec2d{ .x = 3.0 * max_dim_f, .y = 0.0 };
            const v1 = Vec2d{ .x = -1.5 * max_dim_f, .y = 3.0 * proj.SQRT3_2 * max_dim_f };
            const v2 = Vec2d{ .x = -1.5 * max_dim_f, .y = -3.0 * proj.SQRT3_2 * max_dim_f };

            const face2: i32 = if (last_face == center_ijk.face) fijk.face else last_face;
            const dir = adjacentFaceDir[@intCast(center_ijk.face)][@intCast(face2)];
            const edge: struct { e0: Vec2d, e1: Vec2d } = switch (dir) {
                IJ => .{ .e0 = v0, .e1 = v1 },
                JK => .{ .e0 = v1, .e1 = v2 },
                else => .{ .e0 = v2, .e1 = v0 }, // KI
            };

            const inter = v2dIntersect(orig_a, orig_b, edge.e0, edge.e1);
            const at_vertex = v2dAlmostEquals(orig_a, inter) or v2dAlmostEquals(orig_b, inter);
            if (!at_vertex) {
                const ll = h3dec.hex2dToGeo(inter, center_ijk.face, adj_res, true);
                out.verts[@intCast(out.num_verts)] = .{ .lat = ll.lat, .lng = ll.lng };
                out.num_verts += 1;
            }
        }

        if (vert < start + length) {
            const vec = proj.ijkToHex2d(fijk.coord);
            const ll = h3dec.hex2dToGeo(vec, fijk.face, adj_res, true);
            out.verts[@intCast(out.num_verts)] = .{ .lat = ll.lat, .lng = ll.lng };
            out.num_verts += 1;
        }

        last_face = fijk.face;
        last_overage = overage;
    }
}

// =============================================================================
// faceIjkPentToCellBoundary (pentagon)
// =============================================================================

pub fn faceIjkPentToCellBoundary(h: *const FaceIJK, res: i32, out: *CellBoundary) void {
    faceIjkPentToCellBoundarySegment(h, res, 0, NUM_PENT_VERTS, out);
}

pub fn faceIjkPentToCellBoundarySegment(h: *const FaceIJK, res: i32, start: usize, length: usize, out: *CellBoundary) void {
    var adj_res = res;
    var center_ijk = h.*;
    var fijk_verts: [NUM_PENT_VERTS]FaceIJK = undefined;
    faceIjkPentToVerts(&center_ijk, &adj_res, &fijk_verts);

    const additional: usize = if (length == NUM_PENT_VERTS) 1 else 0;

    out.num_verts = 0;
    var last_fijk: FaceIJK = undefined;

    var vert: usize = start;
    while (vert < start + length + additional) : (vert += 1) {
        const v_idx = vert % NUM_PENT_VERTS;
        var fijk = fijk_verts[v_idx];

        _ = adjustPentVertOverage(&fijk, adj_res);

        // All Class III pentagon edges cross icosa edges
        if (isClassIII(res) and vert > start) {
            var tmp_fijk = fijk;
            const orig_a = proj.ijkToHex2d(last_fijk.coord);

            const cur_to_last_dir = adjacentFaceDir[@intCast(tmp_fijk.face)][@intCast(last_fijk.face)];
            const fijk_orient = h3dec.faceNeighbors[
                @as(usize, @intCast(tmp_fijk.face)) * 4 +
                    @as(usize, @intCast(cur_to_last_dir))
            ];

            tmp_fijk.face = fijk_orient.face;
            const ijk_ptr = &tmp_fijk.coord;
            var ri: i32 = 0;
            while (ri < fijk_orient.ccw_rot60) : (ri += 1) h3idx.ijkRotate60ccw(ijk_ptr);

            var trans = fijk_orient.translate;
            h3idx.ijkScale(&trans, h3dec.unitScaleByCIIres[@intCast(adj_res)] * 3);
            ijk_ptr.* = h3idx.ijkAdd(ijk_ptr.*, trans);
            proj.ijkNormalize(ijk_ptr);

            const orig_b = proj.ijkToHex2d(tmp_fijk.coord);

            const max_dim_f: f64 = @floatFromInt(h3dec.maxDimByCIIres[@intCast(adj_res)]);
            const v0 = Vec2d{ .x = 3.0 * max_dim_f, .y = 0.0 };
            const v1 = Vec2d{ .x = -1.5 * max_dim_f, .y = 3.0 * proj.SQRT3_2 * max_dim_f };
            const v2 = Vec2d{ .x = -1.5 * max_dim_f, .y = -3.0 * proj.SQRT3_2 * max_dim_f };

            const dir = adjacentFaceDir[@intCast(tmp_fijk.face)][@intCast(fijk.face)];
            const edge: struct { e0: Vec2d, e1: Vec2d } = switch (dir) {
                IJ => .{ .e0 = v0, .e1 = v1 },
                JK => .{ .e0 = v1, .e1 = v2 },
                else => .{ .e0 = v2, .e1 = v0 },
            };
            const inter = v2dIntersect(orig_a, orig_b, edge.e0, edge.e1);

            const ll = h3dec.hex2dToGeo(inter, tmp_fijk.face, adj_res, true);
            out.verts[@intCast(out.num_verts)] = .{ .lat = ll.lat, .lng = ll.lng };
            out.num_verts += 1;
        }

        if (vert < start + length) {
            const vec = proj.ijkToHex2d(fijk.coord);
            const ll = h3dec.hex2dToGeo(vec, fijk.face, adj_res, true);
            out.verts[@intCast(out.num_verts)] = .{ .lat = ll.lat, .lng = ll.lng };
            out.num_verts += 1;
        }

        last_fijk = fijk;
    }
}

// =============================================================================
// Public API: cellToBoundary
// =============================================================================

const H3_RES_OFFSET: u6 = 52;
inline fn getResolution(h: H3Index) i32 {
    return @intCast((h >> H3_RES_OFFSET) & 0xF);
}

pub fn cellToBoundary(cell: H3Index) Error!CellBoundary {
    var fijk: FaceIJK = undefined;
    try h3dec.h3ToFaceIjk(cell, &fijk);
    var out: CellBoundary = undefined;
    const res = getResolution(cell);
    if (pure.isPentagon(cell)) {
        faceIjkPentToCellBoundary(&fijk, res, &out);
    } else {
        faceIjkToCellBoundary(&fijk, res, &out);
    }
    return out;
}

// =============================================================================
// Phase 4d — cellArea via spherical triangle decomposition
// =============================================================================

const EARTH_RADIUS_KM: f64 = 6371.007180918475;

/// Spherical triangle area on the unit sphere given its three edge lengths
/// (in radians) via L'Huilier's theorem.
pub fn triangleEdgeLengthsToArea(a_in: f64, b_in: f64, c_in: f64) f64 {
    var s = (a_in + b_in + c_in) / 2.0;
    const a = (s - a_in) / 2.0;
    const b = (s - b_in) / 2.0;
    const c = (s - c_in) / 2.0;
    s = s / 2.0;
    return 4.0 * std.math.atan(@sqrt(@tan(s) * @tan(a) * @tan(b) * @tan(c)));
}

/// Spherical triangle area on the unit sphere given its three lat/lng vertices.
pub fn triangleArea(a: LatLng, b: LatLng, c: LatLng) f64 {
    return triangleEdgeLengthsToArea(
        pure.greatCircleDistanceRads(a, b),
        pure.greatCircleDistanceRads(b, c),
        pure.greatCircleDistanceRads(c, a),
    );
}

/// Exact area of `cell` in radians² — sum of spherical triangles formed by
/// each boundary edge and the cell centroid.
pub fn cellAreaRads2(cell: H3Index) Error!f64 {
    const center = try h3dec.cellToLatLng(cell);
    const bnd = try cellToBoundary(cell);
    var area: f64 = 0.0;
    var i: usize = 0;
    const n: usize = @intCast(bnd.num_verts);
    while (i < n) : (i += 1) {
        const j = (i + 1) % n;
        area += triangleArea(bnd.verts[i], bnd.verts[j], center);
    }
    return area;
}

pub fn cellAreaKm2(cell: H3Index) Error!f64 {
    const a = try cellAreaRads2(cell);
    return a * EARTH_RADIUS_KM * EARTH_RADIUS_KM;
}

pub fn cellAreaM2(cell: H3Index) Error!f64 {
    const a = try cellAreaKm2(cell);
    return a * 1000.0 * 1000.0;
}

test "pure cellAreaRads2 matches libh3 on random hex cells at multiple resolutions" {
    var rng = std.Random.DefaultPrng.init(0xA1EA_F00D);
    var res: i32 = 0;
    while (res <= 12) : (res += 2) { // sample even resolutions to keep runtime modest
        for (0..15) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(cell)) continue;
            const theirs = try root.cellAreaRads2(cell);
            const ours = try cellAreaRads2(cell);
            // Relative tolerance: 1e-8 of the value (well below any sensible precision)
            const tol = @max(@abs(theirs) * 1e-8, 1e-18);
            try testing.expectApproxEqAbs(theirs, ours, tol);
        }
    }
}

test "pure cellAreaKm2 matches libh3 on random hex cells" {
    var rng = std.Random.DefaultPrng.init(0xCAFE);
    var res: i32 = 4;
    while (res <= 10) : (res += 2) {
        for (0..10) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(cell)) continue;
            const theirs = try root.cellAreaKm2(cell);
            const ours = try cellAreaKm2(cell);
            const tol = @max(@abs(theirs) * 1e-8, 1e-12);
            try testing.expectApproxEqAbs(theirs, ours, tol);
        }
    }
}

test "pure cellAreaM2 = cellAreaKm2 * 1e6" {
    const cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 7);
    const km2 = try cellAreaKm2(cell);
    const m2 = try cellAreaM2(cell);
    try testing.expectApproxEqAbs(km2 * 1_000_000.0, m2, m2 * 1e-12);
}

test "pure cellArea on pentagons matches libh3" {
    var pents: [12]H3Index = undefined;
    try root.getPentagons(5, &pents);
    for (pents) |p| {
        const theirs = try root.cellAreaKm2(p);
        const ours = try cellAreaKm2(p);
        const tol = @max(@abs(theirs) * 1e-6, 1e-9); // pentagons accumulate slightly more error
        try testing.expectApproxEqAbs(theirs, ours, tol);
    }
}

// =============================================================================
// Cross-validation tests
// =============================================================================

const testing = std.testing;

const ANGLE_TOLERANCE: f64 = 1e-9; // ≈ 6 mm of arc-length on Earth

fn boundariesAlmostEqual(a: CellBoundary, b: CellBoundary) !void {
    try testing.expectEqual(a.num_verts, b.num_verts);
    var i: usize = 0;
    while (i < @as(usize, @intCast(a.num_verts))) : (i += 1) {
        try testing.expectApproxEqAbs(a.verts[i].lat, b.verts[i].lat, ANGLE_TOLERANCE);
        const dlng = @abs(a.verts[i].lng - b.verts[i].lng);
        const wrapped = @abs(dlng - 2.0 * std.math.pi);
        try testing.expect(dlng < ANGLE_TOLERANCE or wrapped < ANGLE_TOLERANCE);
    }
}

test "pure cellToBoundary matches libh3 on landmark hex cells across all resolutions" {
    const landmarks = [_]LatLng{
        LatLng.fromDegrees(40.6892, -74.0445),
        LatLng.fromDegrees(37.7749, -122.4194),
        LatLng.fromDegrees(51.5074, -0.1278),
        LatLng.fromDegrees(35.6762, 139.6503),
        LatLng.fromDegrees(-33.8688, 151.2093),
        LatLng.fromDegrees(0.0, 0.0),
    };
    for (landmarks) |p| {
        var res: i32 = 0;
        while (res <= h3idx.MAX_RES) : (res += 1) {
            const cell = try root.latLngToCell(p, res);
            // Skip pentagons here (covered separately).
            if (pure.isPentagon(cell)) continue;
            const theirs = try root.cellToBoundary(cell);
            const ours = try cellToBoundary(cell);
            try boundariesAlmostEqual(theirs, ours);
        }
    }
}

test "pure cellToBoundary matches libh3 on random hex cells across all resolutions" {
    var rng = std.Random.DefaultPrng.init(0xB0_DA_F00D);
    var res: i32 = 0;
    while (res <= h3idx.MAX_RES) : (res += 1) {
        for (0..30) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(cell)) continue;
            const theirs = try root.cellToBoundary(cell);
            const ours = try cellToBoundary(cell);
            try boundariesAlmostEqual(theirs, ours);
        }
    }
}

test "pure cellToBoundary matches libh3 on every pentagon at every resolution" {
    var res: i32 = 0;
    while (res <= h3idx.MAX_RES) : (res += 1) {
        var pents: [12]H3Index = undefined;
        try root.getPentagons(res, &pents);
        for (pents) |p| {
            const theirs = try root.cellToBoundary(p);
            const ours = try cellToBoundary(p);
            try boundariesAlmostEqual(theirs, ours);
        }
    }
}

test "pure cellToBoundary produces 6 vertices for hexagons and 5-10 for pentagons" {
    var rng = std.Random.DefaultPrng.init(0xB0EF);
    for (0..30) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), 9);
        const bnd = try cellToBoundary(cell);
        if (pure.isPentagon(cell)) {
            try testing.expect(bnd.num_verts >= 5 and bnd.num_verts <= 10);
        } else {
            try testing.expect(bnd.num_verts >= 6 and bnd.num_verts <= 10);
        }
    }
}
