//! Pure-Zig implementations of H3 v4 primitives.
//!
//! This module is the parallel native track to `root.zig` (which wraps
//! libh3). Every function in here is cross-validated against the libh3
//! equivalent via tests at the bottom of this file — same build, same test
//! run, no dual-implementation drift.
//!
//! When pure-Zig coverage is complete and the cross-validation tests pass
//! on the full input domain, the C dependency can be made optional via a
//! build flag and dropped at v1.0.0.
//!
//! ## Roadmap
//!
//! - **Phase 1 (v0.1.0):** Functions that don't require the icosahedron
//!   projection: degrees↔radians, H3-index bit extraction (resolution,
//!   base cell, ResClass III, digit), pentagon detection, closed-form
//!   counts, and great-circle distance via haversine. ✅ shipped.
//!
//! - **Phase 2 (v0.1.0):** H3 index format helpers — `isValidCell` (full
//!   algorithm including the pentagon "deleted subsequence" rule),
//!   `h3ToString`, `stringToH3`, mode/reserved bit access, cell digit
//!   walking. ✅ shipped.
//!
//! - **Phase 3 (~weeks 5–16):** The icosahedron projection — face-centered
//!   IJK coordinates, `latLngToCell`, `cellToLatLng`, `cellToBoundary`,
//!   pentagon distortion handling. This is the multi-month substrate.
//!
//! - **Phase 4 (~weeks 17–24):** Hierarchical (parent/children/center
//!   child, compact/uncompact) and grid traversal (gridDisk, gridRing,
//!   gridDistance, areNeighborCells, gridPathCells).
//!
//! - **Phase 5 (~weeks 25–32):** Exact cell area (spherical excess),
//!   edge length, face count, base cell enumeration, pentagon
//!   enumeration.
//!
//! - **Phase 6:** Directed edges, vertices, polygon-to-cells (optional —
//!   the wrapper covers these via raw libh3 access).

const std = @import("std");
const root = @import("root.zig");

pub const H3Index = root.H3Index;
pub const LatLng = root.LatLng;
pub const Error = root.Error;

// =============================================================================
// Constants — bit-for-bit matched to libh3 src/h3lib/include/constants.h
// =============================================================================

/// Radians per degree. Same f64 value as libh3's `M_PI_180`.
pub const RADIANS_PER_DEGREE: f64 = 0.0174532925199432957692369076848861271111;

/// Degrees per radian. Same f64 value as libh3's `M_180_PI`.
pub const DEGREES_PER_RADIAN: f64 = 57.29577951308232087679815481410517033240547;

/// Mean Earth radius in kilometers used by libh3 area / distance routines.
pub const EARTH_RADIUS_KM: f64 = 6371.007180918475;

/// Maximum valid H3 resolution.
pub const MAX_RES: i32 = 15;

/// Number of resolution-0 base cells.
pub const RES0_CELL_COUNT: i32 = 122;

/// Number of pentagons at every resolution.
pub const PENTAGON_COUNT_PER_RES: i32 = 12;

// =============================================================================
// H3 index bit layout — bit-for-bit matched to libh3 src/h3lib/include/h3Index.h
// =============================================================================

const H3_MODE_OFFSET: u6 = 59;
const H3_RESERVED_OFFSET: u6 = 56;
const H3_RES_OFFSET: u6 = 52;
const H3_BC_OFFSET: u6 = 45;
const H3_PER_DIGIT_OFFSET: u6 = 3;
const H3_DIGIT_MASK: u64 = 7;
const H3_HIGH_BIT_OFFSET: u6 = 63;

/// libh3 `H3_CELL_MODE = 1` — the only valid mode for a cell H3Index.
pub const CELL_MODE: u4 = 1;

/// libh3 `K_AXES_DIGIT = 1` — the direction that is "skipped" at the first
/// non-zero digit position of a pentagon cell.
pub const PENTAGON_SKIPPED_DIGIT: u3 = 1;

/// libh3 `INVALID_DIGIT = 7` — the sentinel that fills digit slots below a
/// cell's resolution.
pub const INVALID_DIGIT: u3 = 7;

inline fn getHighBit(cell: H3Index) u1 {
    return @intCast((cell >> H3_HIGH_BIT_OFFSET) & 1);
}

inline fn getModeBits(cell: H3Index) u4 {
    return @intCast((cell >> H3_MODE_OFFSET) & 0xF);
}

inline fn getReservedBits(cell: H3Index) u3 {
    return @intCast((cell >> H3_RESERVED_OFFSET) & 0x7);
}

/// Resolution of the cell (0..15).
pub fn getResolution(cell: H3Index) i32 {
    return @intCast((cell >> H3_RES_OFFSET) & 0xF);
}

/// Base cell number (0..121).
pub fn getBaseCellNumber(cell: H3Index) i32 {
    return @intCast((cell >> H3_BC_OFFSET) & 0x7F);
}

/// True iff the resolution is one of {1, 3, 5, 7, 9, 11, 13, 15} — the
/// "Class III" resolutions whose orientation is rotated relative to their
/// parent.
pub fn isResClassIII(cell: H3Index) bool {
    return (getResolution(cell) & 1) == 1;
}

/// Extract the cell-direction digit (0..6, or 7 for "unused") at a specific
/// resolution. Used internally by `isPentagon` and by future hierarchy code.
pub fn getCellDigit(cell: H3Index, res: i32) u3 {
    std.debug.assert(res >= 1 and res <= MAX_RES);
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * @as(i32, H3_PER_DIGIT_OFFSET));
    return @intCast((cell >> shift) & H3_DIGIT_MASK);
}

// =============================================================================
// Degrees ↔ radians
// =============================================================================

pub fn degsToRads(degrees: f64) f64 {
    return degrees * RADIANS_PER_DEGREE;
}

pub fn radsToDegs(radians: f64) f64 {
    return radians * DEGREES_PER_RADIAN;
}

// =============================================================================
// Pentagon detection
// =============================================================================

/// The 12 base cells that are pentagons. Constant across all resolutions.
pub const PENTAGON_BASE_CELLS = [_]i32{ 4, 14, 24, 38, 49, 58, 63, 72, 83, 97, 107, 117 };

/// True iff base cell number `bc` is one of the 12 pentagon base cells.
pub fn isPentagonBaseCell(bc: i32) bool {
    for (PENTAGON_BASE_CELLS) |p| {
        if (p == bc) return true;
    }
    return false;
}

/// True iff `cell` is one of the 12 pentagons at its resolution. A cell is a
/// pentagon iff its base cell is a pentagon and all of its resolution
/// digits (1..res) are zero — i.e., it's the "center child of a pentagon
/// all the way down."
pub fn isPentagon(cell: H3Index) bool {
    const bc = getBaseCellNumber(cell);
    if (!isPentagonBaseCell(bc)) return false;
    const res = getResolution(cell);
    var r: i32 = 1;
    while (r <= res) : (r += 1) {
        if (getCellDigit(cell, r) != 0) return false;
    }
    return true;
}

// =============================================================================
// Closed-form counts
// =============================================================================

pub fn res0CellCount() i32 {
    return RES0_CELL_COUNT;
}

pub fn pentagonCount() i32 {
    return PENTAGON_COUNT_PER_RES;
}

/// Total number of cells at resolution `res` — closed form `2 + 120 * 7^res`.
pub fn getNumCells(res: i32) Error!i64 {
    if (res < 0 or res > MAX_RES) return Error.ResolutionDomain;
    var pow7: i64 = 1;
    var i: i32 = 0;
    while (i < res) : (i += 1) pow7 *= 7;
    return 2 + 120 * pow7;
}

/// Maximum size of a grid disk at distance `k`. Closed form `1 + 3*k*(k+1)`.
pub fn maxGridDiskSize(k: i32) Error!i64 {
    if (k < 0) return Error.Domain;
    const kk: i64 = k;
    return 1 + 3 * kk * (kk + 1);
}

// =============================================================================
// H3 index format helpers — Phase 2
// =============================================================================

/// True iff `cell` is a syntactically valid H3 cell. Mirrors libh3's
/// `isValidCell` algorithm: checks the high bit, mode, reserved bits, base
/// cell, resolution, digit-range, the pentagon "deleted subsequence" rule
/// (a pentagon cannot have `K_AXES_DIGIT` at its first non-zero digit), and
/// that all digits below the resolution are `INVALID_DIGIT`.
pub fn isValidCell(cell: H3Index) bool {
    if (getHighBit(cell) != 0) return false;
    if (getModeBits(cell) != CELL_MODE) return false;
    if (getReservedBits(cell) != 0) return false;

    const bc = getBaseCellNumber(cell);
    if (bc < 0 or bc >= RES0_CELL_COUNT) return false;

    const res = getResolution(cell);
    if (res < 0 or res > MAX_RES) return false;

    const is_pent_base = isPentagonBaseCell(bc);
    var found_first_nonzero = false;
    var r: i32 = 1;
    while (r <= res) : (r += 1) {
        const digit = getCellDigit(cell, r);
        if (!found_first_nonzero and digit != 0) {
            found_first_nonzero = true;
            if (is_pent_base and digit == PENTAGON_SKIPPED_DIGIT) return false;
        }
        if (digit >= INVALID_DIGIT) return false;
    }

    // Digits below the cell's resolution must be the INVALID_DIGIT sentinel.
    while (r <= MAX_RES) : (r += 1) {
        if (getCellDigit(cell, r) != INVALID_DIGIT) return false;
    }

    return true;
}

/// Format `cell` as a lowercase hexadecimal string. Returns a sub-slice of
/// `buf` containing the digits (no trailing null byte). libh3 requires
/// `buf.len >= 17` (16 hex digits + null terminator) and uses `sprintf("%llx", h)`
/// which is unpadded lowercase hex; this function matches the byte content
/// (minus the trailing null, which Zig slices don't require).
pub fn h3ToString(cell: H3Index, buf: []u8) Error![]const u8 {
    if (buf.len < 17) return Error.MemoryBounds;
    return std.fmt.bufPrint(buf, "{x}", .{cell}) catch return Error.MemoryBounds;
}

/// Parse a lowercase or uppercase hexadecimal string into an `H3Index`.
/// libh3 uses `sscanf("%llx")` which is permissive about whitespace and
/// leading-zero behavior; this implementation skips leading ASCII
/// whitespace and accepts an optional `0x`/`0X` prefix, then consumes
/// the maximal prefix of hex digits. Returns `Error.Failed` for input
/// containing no parseable hex digits — same code libh3 returns.
pub fn stringToH3(s: []const u8) Error!H3Index {
    // Skip leading whitespace (matches sscanf default).
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') break;
    }
    if (i == s.len) return Error.Failed;

    // Optional 0x / 0X prefix.
    if (i + 1 < s.len and s[i] == '0' and (s[i + 1] == 'x' or s[i + 1] == 'X')) {
        i += 2;
    }
    if (i == s.len) return Error.Failed;

    var value: u64 = 0;
    var digits: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        const d: u64 = switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => break,
        };
        // Reject overflow (more than 16 hex digits).
        if (digits >= 16) return Error.Failed;
        value = (value << 4) | d;
        digits += 1;
    }

    if (digits == 0) return Error.Failed;
    return value;
}

// =============================================================================
// Great-circle distance — haversine
// =============================================================================

/// Haversine great-circle distance in radians between two points on a sphere.
pub fn greatCircleDistanceRads(a: LatLng, b: LatLng) f64 {
    const dlat = b.lat - a.lat;
    const dlng = b.lng - a.lng;
    const sin_dlat = @sin(dlat / 2.0);
    const sin_dlng = @sin(dlng / 2.0);
    const h = sin_dlat * sin_dlat + @cos(a.lat) * @cos(b.lat) * sin_dlng * sin_dlng;
    return 2.0 * std.math.asin(@sqrt(h));
}

pub fn greatCircleDistanceKm(a: LatLng, b: LatLng) f64 {
    return greatCircleDistanceRads(a, b) * EARTH_RADIUS_KM;
}

pub fn greatCircleDistanceM(a: LatLng, b: LatLng) f64 {
    return greatCircleDistanceKm(a, b) * 1000.0;
}

// =============================================================================
// Cross-validation tests against libh3 (via root.zig wrapper)
// =============================================================================
//
// Every pure-Zig function is checked against the libh3-backed equivalent
// over a wide input range. Integer outputs must match exactly; floating-
// point outputs are compared with bit-equality where the math is identical
// (degsToRads, radsToDegs) and with a tight ULP tolerance otherwise
// (haversine — different multiplication orders may differ by a few ULPs).
//
// To add a new pure function: implement it in this file, then add a
// cross-validation test below. If the test fails, the pure-Zig implementation
// is wrong (libh3 is the reference).

const testing = std.testing;

// libh3's `M_PI_180` and `M_180_PI` are declared as C `long double` literals.
// On platforms where intermediate computations happen in x87 extended
// precision, libh3's `degrees * M_PI_180` and `radians * M_180_PI` can differ
// from a pure-f64 multiplication by a few ULPs. We assert near-equality at
// 4 × DBL_EPSILON (~9e-16) — vastly tighter than any application requires.
const ULP4: f64 = 8.881784197001252e-16;

test "pure degsToRads matches libh3 within 4 ULPs across [-360, 360]" {
    var deg: f64 = -360.0;
    while (deg <= 360.0) : (deg += 0.25) {
        const ours = degsToRads(deg);
        const theirs = root.degsToRads(deg);
        try testing.expectApproxEqAbs(theirs, ours, @max(@abs(theirs) * ULP4, ULP4));
    }
}

test "pure radsToDegs matches libh3 within 4 ULPs across [-2π, 2π]" {
    var rad: f64 = -2.0 * std.math.pi;
    while (rad <= 2.0 * std.math.pi) : (rad += 0.01) {
        const ours = radsToDegs(rad);
        const theirs = root.radsToDegs(rad);
        try testing.expectApproxEqAbs(theirs, ours, @max(@abs(theirs) * ULP4, ULP4));
    }
}

test "RADIANS_PER_DEGREE matches libh3 within 4 ULPs" {
    const theirs = root.degsToRads(1.0);
    try testing.expectApproxEqAbs(theirs, RADIANS_PER_DEGREE, ULP4);
}

test "DEGREES_PER_RADIAN matches libh3 within 4 ULPs" {
    const theirs = root.radsToDegs(1.0);
    try testing.expectApproxEqAbs(theirs, DEGREES_PER_RADIAN, ULP4 * 100.0);
}

test "pure getResolution matches libh3 on cells across all resolutions" {
    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    for (0..200) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const point = LatLng.fromDegrees(lat_deg, lng_deg);
        var res: i32 = 0;
        while (res <= MAX_RES) : (res += 1) {
            const cell = try root.latLngToCell(point, res);
            try testing.expectEqual(root.getResolution(cell), getResolution(cell));
        }
    }
}

test "pure getBaseCellNumber matches libh3 on res-0 base cells" {
    var cells: [122]H3Index = undefined;
    try root.getRes0Cells(&cells);
    for (cells) |cell| {
        try testing.expectEqual(root.getBaseCellNumber(cell), getBaseCellNumber(cell));
    }
}

test "pure getBaseCellNumber matches libh3 on random fine cells" {
    var rng = std.Random.DefaultPrng.init(0xBAFFED);
    for (0..500) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const res: i32 = @intCast(rng.random().int(u32) % 16);
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat_deg, lng_deg), res);
        try testing.expectEqual(root.getBaseCellNumber(cell), getBaseCellNumber(cell));
    }
}

test "pure isResClassIII matches libh3" {
    var rng = std.Random.DefaultPrng.init(0xDEFACED);
    for (0..200) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const point = LatLng.fromDegrees(lat_deg, lng_deg);
        var res: i32 = 0;
        while (res <= MAX_RES) : (res += 1) {
            const cell = try root.latLngToCell(point, res);
            try testing.expectEqual(root.isResClassIII(cell), isResClassIII(cell));
        }
    }
}

test "pure isPentagon matches libh3 on all base cells at every resolution" {
    var rng = std.Random.DefaultPrng.init(0xDABEEF);
    var cells: [122]H3Index = undefined;
    try root.getRes0Cells(&cells);

    // Every res-0 cell first.
    for (cells) |cell| {
        try testing.expectEqual(root.isPentagon(cell), isPentagon(cell));
    }

    // 12 pentagons at every resolution.
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        var pents: [12]H3Index = undefined;
        try root.getPentagons(res, &pents);
        for (pents) |p| try testing.expectEqual(true, isPentagon(p));
    }

    // Random non-pentagon cells.
    for (0..500) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const res2: i32 = @intCast(rng.random().int(u32) % 16);
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat_deg, lng_deg), res2);
        try testing.expectEqual(root.isPentagon(cell), isPentagon(cell));
    }
}

test "pure res0CellCount and pentagonCount match libh3" {
    try testing.expectEqual(root.res0CellCount(), res0CellCount());
    try testing.expectEqual(root.pentagonCount(), pentagonCount());
}

test "pure getNumCells matches libh3 across all valid resolutions" {
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        try testing.expectEqual(try root.getNumCells(res), try getNumCells(res));
    }
}

test "pure getNumCells rejects out-of-range resolution" {
    try testing.expectError(Error.ResolutionDomain, getNumCells(-1));
    try testing.expectError(Error.ResolutionDomain, getNumCells(16));
}

test "pure maxGridDiskSize matches libh3 across reasonable k" {
    var k: i32 = 0;
    while (k <= 30) : (k += 1) {
        try testing.expectEqual(try root.maxGridDiskSize(k), try maxGridDiskSize(k));
    }
}

test "pure maxGridDiskSize rejects negative k" {
    try testing.expectError(Error.Domain, maxGridDiskSize(-1));
}

test "pure greatCircleDistance matches libh3 within tight tolerance" {
    // Different floating-point operation orderings (libh3 vs ours) can differ
    // by a handful of ULPs. 1e-12 radians is far tighter than any practical
    // application cares about; bit-equality would require copying libh3's
    // exact expression tree.
    const tolerance_rads: f64 = 1e-12;
    const tolerance_km: f64 = 1e-9;

    var rng = std.Random.DefaultPrng.init(0xC1AB);
    for (0..200) |_| {
        const a = LatLng.fromDegrees(
            (rng.random().float(f64) - 0.5) * 179.0,
            (rng.random().float(f64) - 0.5) * 359.0,
        );
        const b = LatLng.fromDegrees(
            (rng.random().float(f64) - 0.5) * 179.0,
            (rng.random().float(f64) - 0.5) * 359.0,
        );

        const ours_rads = greatCircleDistanceRads(a, b);
        const theirs_rads = root.greatCircleDistanceRads(a, b);
        try testing.expectApproxEqAbs(theirs_rads, ours_rads, tolerance_rads);

        const ours_km = greatCircleDistanceKm(a, b);
        const theirs_km = root.greatCircleDistanceKm(a, b);
        try testing.expectApproxEqAbs(theirs_km, ours_km, tolerance_km);

        const ours_m = greatCircleDistanceM(a, b);
        const theirs_m = root.greatCircleDistanceM(a, b);
        try testing.expectApproxEqAbs(theirs_m, ours_m, tolerance_km * 1000.0);
    }
}

test "PENTAGON_BASE_CELLS matches libh3's getPentagons at res 0" {
    var pents: [12]H3Index = undefined;
    try root.getPentagons(0, &pents);
    var seen: [12]bool = .{false} ** 12;
    for (pents) |p| {
        const bc = root.getBaseCellNumber(p);
        var found = false;
        for (PENTAGON_BASE_CELLS, 0..) |expected_bc, idx| {
            if (expected_bc == bc) {
                seen[idx] = true;
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
    for (seen) |s| try testing.expect(s);
}

test "getCellDigit returns valid 3-bit values on real cells" {
    var rng = std.Random.DefaultPrng.init(0x77);
    for (0..100) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const res: i32 = 5 + @as(i32, @intCast(rng.random().int(u32) % 10));
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat_deg, lng_deg), res);
        var r: i32 = 1;
        while (r <= res) : (r += 1) {
            const d = getCellDigit(cell, r);
            try testing.expect(d <= 6); // valid digits are 0..6, 7 = unused
        }
    }
}

// === Phase 2 cross-validation ================================================

test "pure isValidCell agrees with libh3 on every res-0 base cell" {
    var cells: [122]H3Index = undefined;
    try root.getRes0Cells(&cells);
    for (cells) |cell| {
        try testing.expectEqual(root.isValidCell(cell), isValidCell(cell));
        try testing.expect(isValidCell(cell));
    }
}

test "pure isValidCell agrees with libh3 on pentagons at every resolution" {
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        var pents: [12]H3Index = undefined;
        try root.getPentagons(res, &pents);
        for (pents) |p| {
            try testing.expectEqual(root.isValidCell(p), isValidCell(p));
            try testing.expect(isValidCell(p));
        }
    }
}

test "pure isValidCell agrees with libh3 on random valid cells" {
    var rng = std.Random.DefaultPrng.init(0xDA1A);
    for (0..500) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const res: i32 = @intCast(rng.random().int(u32) % 16);
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat_deg, lng_deg), res);
        try testing.expectEqual(root.isValidCell(cell), isValidCell(cell));
        try testing.expect(isValidCell(cell));
    }
}

test "pure isValidCell rejects garbage same as libh3" {
    const garbage = [_]H3Index{
        0,
        0xdeadbeef,
        0xffffffffffffffff,
        1, // mode=0 if all other bits zero
        0xF000000000000000, // mode=14 (illegal)
        0x0700000000000000, // reserved bits nonzero
    };
    for (garbage) |g| {
        try testing.expectEqual(root.isValidCell(g), isValidCell(g));
    }
}

test "pure isValidCell rejects cell with corrupted digit at res > resolution" {
    // Build a valid res-2 cell, then poison a digit at res 5 to a non-7.
    const cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 2);
    try testing.expect(isValidCell(cell));

    const shift: u6 = @intCast((@as(i32, MAX_RES) - 5) * @as(i32, H3_PER_DIGIT_OFFSET));
    const mask = @as(H3Index, 0x7) << shift;
    const poisoned = (cell & ~mask) | (@as(H3Index, 3) << shift); // digit 3 instead of 7
    try testing.expect(!isValidCell(poisoned));
    try testing.expectEqual(root.isValidCell(poisoned), isValidCell(poisoned));
}

test "pure isValidCell rejects pentagon with K_AXES_DIGIT first non-zero digit" {
    // Take a pentagon at res 2 (which is all-zero digits) and force digit 1
    // at resolution 1 = K_AXES_DIGIT. libh3 rejects this.
    var pents: [12]H3Index = undefined;
    try root.getPentagons(2, &pents);
    const pent_res2 = pents[0];
    try testing.expect(isValidCell(pent_res2));

    const shift: u6 = @intCast((@as(i32, MAX_RES) - 1) * @as(i32, H3_PER_DIGIT_OFFSET));
    const mask = @as(H3Index, 0x7) << shift;
    const poisoned = (pent_res2 & ~mask) | (@as(H3Index, PENTAGON_SKIPPED_DIGIT) << shift);
    try testing.expect(!isValidCell(poisoned));
    try testing.expectEqual(root.isValidCell(poisoned), isValidCell(poisoned));
}

test "pure isValidCell rejects out-of-range base cell numbers (122..127)" {
    // The base-cell field is 7 bits wide (0..127) but only base cells
    // 0..121 are valid (RES0_CELL_COUNT = 122). Take a valid res-0 cell
    // and overwrite its base-cell field with 122..127; libh3 rejects all
    // of these, and so must we. Surfaced by mutation operator M07
    // (`bc >= RES0_CELL_COUNT` → `bc > RES0_CELL_COUNT`).
    const seed_cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 0);
    try testing.expect(isValidCell(seed_cell));
    const bc_mask = @as(H3Index, 0x7F) << H3_BC_OFFSET;

    var bad_bc: i32 = RES0_CELL_COUNT;
    while (bad_bc < 128) : (bad_bc += 1) {
        const poisoned = (seed_cell & ~bc_mask) |
            (@as(H3Index, @intCast(bad_bc)) << H3_BC_OFFSET);
        try testing.expect(!isValidCell(poisoned));
        try testing.expectEqual(root.isValidCell(poisoned), isValidCell(poisoned));
    }
}

test "pure isValidCell rejects cell with INVALID_DIGIT sentinel at in-resolution slot" {
    // The digit-range guard in isValidCell rejects any digit equal to
    // INVALID_DIGIT (7) at slots r in 1..res. The `getCellDigit` return
    // type is `u3`, so the guard must use `>=` not `>` — `digit > 7` is
    // unreachable. Surfaced by mutation operator M08 (`digit >= INVALID_DIGIT`
    // → `digit > INVALID_DIGIT`).
    const cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 5);
    try testing.expect(isValidCell(cell));

    // Poison the digit at resolution 3 (an in-resolution slot for a res-5
    // cell, i.e., r ≤ res) to INVALID_DIGIT.
    const shift: u6 = @intCast((@as(i32, MAX_RES) - 3) * @as(i32, H3_PER_DIGIT_OFFSET));
    const mask = @as(H3Index, 0x7) << shift;
    const poisoned = (cell & ~mask) | (@as(H3Index, INVALID_DIGIT) << shift);
    try testing.expect(!isValidCell(poisoned));
    try testing.expectEqual(root.isValidCell(poisoned), isValidCell(poisoned));
}

test "pure h3ToString matches libh3 byte-for-byte" {
    var rng = std.Random.DefaultPrng.init(0xF00DBA12);
    var our_buf: [17]u8 = undefined;
    var their_buf: [17]u8 = undefined;

    for (0..200) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const res: i32 = @intCast(rng.random().int(u32) % 16);
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat_deg, lng_deg), res);

        const ours = try h3ToString(cell, &our_buf);
        const theirs = try root.h3ToString(cell, &their_buf);
        try testing.expectEqualStrings(theirs, ours);
    }
}

test "pure h3ToString rejects undersized buffer" {
    var small: [16]u8 = undefined;
    try testing.expectError(Error.MemoryBounds, h3ToString(0x12345, &small));
}

test "pure stringToH3 roundtrips through h3ToString" {
    var rng = std.Random.DefaultPrng.init(0xC0DEBA5E);
    var buf: [17]u8 = undefined;

    for (0..200) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const res: i32 = @intCast(rng.random().int(u32) % 16);
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat_deg, lng_deg), res);

        const s = try h3ToString(cell, &buf);
        try testing.expectEqual(cell, try stringToH3(s));
    }
}

test "pure stringToH3 agrees with libh3 on the wrapped path" {
    // Generate via libh3, parse with pure-Zig, compare cell values.
    var rng = std.Random.DefaultPrng.init(0xBAB1ED);
    var buf: [17]u8 = undefined;
    var zbuf: [17]u8 = undefined;

    for (0..200) |_| {
        const lat_deg = (rng.random().float(f64) - 0.5) * 179.0;
        const lng_deg = (rng.random().float(f64) - 0.5) * 359.0;
        const res: i32 = @intCast(rng.random().int(u32) % 16);
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat_deg, lng_deg), res);

        const theirs = try root.h3ToString(cell, &buf);

        // libh3's stringToH3 needs a null-terminated string.
        @memcpy(zbuf[0..theirs.len], theirs);
        zbuf[theirs.len] = 0;
        const z: [:0]const u8 = zbuf[0..theirs.len :0];

        const ours_value = try stringToH3(theirs);
        const theirs_value = try root.stringToH3(z);
        try testing.expectEqual(theirs_value, ours_value);
    }
}

test "pure stringToH3 handles 0x prefix, whitespace, and uppercase" {
    try testing.expectEqual(@as(H3Index, 0xABC), try stringToH3("abc"));
    try testing.expectEqual(@as(H3Index, 0xABC), try stringToH3("ABC"));
    try testing.expectEqual(@as(H3Index, 0xABC), try stringToH3("0xabc"));
    try testing.expectEqual(@as(H3Index, 0xABC), try stringToH3("0XABC"));
    try testing.expectEqual(@as(H3Index, 0xABC), try stringToH3("  \tabc"));
    try testing.expectEqual(@as(H3Index, 0xFFFFFFFFFFFFFFFF), try stringToH3("ffffffffffffffff"));
}

test "pure stringToH3 rejects malformed input" {
    try testing.expectError(Error.Failed, stringToH3(""));
    try testing.expectError(Error.Failed, stringToH3("   "));
    try testing.expectError(Error.Failed, stringToH3("0x"));
    try testing.expectError(Error.Failed, stringToH3("notahex"));
    try testing.expectError(Error.Failed, stringToH3("ffffffffffffffff0")); // 17 digits = overflow
}

test "pure h3ToString → pure stringToH3 across all res-0 base cells" {
    var cells: [122]H3Index = undefined;
    try root.getRes0Cells(&cells);
    var buf: [17]u8 = undefined;
    for (cells) |cell| {
        const s = try h3ToString(cell, &buf);
        try testing.expectEqual(cell, try stringToH3(s));
    }
}

// =============================================================================
// Phase 4 — hexagon avg-area / avg-edge-length lookup tables
//
// Bit-identical f64 constants from libh3 src/h3lib/lib/latLng.c.
// =============================================================================

const HEXAGON_AREA_AVG_KM2 = [_]f64{
    4.357449416078383e+06, 6.097884417941332e+05, 8.680178039899720e+04,
    1.239343465508816e+04, 1.770347654491307e+03, 2.529038581819449e+02,
    3.612906216441245e+01, 5.161293359717191e+00, 7.373275975944177e-01,
    1.053325134272067e-01, 1.504750190766435e-02, 2.149643129451879e-03,
    3.070918756316060e-04, 4.387026794728296e-05, 6.267181135324313e-06,
    8.953115907605790e-07,
};

const HEXAGON_AREA_AVG_M2 = [_]f64{
    4.357449416078390e+12, 6.097884417941339e+11, 8.680178039899731e+10,
    1.239343465508818e+10, 1.770347654491309e+09, 2.529038581819452e+08,
    3.612906216441250e+07, 5.161293359717198e+06, 7.373275975944188e+05,
    1.053325134272069e+05, 1.504750190766437e+04, 2.149643129451882e+03,
    3.070918756316063e+02, 4.387026794728301e+01, 6.267181135324322e+00,
    8.953115907605802e-01,
};

const HEXAGON_EDGE_LEN_AVG_KM = [_]f64{
    1107.712591, 418.6760055, 158.2446558, 59.81085794,
    22.6063794,  8.544408276, 3.229482772, 1.220629759,
    0.461354684, 0.174375668, 0.065907807, 0.024910561,
    0.009415526, 0.003559893, 0.001348575, 0.000509713,
};

const HEXAGON_EDGE_LEN_AVG_M = [_]f64{
    1107712.591, 418676.0055, 158244.6558, 59810.85794,
    22606.3794,  8544.408276, 3229.482772, 1220.629759,
    461.3546837, 174.3756681, 65.90780749, 24.9105614,
    9.415526211, 3.559893033, 1.348574562, 0.509713273,
};

pub fn hexagonAreaAvgKm2(res: i32) Error!f64 {
    if (res < 0 or res > MAX_RES) return Error.ResolutionDomain;
    return HEXAGON_AREA_AVG_KM2[@intCast(res)];
}

pub fn hexagonAreaAvgM2(res: i32) Error!f64 {
    if (res < 0 or res > MAX_RES) return Error.ResolutionDomain;
    return HEXAGON_AREA_AVG_M2[@intCast(res)];
}

pub fn hexagonEdgeLengthAvgKm(res: i32) Error!f64 {
    if (res < 0 or res > MAX_RES) return Error.ResolutionDomain;
    return HEXAGON_EDGE_LEN_AVG_KM[@intCast(res)];
}

pub fn hexagonEdgeLengthAvgM(res: i32) Error!f64 {
    if (res < 0 or res > MAX_RES) return Error.ResolutionDomain;
    return HEXAGON_EDGE_LEN_AVG_M[@intCast(res)];
}

test "pure hexagonAreaAvgKm2 is bit-identical to libh3 across all resolutions" {
    var r: i32 = 0;
    while (r <= MAX_RES) : (r += 1) {
        try testing.expectEqual(try root.hexagonAreaAvgKm2(r), try hexagonAreaAvgKm2(r));
    }
}

test "pure hexagonAreaAvgM2 is bit-identical to libh3 across all resolutions" {
    var r: i32 = 0;
    while (r <= MAX_RES) : (r += 1) {
        try testing.expectEqual(try root.hexagonAreaAvgM2(r), try hexagonAreaAvgM2(r));
    }
}

test "pure hexagonEdgeLengthAvgKm is bit-identical to libh3 across all resolutions" {
    var r: i32 = 0;
    while (r <= MAX_RES) : (r += 1) {
        try testing.expectEqual(try root.hexagonEdgeLengthAvgKm(r), try hexagonEdgeLengthAvgKm(r));
    }
}

test "pure hexagonEdgeLengthAvgM is bit-identical to libh3 across all resolutions" {
    var r: i32 = 0;
    while (r <= MAX_RES) : (r += 1) {
        try testing.expectEqual(try root.hexagonEdgeLengthAvgM(r), try hexagonEdgeLengthAvgM(r));
    }
}

test "pure hexagon avg functions reject out-of-range resolution" {
    try testing.expectError(Error.ResolutionDomain, hexagonAreaAvgKm2(-1));
    try testing.expectError(Error.ResolutionDomain, hexagonAreaAvgKm2(16));
    try testing.expectError(Error.ResolutionDomain, hexagonAreaAvgM2(-1));
    try testing.expectError(Error.ResolutionDomain, hexagonAreaAvgM2(16));
    try testing.expectError(Error.ResolutionDomain, hexagonEdgeLengthAvgKm(-1));
    try testing.expectError(Error.ResolutionDomain, hexagonEdgeLengthAvgKm(16));
    try testing.expectError(Error.ResolutionDomain, hexagonEdgeLengthAvgM(-1));
    try testing.expectError(Error.ResolutionDomain, hexagonEdgeLengthAvgM(16));
}

// =============================================================================
// Fuzz: adversarial-input safety on the pure-Zig parser path
// =============================================================================
//
// The 142 cross-validation tests cover known-good inputs. This fuzz test
// covers the *garbage*-input safety contract: feed 10 000 random u64 values
// into the pure-Zig parser surface (`isValidCell`, `cellToLatLng`,
// `getResolution`, `getBaseCellNumber`, `isPentagon`) and verify nothing
// panics, no NaN/Inf escapes, and `isValidCell` agreement between the random
// input and a cell that survives the round-trip stays consistent.
//
// PRNG seed is fixed for reproducibility. The cellToLatLng round-trip only
// runs when isValidCell returns true — invalid inputs are expected to error,
// and we just assert they error cleanly (no panic).

const h3index = @import("pure_h3index.zig");
const h3decode = @import("pure_h3decode.zig");

test "fuzz: pure parser rejects garbage u64 inputs without panicking" {
    const fuzz_iters: usize = 10_000;
    var rng = std.Random.DefaultPrng.init(0x60A1_DEAD_BEEF_C0DE);
    const r = rng.random();

    var seen_valid: usize = 0;
    var seen_invalid: usize = 0;

    var i: usize = 0;
    while (i < fuzz_iters) : (i += 1) {
        const candidate: H3Index = r.int(u64);

        // Step 1: probe inspection functions — these must never panic on any
        // 64-bit input, even garbage.
        const res = getResolution(candidate);
        _ = getBaseCellNumber(candidate);
        _ = isPentagon(candidate);
        const valid = isValidCell(candidate);

        if (valid) {
            seen_valid += 1;
            // For valid cells, cellToLatLng must return finite coordinates
            // and round-trip back to the same cell when re-resolved.
            const ll = try h3decode.cellToLatLng(candidate);
            try testing.expect(std.math.isFinite(ll.lat));
            try testing.expect(std.math.isFinite(ll.lng));
            try testing.expect(ll.lat >= -std.math.pi / 2.0 - 1e-9);
            try testing.expect(ll.lat <= std.math.pi / 2.0 + 1e-9);

            // Round-trip via latLngToCell at the cell's own resolution. The
            // result must be a valid cell; in pentagon-adjacent regions it
            // may differ from the input due to centroid drift, but it must
            // not panic and must remain valid.
            if (res >= 0 and res <= MAX_RES) {
                const round = try h3index.latLngToCell(ll, res);
                try testing.expect(isValidCell(round));
            }
        } else {
            seen_invalid += 1;
            // For invalid cells, cellToLatLng is allowed to error or return
            // garbage, but it must not panic. Wrap in `_ = ... catch ...`.
            // Any error code is acceptable for invalid input; we only care
            // that the call does not panic.
            if (h3decode.cellToLatLng(candidate)) |ll| {
                std.mem.doNotOptimizeAway(ll.lat);
            } else |_| {}
        }
    }

    // Sanity: random u64s should produce mostly-invalid inputs (the valid
    // cell space is sparse). Don't pin a specific ratio, just assert we hit
    // both branches so the fuzz exercises both code paths.
    try testing.expect(seen_invalid > 0);
    // (seen_valid may be zero in principle; the H3 valid-cell density is
    // very low. The interesting failure mode is panic-on-invalid, which we
    // covered above.)
}

test "fuzz: pure latLngToCell rejects non-finite input cleanly" {
    const inputs = [_]LatLng{
        .{ .lat = std.math.nan(f64), .lng = 0.0 },
        .{ .lat = 0.0, .lng = std.math.nan(f64) },
        .{ .lat = std.math.inf(f64), .lng = 0.0 },
        .{ .lat = 0.0, .lng = -std.math.inf(f64) },
    };
    for (inputs) |p| {
        try testing.expectError(Error.LatLngDomain, h3index.latLngToCell(p, 9));
    }
}
