//! Pure-Zig H3 hierarchy operations — Phase 4a.
//!
//! Translates libh3's `cellToParent`, `cellToCenterChild`, `cellToChildrenSize`,
//! and `cellToChildren` (with the children iterator). All pure bit manipulation
//! plus a closed-form size formula — no projection math required, so no
//! cross-face concerns.
//!
//! Cross-validated against the libh3 wrapper for every test.

const std = @import("std");
const root = @import("root.zig");
const pure = @import("pure.zig");
const h3idx = @import("pure_h3index.zig");

pub const H3Index = root.H3Index;
pub const Error = root.Error;
pub const MAX_RES = h3idx.MAX_RES;

const H3_RES_OFFSET: u6 = 52;
const H3_PER_DIGIT_OFFSET: u6 = 3;
const H3_DIGIT_MASK: u64 = 7;
const PENTAGON_SKIPPED_DIGIT: u3 = 1;
const INVALID_DIGIT: u3 = 7;

inline fn getResolution(h: H3Index) i32 {
    return @intCast((h >> H3_RES_OFFSET) & 0xF);
}

inline fn setResolution(h: H3Index, res: i32) H3Index {
    return (h & ~(@as(H3Index, 0xF) << H3_RES_OFFSET)) |
        (@as(H3Index, @intCast(res)) << H3_RES_OFFSET);
}

inline fn setIndexDigit(h: H3Index, res: i32, digit: u3) H3Index {
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * @as(i32, H3_PER_DIGIT_OFFSET));
    return (h & ~(H3_DIGIT_MASK << shift)) | (@as(H3Index, digit) << shift);
}

inline fn getIndexDigit(h: H3Index, res: i32) u3 {
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * @as(i32, H3_PER_DIGIT_OFFSET));
    return @intCast((h >> shift) & H3_DIGIT_MASK);
}

/// Zero out digits in `h` from `start` through `end` inclusive (1-indexed
/// resolutions). Mirrors libh3 `_zeroIndexDigits`.
fn zeroIndexDigits(h: H3Index, start: i32, end: i32) H3Index {
    if (start > end) return h;
    var m: H3Index = 0;
    m = ~m;
    m <<= @intCast(@as(i32, H3_PER_DIGIT_OFFSET) * (end - start + 1));
    m = ~m;
    m <<= @intCast(@as(i32, H3_PER_DIGIT_OFFSET) * (@as(i32, MAX_RES) - end));
    m = ~m;
    return h & m;
}

inline fn hasChildAtRes(h: H3Index, child_res: i32) bool {
    const parent_res = getResolution(h);
    return child_res >= parent_res and child_res <= MAX_RES;
}

/// Integer power: returns base^exp.
fn ipow(base: i64, exp: i32) i64 {
    var result: i64 = 1;
    var b = base;
    var e = exp;
    while (e > 0) {
        if ((e & 1) == 1) result *= b;
        b *= b;
        e >>= 1;
    }
    return result;
}

// =============================================================================
// cellToParent
// =============================================================================

pub fn cellToParent(cell: H3Index, parent_res: i32) Error!H3Index {
    const child_res = getResolution(cell);
    if (parent_res < 0 or parent_res > MAX_RES) return Error.ResolutionDomain;
    if (parent_res > child_res) return Error.ResolutionMismatch;
    if (parent_res == child_res) return cell;

    var parent_h = setResolution(cell, parent_res);
    var i: i32 = parent_res + 1;
    while (i <= child_res) : (i += 1) {
        parent_h = setIndexDigit(parent_h, i, INVALID_DIGIT);
    }
    return parent_h;
}

// =============================================================================
// cellToCenterChild
// =============================================================================

pub fn cellToCenterChild(cell: H3Index, child_res: i32) Error!H3Index {
    if (!hasChildAtRes(cell, child_res)) return Error.ResolutionDomain;
    var h = zeroIndexDigits(cell, getResolution(cell) + 1, child_res);
    h = setResolution(h, child_res);
    return h;
}

// =============================================================================
// cellToChildrenSize
// =============================================================================

pub fn cellToChildrenSize(cell: H3Index, child_res: i32) Error!i64 {
    if (!hasChildAtRes(cell, child_res)) return Error.ResolutionDomain;
    const n = child_res - getResolution(cell);
    if (pure.isPentagon(cell)) {
        // Pentagon child count formula: 1 + 5 × (7^n - 1) / 6
        return 1 + @divExact(5 * (ipow(7, n) - 1), 6);
    }
    return ipow(7, n);
}

fn isPentagon(h: H3Index) bool {
    return pure.isPentagon(h);
}

// =============================================================================
// cellToChildren iterator + collector
// =============================================================================

pub const ChildIterator = struct {
    h: H3Index,
    parent_res: i32,
    skip_digit: i32,

    pub fn done(self: ChildIterator) bool {
        return self.h == 0;
    }
};

const NULL_ITER: ChildIterator = .{ .h = 0, .parent_res = -1, .skip_digit = -1 };

inline fn getResDigit(it: ChildIterator, res: i32) u3 {
    return getIndexDigit(it.h, res);
}

inline fn incrementResDigit(it: *ChildIterator, res: i32) void {
    const shift: u6 = @intCast(@as(i32, H3_PER_DIGIT_OFFSET) * (@as(i32, MAX_RES) - res));
    it.h += @as(H3Index, 1) << shift;
}

pub fn iterInitParent(parent: H3Index, child_res: i32) ChildIterator {
    const parent_res = getResolution(parent);
    if (child_res < parent_res or child_res > MAX_RES or parent == 0) {
        return NULL_ITER;
    }
    var it = ChildIterator{
        .h = zeroIndexDigits(parent, parent_res + 1, child_res),
        .parent_res = parent_res,
        .skip_digit = -1,
    };
    it.h = setResolution(it.h, child_res);
    if (isPentagon(it.h)) {
        it.skip_digit = child_res;
    }
    return it;
}

pub fn iterStepChild(it: *ChildIterator) void {
    if (it.h == 0) return;

    const child_res = getResolution(it.h);
    incrementResDigit(it, child_res);

    var i: i32 = child_res;
    while (i >= it.parent_res) : (i -= 1) {
        if (i == it.parent_res) {
            it.* = NULL_ITER;
            return;
        }

        if (i == it.skip_digit and getResDigit(it.*, i) == PENTAGON_SKIPPED_DIGIT) {
            // Pentagon iteration: skip the K_AXES_DIGIT value
            incrementResDigit(it, i);
            it.skip_digit -= 1;
            return;
        }

        if (getResDigit(it.*, i) == INVALID_DIGIT) {
            // Carry to next digit position
            incrementResDigit(it, i);
        } else {
            break;
        }
    }
}

/// Fill `out` with all children of `cell` at `child_res`. The caller must
/// ensure `out.len >= cellToChildrenSize(cell, child_res)`.
pub fn cellToChildren(cell: H3Index, child_res: i32, out: []H3Index) Error!void {
    if (!hasChildAtRes(cell, child_res)) return Error.ResolutionDomain;
    var iter = iterInitParent(cell, child_res);
    var idx: usize = 0;
    while (!iter.done()) {
        if (idx >= out.len) return Error.MemoryBounds;
        out[idx] = iter.h;
        idx += 1;
        iterStepChild(&iter);
    }
}

// =============================================================================
// Cross-validation tests
// =============================================================================

const testing = std.testing;
const LatLng = root.LatLng;

test "pure cellToParent matches libh3 across random cells and all parent resolutions" {
    var rng = std.Random.DefaultPrng.init(0xFA7E_F00D_C0DE_BABE);
    var child_res: i32 = 0;
    while (child_res <= MAX_RES) : (child_res += 1) {
        for (0..30) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), child_res);
            var parent_res: i32 = 0;
            while (parent_res <= child_res) : (parent_res += 1) {
                const theirs = try root.cellToParent(cell, parent_res);
                const ours = try cellToParent(cell, parent_res);
                try testing.expectEqual(theirs, ours);
            }
        }
    }
}

test "pure cellToParent rejects invalid resolutions" {
    const cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 5);
    try testing.expectError(Error.ResolutionDomain, cellToParent(cell, -1));
    try testing.expectError(Error.ResolutionDomain, cellToParent(cell, 16));
    try testing.expectError(Error.ResolutionMismatch, cellToParent(cell, 10));
}

test "pure cellToCenterChild inverts via cellToParent across all resolutions" {
    var rng = std.Random.DefaultPrng.init(0xCEDA);
    var parent_res: i32 = 0;
    while (parent_res <= 10) : (parent_res += 1) {
        for (0..20) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), parent_res);
            var child_res: i32 = parent_res;
            while (child_res <= MAX_RES) : (child_res += 1) {
                // Center child must invert: cellToParent(centerChild) == cell.
                const ours_center = try cellToCenterChild(cell, child_res);
                const back = try cellToParent(ours_center, parent_res);
                try testing.expectEqual(cell, back);
            }
        }
    }
}

test "pure cellToChildrenSize matches libh3 on hex and pentagon cells" {
    var rng = std.Random.DefaultPrng.init(0x51E);
    var parent_res: i32 = 0;
    while (parent_res <= 8) : (parent_res += 1) {
        for (0..15) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), parent_res);
            var child_res: i32 = parent_res;
            while (child_res <= @min(parent_res + 5, MAX_RES)) : (child_res += 1) {
                const n: i32 = child_res - parent_res;
                const expected: i64 = if (isPentagon(cell))
                    1 + @divExact(5 * (ipow(7, n) - 1), 6)
                else
                    ipow(7, n);
                try testing.expectEqual(expected, try cellToChildrenSize(cell, child_res));
            }
        }
    }
}

test "pure cellToChildrenSize handles pentagons correctly" {
    // The 12 pentagons at res 0 each have 6 children at res 1 (not 7).
    var pents: [12]H3Index = undefined;
    try root.getPentagons(0, &pents);
    for (pents) |p| {
        // 1 + 5 × (7^1 - 1)/6 = 1 + 5 = 6
        try testing.expectEqual(@as(i64, 6), try cellToChildrenSize(p, 1));
        // 1 + 5 × (7^2 - 1)/6 = 1 + 5 × 8 = 41
        try testing.expectEqual(@as(i64, 41), try cellToChildrenSize(p, 2));
    }
}

test "pure cellToChildren produces the right count and the parent inverts" {
    var rng = std.Random.DefaultPrng.init(0xCCC);
    var parent_res: i32 = 0;
    while (parent_res <= 5) : (parent_res += 1) {
        for (0..5) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), parent_res);
            const child_res: i32 = @min(parent_res + 2, MAX_RES);

            const expected_n = try cellToChildrenSize(cell, child_res);
            const children = try testing.allocator.alloc(H3Index, @intCast(expected_n));
            defer testing.allocator.free(children);
            try cellToChildren(cell, child_res, children);

            // Every child must invert to the original parent.
            for (children) |child| {
                try testing.expectEqual(cell, try cellToParent(child, parent_res));
            }
            // No duplicates.
            for (children, 0..) |c1, i| {
                for (children[i + 1 ..]) |c2| try testing.expect(c1 != c2);
            }
        }
    }
}

test "pure cellToChildren of a pentagon skips K_AXES_DIGIT correctly" {
    var pents: [12]H3Index = undefined;
    try root.getPentagons(0, &pents);
    var children: [6]H3Index = undefined;
    try cellToChildren(pents[0], 1, &children);

    // None of the children should have K_AXES_DIGIT (1) at resolution 1.
    for (children) |c| {
        try testing.expect(getIndexDigit(c, 1) != PENTAGON_SKIPPED_DIGIT);
    }
    // All children invert to the pentagon.
    for (children) |c| {
        try testing.expectEqual(pents[0], try cellToParent(c, 0));
    }
}
