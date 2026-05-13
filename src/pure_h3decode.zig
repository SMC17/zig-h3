//! Pure-Zig H3 v4 index → lat/lng decoding — Phase 3c.
//!
//! Reverse of `pure_h3index.zig`. Translates `libh3`'s
//! `_h3ToFaceIjkWithInitializedFijk`, `_h3ToFaceIjk`, `_adjustOverageClassII`,
//! `_hex2dToGeo`, and `_geoAzDistanceRads`, plus the `faceNeighbors[20][4]`
//! table needed for overage handling.
//!
//! Public API:
//!   - `cellToLatLng(cell) → LatLng` — pure-Zig reverse projection. Cross-
//!     validated against `root.cellToLatLng` (libh3 wrapper) within a tight
//!     numeric tolerance.

const std = @import("std");
const root = @import("root.zig");
const proj = @import("pure_proj.zig");
const h3idx = @import("pure_h3index.zig");

pub const LatLng = root.LatLng;
pub const H3Index = root.H3Index;
pub const Error = root.Error;
pub const CoordIJK = proj.CoordIJK;
pub const FaceIJK = h3idx.FaceIJK;
pub const Direction = h3idx.Direction;
pub const MAX_RES = h3idx.MAX_RES;

// =============================================================================
// Resolution-scaling tables — verbatim from libh3 faceijk.c
// =============================================================================

/// `maxDimByCIIres[r]` — `7^(r/2)` × 2 for even r (Class II). Class III rows
/// (odd r) are placeholders; the overage path uses `_downAp7r` to convert to
/// the next finer Class II grid before lookup.
pub const maxDimByCIIres = [_]i32{
    2,        -1, 14,      -1,
    98,       -1, 686,     -1,
    4802,     -1, 33614,   -1,
    235298,   -1, 1647086, -1,
    11529602,
};

pub const unitScaleByCIIres = [_]i32{
    1,       -1, 7,      -1,
    49,      -1, 343,    -1,
    2401,    -1, 16807,  -1,
    117649,  -1, 823543, -1,
    5764801,
};

// =============================================================================
// FaceOrientIJK + faceNeighbors[20][4]
//
// Each face has 4 entries: index 0 = central face (self), 1 = IJ quadrant,
// 2 = KI quadrant, 3 = JK quadrant.
// =============================================================================

pub const FaceOrientIJK = struct {
    face: i32,
    translate: CoordIJK,
    ccw_rot60: i32,
};

pub const IJ_DIR: i32 = 1;
pub const KI_DIR: i32 = 2;
pub const JK_DIR: i32 = 3;

inline fn fo(face: i32, ti: i32, tj: i32, tk: i32, rot: i32) FaceOrientIJK {
    return .{
        .face = face,
        .translate = .{ .i = ti, .j = tj, .k = tk },
        .ccw_rot60 = rot,
    };
}

/// 20 faces × 4 directions = 80 entries, row-major (face × 4 + dir).
pub const faceNeighbors = [_]FaceOrientIJK{
    // face 0
    fo(0, 0, 0, 0, 0),  fo(4, 2, 0, 2, 1),  fo(1, 2, 2, 0, 5),  fo(5, 0, 2, 2, 3),
    // face 1
    fo(1, 0, 0, 0, 0),  fo(0, 2, 0, 2, 1),  fo(2, 2, 2, 0, 5),  fo(6, 0, 2, 2, 3),
    // face 2
    fo(2, 0, 0, 0, 0),  fo(1, 2, 0, 2, 1),  fo(3, 2, 2, 0, 5),  fo(7, 0, 2, 2, 3),
    // face 3
    fo(3, 0, 0, 0, 0),  fo(2, 2, 0, 2, 1),  fo(4, 2, 2, 0, 5),  fo(8, 0, 2, 2, 3),
    // face 4
    fo(4, 0, 0, 0, 0),  fo(3, 2, 0, 2, 1),  fo(0, 2, 2, 0, 5),  fo(9, 0, 2, 2, 3),
    // face 5
    fo(5, 0, 0, 0, 0),  fo(10, 2, 2, 0, 3), fo(14, 2, 0, 2, 3), fo(0, 0, 2, 2, 3),
    // face 6
    fo(6, 0, 0, 0, 0),  fo(11, 2, 2, 0, 3), fo(10, 2, 0, 2, 3), fo(1, 0, 2, 2, 3),
    // face 7
    fo(7, 0, 0, 0, 0),  fo(12, 2, 2, 0, 3), fo(11, 2, 0, 2, 3), fo(2, 0, 2, 2, 3),
    // face 8
    fo(8, 0, 0, 0, 0),  fo(13, 2, 2, 0, 3), fo(12, 2, 0, 2, 3), fo(3, 0, 2, 2, 3),
    // face 9
    fo(9, 0, 0, 0, 0),  fo(14, 2, 2, 0, 3), fo(13, 2, 0, 2, 3), fo(4, 0, 2, 2, 3),
    // face 10
    fo(10, 0, 0, 0, 0), fo(5, 2, 2, 0, 3),  fo(6, 2, 0, 2, 3),  fo(15, 0, 2, 2, 3),
    // face 11
    fo(11, 0, 0, 0, 0), fo(6, 2, 2, 0, 3),  fo(7, 2, 0, 2, 3),  fo(16, 0, 2, 2, 3),
    // face 12
    fo(12, 0, 0, 0, 0), fo(7, 2, 2, 0, 3),  fo(8, 2, 0, 2, 3),  fo(17, 0, 2, 2, 3),
    // face 13
    fo(13, 0, 0, 0, 0), fo(8, 2, 2, 0, 3),  fo(9, 2, 0, 2, 3),  fo(18, 0, 2, 2, 3),
    // face 14
    fo(14, 0, 0, 0, 0), fo(9, 2, 2, 0, 3),  fo(5, 2, 0, 2, 3),  fo(19, 0, 2, 2, 3),
    // face 15
    fo(15, 0, 0, 0, 0), fo(16, 2, 0, 2, 1), fo(19, 2, 2, 0, 5), fo(10, 0, 2, 2, 3),
    // face 16
    fo(16, 0, 0, 0, 0), fo(17, 2, 0, 2, 1), fo(15, 2, 2, 0, 5), fo(11, 0, 2, 2, 3),
    // face 17
    fo(17, 0, 0, 0, 0), fo(18, 2, 0, 2, 1), fo(16, 2, 2, 0, 5), fo(12, 0, 2, 2, 3),
    // face 18
    fo(18, 0, 0, 0, 0), fo(19, 2, 0, 2, 1), fo(17, 2, 2, 0, 5), fo(13, 0, 2, 2, 3),
    // face 19
    fo(19, 0, 0, 0, 0), fo(15, 2, 0, 2, 1), fo(18, 2, 2, 0, 5), fo(14, 0, 2, 2, 3),
};

comptime {
    std.debug.assert(faceNeighbors.len == 80);
}

inline fn neighborOrient(face: i32, dir: i32) FaceOrientIJK {
    return faceNeighbors[@as(usize, @intCast(face)) * 4 + @as(usize, @intCast(dir))];
}

// =============================================================================
// _neighbor — shift IJK in a given digit direction
// =============================================================================

pub fn neighborStep(ijk: *CoordIJK, digit: Direction) void {
    const d_int = @intFromEnum(digit);
    if (d_int > 0 and d_int < 7) {
        const uv = h3idx.UNIT_VECS[d_int];
        ijk.* = h3idx.ijkAdd(ijk.*, uv);
        proj.ijkNormalize(ijk);
    }
}

// =============================================================================
// _h3ToFaceIjkWithInitializedFijk
// =============================================================================

pub const Overage = enum(i32) { none = 0, face_edge = 1, new_face = 2 };

inline fn isClassIII(res: i32) bool {
    return (@mod(res, 2)) == 1;
}

const H3_RES_OFFSET: u6 = 52;
const H3_BC_OFFSET: u6 = 45;
const H3_DIGIT_MASK: u64 = 7;
const H3_PER_DIGIT_OFFSET: u6 = 3;

inline fn getResolution(h: H3Index) i32 {
    return @intCast((h >> H3_RES_OFFSET) & 0xF);
}

inline fn getBaseCellRaw(h: H3Index) i32 {
    return @intCast((h >> H3_BC_OFFSET) & 0x7F);
}

inline fn getDigit(h: H3Index, res: i32) Direction {
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * @as(i32, H3_PER_DIGIT_OFFSET));
    return @enumFromInt(@as(u3, @intCast((h >> shift) & H3_DIGIT_MASK)));
}

/// Returns `true` if the base cell can have overage; `false` if the cell
/// hierarchy is entirely on its home face.
pub fn h3ToFaceIjkWithInitializedFijk(h: H3Index, fijk: *FaceIJK) bool {
    const ijk = &fijk.coord;
    const res = getResolution(h);
    const bc = getBaseCellRaw(h);

    var possible_overage = true;
    if (!h3idx.isBaseCellPentagon(bc) and
        (res == 0 or (ijk.i == 0 and ijk.j == 0 and ijk.k == 0)))
    {
        possible_overage = false;
    }

    var r: i32 = 1;
    while (r <= res) : (r += 1) {
        if (isClassIII(r)) {
            h3idx.downAp7(ijk);
        } else {
            h3idx.downAp7r(ijk);
        }
        neighborStep(ijk, getDigit(h, r));
    }

    return possible_overage;
}

// =============================================================================
// _adjustOverageClassII — handles IJK overflow into neighboring face
// =============================================================================

pub fn adjustOverageClassII(fijk: *FaceIJK, res: i32, pent_leading4: bool, substrate: bool) Overage {
    var overage: Overage = .none;
    const ijk = &fijk.coord;

    var max_dim = maxDimByCIIres[@intCast(res)];
    if (substrate) max_dim *= 3;

    const sum = ijk.i + ijk.j + ijk.k;
    if (substrate and sum == max_dim) {
        overage = .face_edge;
    } else if (sum > max_dim) {
        overage = .new_face;

        var orient: FaceOrientIJK = undefined;
        if (ijk.k > 0) {
            if (ijk.j > 0) {
                orient = neighborOrient(fijk.face, JK_DIR);
            } else {
                orient = neighborOrient(fijk.face, KI_DIR);
                if (pent_leading4) {
                    const origin: CoordIJK = .{ .i = max_dim, .j = 0, .k = 0 };
                    var tmp = h3idx.ijkSub(ijk.*, origin);
                    h3idx.ijkRotate60cw(&tmp);
                    ijk.* = h3idx.ijkAdd(tmp, origin);
                }
            }
        } else {
            orient = neighborOrient(fijk.face, IJ_DIR);
        }

        fijk.face = orient.face;

        var ri: i32 = 0;
        while (ri < orient.ccw_rot60) : (ri += 1) h3idx.ijkRotate60ccw(ijk);

        var trans = orient.translate;
        var unit_scale = unitScaleByCIIres[@intCast(res)];
        if (substrate) unit_scale *= 3;
        h3idx.ijkScale(&trans, unit_scale);
        ijk.* = h3idx.ijkAdd(ijk.*, trans);
        proj.ijkNormalize(ijk);

        if (substrate and (ijk.i + ijk.j + ijk.k == max_dim)) {
            overage = .face_edge;
        }
    }
    return overage;
}

// =============================================================================
// _h3ToFaceIjk
// =============================================================================

pub fn h3ToFaceIjk(h_in: H3Index, fijk_out: *FaceIJK) Error!void {
    var h = h_in;
    const bc = getBaseCellRaw(h);
    if (bc < 0 or bc >= h3idx.NUM_BASE_CELLS) {
        fijk_out.* = .{ .face = 0, .coord = .{ .i = 0, .j = 0, .k = 0 } };
        return Error.CellInvalid;
    }

    // Pentagon leading-5 adjustment.
    if (h3idx.isBaseCellPentagon(bc) and h3idx.h3LeadingNonZeroDigit(h) == .ik_axes) {
        h = h3idx.h3Rotate60cw(h);
    }

    const bcd = h3idx.baseCellData[@intCast(bc)];
    fijk_out.* = .{
        .face = bcd.home_face,
        .coord = .{ .i = bcd.home_i, .j = bcd.home_j, .k = bcd.home_k },
    };

    if (!h3ToFaceIjkWithInitializedFijk(h, fijk_out)) return; // success, no overage

    // Potential overage: may need to re-project onto an adjacent face.
    const orig_ijk = fijk_out.coord;

    var res = getResolution(h);
    if (isClassIII(res)) {
        h3idx.downAp7r(&fijk_out.coord);
        res += 1;
    }

    const pent_leading4 = h3idx.isBaseCellPentagon(bc) and h3idx.h3LeadingNonZeroDigit(h) == .i_axes;
    if (adjustOverageClassII(fijk_out, res, pent_leading4, false) != .none) {
        // pentagon base cell can have secondary overage
        if (h3idx.isBaseCellPentagon(bc)) {
            while (adjustOverageClassII(fijk_out, res, false, false) != .none) {}
        }
        if (res != getResolution(h)) h3idx.upAp7r(&fijk_out.coord);
    } else if (res != getResolution(h)) {
        fijk_out.coord = orig_ijk;
    }
}

// =============================================================================
// _hex2dToGeo — inverse of geoToHex2d
// =============================================================================

const EPSILON: f64 = 0.0000000000000001;
const PI: f64 = std.math.pi;
const TWO_PI: f64 = 6.28318530717958647692528676655900576839433;
const PI_2: f64 = 1.5707963267948966;

fn constrainLng(lng_in: f64) f64 {
    var lng = lng_in;
    while (lng > PI) lng -= 2.0 * PI;
    while (lng < -PI) lng += 2.0 * PI;
    return lng;
}

/// Inverse spherical step: given an origin, a great-circle azimuth, and a
/// great-circle distance (all radians), compute the destination LatLng.
/// Mirrors libh3's `_geoAzDistanceRads`.
pub fn geoAzDistanceRads(origin: LatLng, az_in: f64, distance: f64) LatLng {
    if (distance < EPSILON) return origin;

    var out: LatLng = undefined;
    const az = proj.posAngleRads(az_in);

    if (az < EPSILON or @abs(az - PI) < EPSILON) {
        // due north or due south
        out.lat = if (az < EPSILON) origin.lat + distance else origin.lat - distance;
        if (@abs(out.lat - PI_2) < EPSILON) {
            out.lat = PI_2;
            out.lng = 0.0;
        } else if (@abs(out.lat + PI_2) < EPSILON) {
            out.lat = -PI_2;
            out.lng = 0.0;
        } else {
            out.lng = constrainLng(origin.lng);
        }
        return out;
    }

    var sinlat = @sin(origin.lat) * @cos(distance) +
        @cos(origin.lat) * @sin(distance) * @cos(az);
    if (sinlat > 1.0) sinlat = 1.0;
    if (sinlat < -1.0) sinlat = -1.0;
    out.lat = std.math.asin(sinlat);

    if (@abs(out.lat - PI_2) < EPSILON) {
        out.lat = PI_2;
        out.lng = 0.0;
    } else if (@abs(out.lat + PI_2) < EPSILON) {
        out.lat = -PI_2;
        out.lng = 0.0;
    } else {
        var sinlng = @sin(az) * @sin(distance) / @cos(out.lat);
        var coslng = (@cos(distance) - @sin(origin.lat) * @sin(out.lat)) /
            @cos(origin.lat) / @cos(out.lat);
        if (sinlng > 1.0) sinlng = 1.0;
        if (sinlng < -1.0) sinlng = -1.0;
        if (coslng > 1.0) coslng = 1.0;
        if (coslng < -1.0) coslng = -1.0;
        out.lng = constrainLng(origin.lng + std.math.atan2(sinlng, coslng));
    }
    return out;
}

/// Inverse projection: face-centered 2D hex coord → lat/lng. Mirrors libh3's
/// `_hex2dToGeo`. `substrate = false` for normal cell-center decoding.
pub fn hex2dToGeo(v: proj.Vec2d, face: i32, res: i32, substrate: bool) LatLng {
    var r = proj.vec2dMag(v);

    if (r < EPSILON) return proj.faceCenterGeo[@intCast(face)];

    var theta = std.math.atan2(v.y, v.x);

    // unscale by the aperture-7 ratio
    var i: i32 = 0;
    while (i < res) : (i += 1) r /= proj.SQRT7;

    if (substrate) {
        r /= 3.0;
        if (isClassIII(res)) r /= proj.SQRT7;
    }

    r *= proj.RES0_U_GNOMONIC;
    r = std.math.atan(r);

    // Class III: undo the rotation that was applied during forward projection
    if (!substrate and isClassIII(res)) {
        theta = proj.posAngleRads(theta + proj.AP7_ROT_RADS);
    }

    // CCW theta → azimuth from face center
    theta = proj.posAngleRads(proj.faceAxesAzRadsCII[@intCast(face)][0] - theta);

    return geoAzDistanceRads(proj.faceCenterGeo[@intCast(face)], theta, r);
}

pub fn faceIjkToGeo(fijk: FaceIJK, res: i32) LatLng {
    const v = proj.ijkToHex2d(fijk.coord);
    return hex2dToGeo(v, fijk.face, res, false);
}

// =============================================================================
// Public API: cellToLatLng
// =============================================================================

pub fn cellToLatLng(cell: H3Index) Error!LatLng {
    var fijk: FaceIJK = undefined;
    try h3ToFaceIjk(cell, &fijk);
    return faceIjkToGeo(fijk, getResolution(cell));
}

// =============================================================================
// Cross-validation tests
// =============================================================================

const testing = std.testing;

// libh3's _hex2dToGeo and our hex2dToGeo accumulate floating-point error
// through asin / atan2 / multiple multiplications. 1e-10 radians ≈ 0.6 mm of
// arc-length on Earth — vastly tighter than any application needs.
const ANGLE_TOLERANCE: f64 = 1e-10;

fn approxEqLatLng(a: LatLng, b: LatLng) !void {
    try testing.expectApproxEqAbs(a.lat, b.lat, ANGLE_TOLERANCE);
    // Longitude wrap: ±π are equivalent; check both branches.
    const dlng = @abs(a.lng - b.lng);
    const wrapped = @abs(dlng - 2.0 * PI);
    try testing.expect(dlng < ANGLE_TOLERANCE or wrapped < ANGLE_TOLERANCE);
}

test "pure cellToLatLng matches libh3 on landmark cells across all resolutions" {
    const landmarks = [_]LatLng{
        LatLng.fromDegrees(40.6892, -74.0445),
        LatLng.fromDegrees(37.7749, -122.4194),
        LatLng.fromDegrees(51.5074, -0.1278),
        LatLng.fromDegrees(35.6762, 139.6503),
        LatLng.fromDegrees(-33.8688, 151.2093),
        LatLng.fromDegrees(0.0, 0.0),
        LatLng.fromDegrees(89.0, 0.0),
        LatLng.fromDegrees(-89.0, 0.0),
    };
    for (landmarks) |p| {
        var res: i32 = 0;
        while (res <= MAX_RES) : (res += 1) {
            const cell = try root.latLngToCell(p, res);
            const theirs = try root.cellToLatLng(cell);
            const ours = try cellToLatLng(cell);
            try approxEqLatLng(theirs, ours);
        }
    }
}

test "pure cellToLatLng matches libh3 on random cells at every resolution" {
    var rng = std.Random.DefaultPrng.init(0xC0FFEE_F00DBA12);
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        for (0..50) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            const theirs = try root.cellToLatLng(cell);
            const ours = try cellToLatLng(cell);
            try approxEqLatLng(theirs, ours);
        }
    }
}

test "pure cellToLatLng matches libh3 on every res-0 base cell" {
    var cells: [122]H3Index = undefined;
    try root.getRes0Cells(&cells);
    for (cells) |cell| {
        const theirs = try root.cellToLatLng(cell);
        const ours = try cellToLatLng(cell);
        try approxEqLatLng(theirs, ours);
    }
}

test "pure cellToLatLng matches libh3 on every pentagon at every resolution" {
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        var pents: [12]H3Index = undefined;
        try root.getPentagons(res, &pents);
        for (pents) |p| {
            const theirs = try root.cellToLatLng(p);
            const ours = try cellToLatLng(p);
            try approxEqLatLng(theirs, ours);
        }
    }
}

test "pure latLngToCell ∘ cellToLatLng is identity (with cell stability)" {
    var rng = std.Random.DefaultPrng.init(0xBABE_F00D);
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        for (0..20) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell1 = try h3idx.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            const center = try cellToLatLng(cell1);
            const cell2 = try h3idx.latLngToCell(center, res);
            try testing.expectEqual(cell1, cell2);
        }
    }
}
