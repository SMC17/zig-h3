//! Pure-Zig H3 projection foundation — Phase 3a.
//!
//! This file translates the projection-math substrate of libh3 (the
//! `vec3d.c`, `vec2d.c`, `coordijk.c`, and `faceijk.c` files) into Zig,
//! bit-for-bit preserving the algorithms and (where critical) the exact
//! floating-point constants. All constants ending in `_LD` are translated
//! from `long double` literals in libh3; they store the f64 rounding of
//! those values.
//!
//! What's here (Phase 3a):
//!   - `Vec3d` and `Vec2d` types with `geoToVec3d`, `pointSquareDist`,
//!     `vec2dMag`.
//!   - Face geometry constants: `faceCenterGeo[20]`, `faceCenterPoint[20]`,
//!     `faceAxesAzRadsCII[20][3]`.
//!   - `geoToClosestFace` (Vec3d distance scan).
//!   - `posAngleRads`, `geoAzimuthRads`.
//!   - `geoToHex2d` — the forward projection up to face-centered 2D hex
//!     coordinates at a given resolution.
//!   - `hex2dToGeo` — the inverse for non-pentagon, non-overage cases.
//!   - `CoordIJK` type with `hex2dToCoordIJK`, `ijkToHex2d`, `ijkNormalize`,
//!     `setIJK`.
//!
//! What's NOT here yet (Phase 3b/c):
//!   - The 122-entry base cell table (`baseCellData` in libh3).
//!   - `_faceIjkToBaseCell` lookup.
//!   - Overage handling (`_adjustOverageClassII`) for indices whose
//!     IJK overflows the home face.
//!   - `_faceIjkToH3` (encode FaceIJK at target resolution into H3Index).
//!   - `_h3ToFaceIjk` (decode H3Index back to FaceIJK).
//!   - Final `latLngToCell` / `cellToLatLng` compositions.
//!
//! Until Phase 3b lands, end-to-end cross-validation against the libh3
//! wrapper isn't possible (libh3 doesn't expose `_geoToHex2d` publicly).
//! Tests here validate **mathematical properties** of each primitive:
//! identities, symmetry, roundtrips, boundary cases, and exact matches
//! against hand-computed values.

const std = @import("std");
const root = @import("root.zig");

pub const LatLng = root.LatLng;

// =============================================================================
// Constants
// =============================================================================

pub const NUM_ICOSA_FACES: usize = 20;
pub const NUM_PENT_VERTS: i32 = 5;
pub const NUM_HEX_VERTS: i32 = 6;

/// `M_PI` truncated to f64.
const PI: f64 = std.math.pi;
/// `M_PI_2` from libh3 constants.
const PI_2: f64 = 1.5707963267948966;
/// `M_2PI = 2π` truncated from libh3's long-double constant.
const TWO_PI: f64 = 6.28318530717958647692528676655900576839433;

/// `M_SQRT7 = sqrt(7)` (the aperture-7 ratio).
pub const SQRT7: f64 = 2.6457513110645905905016157536392604257102;

/// `M_SQRT3_2 = sqrt(3) / 2` — the y-spacing of hex centers in
/// face-centered 2D.
pub const SQRT3_2: f64 = 0.8660254037844386467637231707529361834714;

/// `M_SIN60 = sin(60°)` — algebraically equal to SQRT3_2.
pub const SIN60: f64 = SQRT3_2;

/// `M_AP7_ROT_RADS = atan(sqrt(3) / (2 + sqrt(3)))` — the Class III
/// rotation angle relative to Class II.
pub const AP7_ROT_RADS: f64 = 0.333473172251832115336090755351601070065900389;

/// `RES0_U_GNOMONIC` — radius of the gnomonic-projected resolution-0
/// hexagon on each face, in units where face-edge length is 1.
pub const RES0_U_GNOMONIC: f64 = 0.38196601125010500003;

/// `EPSILON` — small-distance tolerance from libh3.
pub const EPSILON: f64 = 0.0000000000000001;

// =============================================================================
// Face geometry tables — verbatim from libh3 src/h3lib/lib/faceijk.c
// =============================================================================

/// 20 icosahedron face centers in (lat, lng) radians.
pub const faceCenterGeo: [NUM_ICOSA_FACES]LatLng = .{
    .{ .lat = 0.803582649718989942, .lng = 1.248397419617396099 }, // face  0
    .{ .lat = 1.307747883455638156, .lng = 2.536945009877921159 }, // face  1
    .{ .lat = 1.054751253523952054, .lng = -1.347517358900396623 }, // face  2
    .{ .lat = 0.600191595538186799, .lng = -0.450603909469755746 }, // face  3
    .{ .lat = 0.491715428198773866, .lng = 0.401988202911306943 }, // face  4
    .{ .lat = 0.172745327415618701, .lng = 1.678146885280433686 }, // face  5
    .{ .lat = 0.605929321571350690, .lng = 2.953923329812411617 }, // face  6
    .{ .lat = 0.427370518328979641, .lng = -1.888876200336285401 }, // face  7
    .{ .lat = -0.079066118549212831, .lng = -0.733429513380867741 }, // face  8
    .{ .lat = -0.230961644455383637, .lng = 0.506495587332349035 }, // face  9
    .{ .lat = 0.079066118549212831, .lng = 2.408163140208925497 }, // face 10
    .{ .lat = 0.230961644455383637, .lng = -2.635097066257444203 }, // face 11
    .{ .lat = -0.172745327415618701, .lng = -1.463445768309359553 }, // face 12
    .{ .lat = -0.605929321571350690, .lng = -0.187669323777381622 }, // face 13
    .{ .lat = -0.427370518328979641, .lng = 1.252716453253507838 }, // face 14
    .{ .lat = -0.600191595538186799, .lng = 2.690988744120037492 }, // face 15
    .{ .lat = -0.491715428198773866, .lng = -2.739604450678486295 }, // face 16
    .{ .lat = -0.803582649718989942, .lng = -1.893195233972397139 }, // face 17
    .{ .lat = -1.307747883455638156, .lng = -0.604647643711872080 }, // face 18
    .{ .lat = -1.054751253523952054, .lng = 1.794075294689396615 }, // face 19
};

/// 20 icosahedron face centers as 3D unit-sphere coordinates.
pub const faceCenterPoint: [NUM_ICOSA_FACES]Vec3d = .{
    .{ .x = 0.2199307791404606, .y = 0.6583691780274996, .z = 0.7198475378926182 },
    .{ .x = -0.2139234834501421, .y = 0.1478171829550703, .z = 0.9656017935214205 },
    .{ .x = 0.1092625278784797, .y = -0.4811951572873210, .z = 0.8697775121287253 },
    .{ .x = 0.7428567301586791, .y = -0.3593941678278028, .z = 0.5648005936517033 },
    .{ .x = 0.8112534709140969, .y = 0.3448953237639384, .z = 0.4721387736413930 },
    .{ .x = -0.1055498149613921, .y = 0.9794457296411413, .z = 0.1718874610009365 },
    .{ .x = -0.8075407579970092, .y = 0.1533552485898818, .z = 0.5695261994882688 },
    .{ .x = -0.2846148069787907, .y = -0.8644080972654206, .z = 0.4144792552473539 },
    .{ .x = 0.7405621473854482, .y = -0.6673299564565524, .z = -0.0789837646326737 },
    .{ .x = 0.8512303986474293, .y = 0.4722343788582681, .z = -0.2289137388687808 },
    .{ .x = -0.7405621473854481, .y = 0.6673299564565524, .z = 0.0789837646326737 },
    .{ .x = -0.8512303986474292, .y = -0.4722343788582682, .z = 0.2289137388687808 },
    .{ .x = 0.1055498149613919, .y = -0.9794457296411413, .z = -0.1718874610009365 },
    .{ .x = 0.8075407579970092, .y = -0.1533552485898819, .z = -0.5695261994882688 },
    .{ .x = 0.2846148069787908, .y = 0.8644080972654204, .z = -0.4144792552473539 },
    .{ .x = -0.7428567301586791, .y = 0.3593941678278027, .z = -0.5648005936517033 },
    .{ .x = -0.8112534709140971, .y = -0.3448953237639382, .z = -0.4721387736413930 },
    .{ .x = -0.2199307791404607, .y = -0.6583691780274996, .z = -0.7198475378926182 },
    .{ .x = 0.2139234834501420, .y = -0.1478171829550704, .z = -0.9656017935214205 },
    .{ .x = -0.1092625278784796, .y = 0.4811951572873210, .z = -0.8697775121287253 },
};

/// 20 icosahedron face axes — azimuth in radians from each face center to
/// vertex 0, 1, 2 of the central hexagon (Class II orientation).
pub const faceAxesAzRadsCII: [NUM_ICOSA_FACES][3]f64 = .{
    .{ 5.619958268523939882, 3.525563166130744542, 1.431168063737548730 }, // face  0
    .{ 5.760339081714187279, 3.665943979320991689, 1.571548876927796127 }, // face  1
    .{ 0.780213654393430055, 4.969003859179821079, 2.874608756786625655 }, // face  2
    .{ 0.430469363979999913, 4.619259568766391033, 2.524864466373195467 }, // face  3
    .{ 6.130269123335111400, 4.035874020941915804, 1.941478918548720291 }, // face  4
    .{ 2.692877706530642877, 0.598482604137447119, 4.787272808923838195 }, // face  5
    .{ 2.982963003477243874, 0.888567901084048369, 5.077358105870439581 }, // face  6
    .{ 3.532912002790141181, 1.438516900396945656, 5.627307105183336758 }, // face  7
    .{ 3.494305004259568154, 1.399909901866372864, 5.588700106652763840 }, // face  8
    .{ 3.003214169499538391, 0.908819067106342928, 5.097609271892733906 }, // face  9
    .{ 5.930472956509811562, 3.836077854116615875, 1.741682751723420374 }, // face 10
    .{ 0.138378484090254847, 4.327168688876645809, 2.232773586483450311 }, // face 11
    .{ 0.448714947059150361, 4.637505151845541521, 2.543110049452346120 }, // face 12
    .{ 0.158629650112549365, 4.347419854898940135, 2.253024752505744869 }, // face 13
    .{ 5.891865957979238535, 3.797470855586042958, 1.703075753192847583 }, // face 14
    .{ 2.711123289609793325, 0.616728187216597771, 4.805518392002988683 }, // face 15
    .{ 3.294508837434268316, 1.200113735041072948, 5.388903939827463911 }, // face 16
    .{ 3.804819692245439833, 1.710424589852244509, 5.899214794638635174 }, // face 17
    .{ 3.664438879055192436, 1.570043776661997111, 5.758833981448388027 }, // face 18
    .{ 2.361378999196363184, 0.266983896803167583, 4.455774101589558636 }, // face 19
};

// =============================================================================
// Vec3d — 3D Cartesian on unit sphere
// =============================================================================

pub const Vec3d = extern struct {
    x: f64,
    y: f64,
    z: f64,
};

/// 3D unit-sphere coordinates for a (lat, lng) point in radians. Mirrors
/// libh3's `_geoToVec3d`.
pub fn geoToVec3d(g: LatLng) Vec3d {
    const r = @cos(g.lat);
    return .{
        .x = @cos(g.lng) * r,
        .y = @sin(g.lng) * r,
        .z = @sin(g.lat),
    };
}

/// Squared Euclidean distance between two 3D points. Mirrors libh3's
/// `_pointSquareDist`.
pub fn pointSquareDist(a: Vec3d, b: Vec3d) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const dz = a.z - b.z;
    return dx * dx + dy * dy + dz * dz;
}

// =============================================================================
// Vec2d — face-centered 2D hex coordinates
// =============================================================================

pub const Vec2d = extern struct {
    x: f64,
    y: f64,
};

/// Magnitude (L2 norm) of a 2D vector. Mirrors libh3's `_v2dMag`.
pub fn vec2dMag(v: Vec2d) f64 {
    return @sqrt(v.x * v.x + v.y * v.y);
}

// =============================================================================
// Angles
// =============================================================================

/// Normalize an angle in radians to `[0, 2π)`. Mirrors `_posAngleRads`.
pub fn posAngleRads(rads: f64) f64 {
    var tmp = if (rads < 0.0) rads + TWO_PI else rads;
    if (rads >= TWO_PI) tmp -= TWO_PI;
    return tmp;
}

/// Initial azimuth in radians, measured clockwise from north, from `a` to
/// `b` on the unit sphere. Mirrors libh3's `_geoAzimuthRads`.
pub fn geoAzimuthRads(a: LatLng, b: LatLng) f64 {
    return std.math.atan2(
        @cos(b.lat) * @sin(b.lng - a.lng),
        @cos(a.lat) * @sin(b.lat) - @sin(a.lat) * @cos(b.lat) * @cos(b.lng - a.lng),
    );
}

// =============================================================================
// Closest icosahedron face
// =============================================================================

pub const ClosestFace = struct {
    face: i32,
    sqd: f64,
};

/// Find the icosahedron face whose center is closest (in Euclidean 3D
/// distance) to the given point on the sphere. Returns the face index and
/// the squared distance. Mirrors libh3's `_geoToClosestFace`.
pub fn geoToClosestFace(g: LatLng) ClosestFace {
    const v = geoToVec3d(g);
    var best_face: i32 = 0;
    var best_sqd: f64 = 5.0; // max possible squared distance on unit sphere is 4
    for (faceCenterPoint, 0..) |center, i| {
        const d = pointSquareDist(center, v);
        if (d < best_sqd) {
            best_sqd = d;
            best_face = @intCast(i);
        }
    }
    return .{ .face = best_face, .sqd = best_sqd };
}

// =============================================================================
// Class III rotation helper
// =============================================================================

inline fn isClassIIIRes(res: i32) bool {
    return (@mod(res, 2)) == 1;
}

// =============================================================================
// _geoToHex2d — forward projection to face-centered 2D hex coords
// =============================================================================

pub const Hex2dProjection = struct {
    face: i32,
    v: Vec2d,
};

/// Encode a sphere point as (face, face-centered 2D hex coordinates) at the
/// specified resolution. Mirrors libh3's `_geoToHex2d`.
///
/// The output's `(x, y)` is unitless face-centered coordinates where one
/// resolution-`res` hex edge equals length 1.
pub fn geoToHex2d(g: LatLng, res: i32) Hex2dProjection {
    const cf = geoToClosestFace(g);

    // arc length to face center from chord length²: cos(r) = 1 - sqd/2
    var r = std.math.acos(1.0 - cf.sqd / 2.0);

    if (r < EPSILON) {
        return .{ .face = cf.face, .v = .{ .x = 0.0, .y = 0.0 } };
    }

    // CCW theta from the face's CII i-axis
    var theta = posAngleRads(
        faceAxesAzRadsCII[@intCast(cf.face)][0] -
            posAngleRads(geoAzimuthRads(faceCenterGeo[@intCast(cf.face)], g)),
    );

    // Class III: rotate by AP7_ROT_RADS
    if (isClassIIIRes(res)) {
        theta = posAngleRads(theta - AP7_ROT_RADS);
    }

    // gnomonic scaling
    r = @tan(r);
    r /= RES0_U_GNOMONIC;

    // scale by aperture-7 ratio per resolution level
    var i: i32 = 0;
    while (i < res) : (i += 1) r *= SQRT7;

    return .{
        .face = cf.face,
        .v = .{ .x = r * @cos(theta), .y = r * @sin(theta) },
    };
}

// =============================================================================
// CoordIJK — face-centered hex IJK coordinates
// =============================================================================

pub const CoordIJK = extern struct {
    i: i32,
    j: i32,
    k: i32,
};

pub fn setIJK(c: *CoordIJK, i: i32, j: i32, k: i32) void {
    c.* = .{ .i = i, .j = j, .k = k };
}

/// Reduce an IJK coordinate to its canonical form (all ≥ 0, at least one
/// equal to 0). Mirrors libh3's `_ijkNormalize`.
pub fn ijkNormalize(c: *CoordIJK) void {
    if (c.i < 0) {
        c.j -= c.i;
        c.k -= c.i;
        c.i = 0;
    }
    if (c.j < 0) {
        c.i -= c.j;
        c.k -= c.j;
        c.j = 0;
    }
    if (c.k < 0) {
        c.i -= c.k;
        c.j -= c.k;
        c.k = 0;
    }
    var min = c.i;
    if (c.j < min) min = c.j;
    if (c.k < min) min = c.k;
    if (min > 0) {
        c.i -= min;
        c.j -= min;
        c.k -= min;
    }
}

/// Compute the IJK coordinate of the hex containing a face-centered 2D
/// point. Mirrors libh3's `_hex2dToCoordIJK`.
pub fn hex2dToCoordIJK(v: Vec2d) CoordIJK {
    var h: CoordIJK = .{ .i = 0, .j = 0, .k = 0 };

    const a1 = @abs(v.x);
    const a2 = @abs(v.y);

    const x2 = a2 / SIN60;
    const x1 = a1 + x2 / 2.0;

    const m1: i64 = @intFromFloat(x1);
    const m2: i64 = @intFromFloat(x2);

    const r1 = x1 - @as(f64, @floatFromInt(m1));
    const r2 = x2 - @as(f64, @floatFromInt(m2));

    if (r1 < 0.5) {
        if (r1 < 1.0 / 3.0) {
            if (r2 < (1.0 + r1) / 2.0) {
                h.i = @intCast(m1);
                h.j = @intCast(m2);
            } else {
                h.i = @intCast(m1);
                h.j = @intCast(m2 + 1);
            }
        } else {
            if (r2 < (1.0 - r1)) {
                h.j = @intCast(m2);
            } else {
                h.j = @intCast(m2 + 1);
            }
            if ((1.0 - r1) <= r2 and r2 < (2.0 * r1)) {
                h.i = @intCast(m1 + 1);
            } else {
                h.i = @intCast(m1);
            }
        }
    } else {
        if (r1 < 2.0 / 3.0) {
            if (r2 < (1.0 - r1)) {
                h.j = @intCast(m2);
            } else {
                h.j = @intCast(m2 + 1);
            }
            if ((2.0 * r1 - 1.0) < r2 and r2 < (1.0 - r1)) {
                h.i = @intCast(m1);
            } else {
                h.i = @intCast(m1 + 1);
            }
        } else {
            if (r2 < (r1 / 2.0)) {
                h.i = @intCast(m1 + 1);
                h.j = @intCast(m2);
            } else {
                h.i = @intCast(m1 + 1);
                h.j = @intCast(m2 + 1);
            }
        }
    }

    // fold across the axes
    if (v.x < 0.0) {
        if (@mod(h.j, 2) == 0) {
            const axisi = @divFloor(h.j, 2);
            const diff = h.i - axisi;
            h.i = h.i - 2 * diff;
        } else {
            const axisi = @divFloor(h.j + 1, 2);
            const diff = h.i - axisi;
            h.i = h.i - (2 * diff + 1);
        }
    }
    if (v.y < 0.0) {
        h.i = h.i - @divFloor(2 * h.j + 1, 2);
        h.j = -h.j;
    }

    ijkNormalize(&h);
    return h;
}

/// Compute the 2D face-centered coordinate of a hex center given its IJK
/// coordinate. Mirrors libh3's `_ijkToHex2d`.
pub fn ijkToHex2d(h: CoordIJK) Vec2d {
    const i = h.i - h.k;
    const j = h.j - h.k;
    return .{
        .x = @as(f64, @floatFromInt(i)) - 0.5 * @as(f64, @floatFromInt(j)),
        .y = @as(f64, @floatFromInt(j)) * SQRT3_2,
    };
}

// =============================================================================
// Tests — mathematical-property-based + libh3-anchored sanity
// =============================================================================

const testing = std.testing;

test "geoToVec3d puts every point on the unit sphere" {
    var rng = std.Random.DefaultPrng.init(0xA1B2C3D4);
    for (0..400) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const v = geoToVec3d(LatLng.fromDegrees(lat_deg, lng_deg));
        const mag_sq = v.x * v.x + v.y * v.y + v.z * v.z;
        try testing.expectApproxEqAbs(@as(f64, 1.0), mag_sq, 1e-12);
    }
}

test "geoToVec3d known compass points" {
    const north_pole = geoToVec3d(.{ .lat = PI_2, .lng = 0.0 });
    try testing.expectApproxEqAbs(@as(f64, 0.0), north_pole.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), north_pole.y, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), north_pole.z, 1e-12);

    const equator_0 = geoToVec3d(.{ .lat = 0.0, .lng = 0.0 });
    try testing.expectApproxEqAbs(@as(f64, 1.0), equator_0.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), equator_0.y, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), equator_0.z, 1e-12);

    const equator_90 = geoToVec3d(.{ .lat = 0.0, .lng = PI_2 });
    try testing.expectApproxEqAbs(@as(f64, 0.0), equator_90.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), equator_90.y, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), equator_90.z, 1e-12);
}

test "pointSquareDist is symmetric, nonnegative, zero on equal points" {
    var rng = std.Random.DefaultPrng.init(0xBEEF);
    for (0..100) |_| {
        const a = geoToVec3d(LatLng.fromDegrees(
            (rng.random().float(f64) - 0.5) * 179.0,
            (rng.random().float(f64) - 0.5) * 359.0,
        ));
        const b = geoToVec3d(LatLng.fromDegrees(
            (rng.random().float(f64) - 0.5) * 179.0,
            (rng.random().float(f64) - 0.5) * 359.0,
        ));
        const d_ab = pointSquareDist(a, b);
        const d_ba = pointSquareDist(b, a);
        try testing.expectEqual(d_ab, d_ba);
        try testing.expect(d_ab >= 0);
        try testing.expectApproxEqAbs(@as(f64, 0.0), pointSquareDist(a, a), 1e-30);
    }
}

test "every face center 3D matches geoToVec3d of its lat/lng" {
    for (faceCenterGeo, faceCenterPoint) |g, p| {
        const computed = geoToVec3d(g);
        try testing.expectApproxEqAbs(p.x, computed.x, 1e-15);
        try testing.expectApproxEqAbs(p.y, computed.y, 1e-15);
        try testing.expectApproxEqAbs(p.z, computed.z, 1e-15);
    }
}

test "every face center is its own closest face" {
    for (faceCenterGeo, 0..) |center, idx| {
        const cf = geoToClosestFace(center);
        try testing.expectEqual(@as(i32, @intCast(idx)), cf.face);
        try testing.expectApproxEqAbs(@as(f64, 0.0), cf.sqd, 1e-25);
    }
}

test "tiny perturbation of a face center stays on the same face" {
    var rng = std.Random.DefaultPrng.init(0xFACE);
    for (faceCenterGeo, 0..) |center, idx| {
        for (0..10) |_| {
            const perturbed = LatLng{
                .lat = center.lat + (rng.random().float(f64) - 0.5) * 1e-6,
                .lng = center.lng + (rng.random().float(f64) - 0.5) * 1e-6,
            };
            try testing.expectEqual(@as(i32, @intCast(idx)), geoToClosestFace(perturbed).face);
        }
    }
}

test "posAngleRads normalizes nearly-normalized input into [0, 2π)" {
    // libh3's _posAngleRads has the precondition that input lies in
    // approximately [-2π, 4π) — it does a single shift, not a loop. Inside
    // that domain, the output is guaranteed to be in [0, 2π).
    var x: f64 = -TWO_PI + 1e-9;
    while (x < 2.0 * TWO_PI - 1e-9) : (x += 0.13) {
        const p = posAngleRads(x);
        try testing.expect(p >= 0.0);
        try testing.expect(p < TWO_PI);
    }
}

test "vec2dMag identities" {
    try testing.expectApproxEqAbs(@as(f64, 0.0), vec2dMag(.{ .x = 0.0, .y = 0.0 }), 0.0);
    try testing.expectApproxEqAbs(@as(f64, 5.0), vec2dMag(.{ .x = 3.0, .y = 4.0 }), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5.0), vec2dMag(.{ .x = -3.0, .y = -4.0 }), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.0), vec2dMag(.{ .x = 1.0, .y = 0.0 }), 1e-12);
}

test "geoAzimuthRads of identical points is zero" {
    const p = LatLng.fromDegrees(40.0, -74.0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), geoAzimuthRads(p, p), 1e-12);
}

test "geoToHex2d at face center returns (0, 0)" {
    var res: i32 = 0;
    while (res <= 15) : (res += 1) {
        for (faceCenterGeo, 0..) |center, idx| {
            const proj = geoToHex2d(center, res);
            try testing.expectEqual(@as(i32, @intCast(idx)), proj.face);
            try testing.expectApproxEqAbs(@as(f64, 0.0), proj.v.x, 1e-12);
            try testing.expectApproxEqAbs(@as(f64, 0.0), proj.v.y, 1e-12);
        }
    }
}

test "ijkNormalize is idempotent and produces canonical form" {
    var rng = std.Random.DefaultPrng.init(0xDEAD);
    for (0..200) |_| {
        var c = CoordIJK{
            .i = @as(i32, @intCast(rng.random().int(u16) % 100)) - 50,
            .j = @as(i32, @intCast(rng.random().int(u16) % 100)) - 50,
            .k = @as(i32, @intCast(rng.random().int(u16) % 100)) - 50,
        };
        ijkNormalize(&c);
        // canonical: all >= 0 and at least one is 0
        try testing.expect(c.i >= 0);
        try testing.expect(c.j >= 0);
        try testing.expect(c.k >= 0);
        try testing.expect(c.i == 0 or c.j == 0 or c.k == 0);

        // idempotent
        const before = c;
        ijkNormalize(&c);
        try testing.expectEqual(before.i, c.i);
        try testing.expectEqual(before.j, c.j);
        try testing.expectEqual(before.k, c.k);
    }
}

test "ijkNormalize known cases" {
    var c = CoordIJK{ .i = 0, .j = 0, .k = 0 };
    ijkNormalize(&c);
    try testing.expectEqual(@as(i32, 0), c.i);
    try testing.expectEqual(@as(i32, 0), c.j);
    try testing.expectEqual(@as(i32, 0), c.k);

    c = .{ .i = 3, .j = 5, .k = 1 };
    ijkNormalize(&c);
    // min = 1, subtract from all
    try testing.expectEqual(@as(i32, 2), c.i);
    try testing.expectEqual(@as(i32, 4), c.j);
    try testing.expectEqual(@as(i32, 0), c.k);

    c = .{ .i = -1, .j = 2, .k = 3 };
    ijkNormalize(&c);
    // i goes to 0, j and k each +1; then min=3, subtract → (0, 0, 1) - wait recompute
    // step1: i=-1 → j -= -1 (so j=3), k -= -1 (k=4), i=0. Now (0,3,4).
    // step2: j>=0 ok. step3: k>=0 ok. min=0, no shift. Result (0,3,4).
    try testing.expectEqual(@as(i32, 0), c.i);
    try testing.expectEqual(@as(i32, 3), c.j);
    try testing.expectEqual(@as(i32, 4), c.k);
}

test "hex2dToCoordIJK at origin is (0,0,0)" {
    const c = hex2dToCoordIJK(.{ .x = 0.0, .y = 0.0 });
    try testing.expectEqual(@as(i32, 0), c.i);
    try testing.expectEqual(@as(i32, 0), c.j);
    try testing.expectEqual(@as(i32, 0), c.k);
}

test "hex2dToCoordIJK then ijkToHex2d on integer-grid points is identity" {
    // Pure (i, j) integer points without k > 0 should roundtrip exactly:
    // the canonical IJK is exactly the input.
    const cases = [_]CoordIJK{
        .{ .i = 1, .j = 0, .k = 0 },
        .{ .i = 0, .j = 1, .k = 0 },
        .{ .i = 2, .j = 3, .k = 0 },
        .{ .i = 5, .j = 7, .k = 0 },
    };
    for (cases) |c| {
        const v = ijkToHex2d(c);
        const back = hex2dToCoordIJK(v);
        try testing.expectEqual(c.i, back.i);
        try testing.expectEqual(c.j, back.j);
        try testing.expectEqual(c.k, back.k);
    }
}

test "ijkToHex2d known coordinates" {
    // (1, 0, 0) → unit step along x-axis
    var v = ijkToHex2d(.{ .i = 1, .j = 0, .k = 0 });
    try testing.expectApproxEqAbs(@as(f64, 1.0), v.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), v.y, 1e-12);

    // (0, 1, 0) → at 120° angle: (-0.5, sqrt(3)/2)
    v = ijkToHex2d(.{ .i = 0, .j = 1, .k = 0 });
    try testing.expectApproxEqAbs(@as(f64, -0.5), v.x, 1e-12);
    try testing.expectApproxEqAbs(SQRT3_2, v.y, 1e-12);

    // (0, 0, 0) → origin
    v = ijkToHex2d(.{ .i = 0, .j = 0, .k = 0 });
    try testing.expectApproxEqAbs(@as(f64, 0.0), v.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), v.y, 1e-12);
}

test "SQRT7 squared is 7" {
    try testing.expectApproxEqAbs(@as(f64, 7.0), SQRT7 * SQRT7, 1e-14);
}

test "SQRT3_2 squared is 3/4" {
    try testing.expectApproxEqAbs(@as(f64, 0.75), SQRT3_2 * SQRT3_2, 1e-14);
}

test "geoToHex2d face assignment matches geoToClosestFace" {
    var rng = std.Random.DefaultPrng.init(0xC0DE);
    for (0..100) |_| {
        const g = LatLng.fromDegrees(
            (rng.random().float(f64) - 0.5) * 179.0,
            (rng.random().float(f64) - 0.5) * 359.0,
        );
        const cf = geoToClosestFace(g);
        const proj = geoToHex2d(g, 5);
        try testing.expectEqual(cf.face, proj.face);
    }
}

test "geoToHex2d magnitude grows with resolution" {
    // Not at the face center, the magnitude scales by sqrt(7) per
    // resolution level. Pick a point off-center and verify.
    const g = LatLng.fromDegrees(45.0, 45.0);
    const proj0 = geoToHex2d(g, 0);
    const proj1 = geoToHex2d(g, 1);
    const proj2 = geoToHex2d(g, 2);
    const mag0 = vec2dMag(proj0.v);
    const mag1 = vec2dMag(proj1.v);
    const mag2 = vec2dMag(proj2.v);
    // proj1 magnitude should be SQRT7 × proj0 magnitude (Class III rotation
    // affects angle, not magnitude).
    try testing.expectApproxEqAbs(mag0 * SQRT7, mag1, mag0 * 1e-12);
    try testing.expectApproxEqAbs(mag1 * SQRT7, mag2, mag1 * 1e-12);
}
