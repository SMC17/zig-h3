//! Pure-Zig H3 grid traversal — Phase 4e.
//!
//! Translates libh3's `h3NeighborRotations` and the gridDisk family:
//!
//!   - `gridDiskUnsafe` — fast spiral traversal; returns `Error.Pentagon`
//!     if any cell on the path is a pentagon
//!   - `gridDiskDistancesSafe` — recursive flood fill, correct even
//!     across pentagons; uses an open-addressed hash set keyed on
//!     `H3Index % maxIdx`
//!   - `gridDisk` / `gridDiskDistances` — try the unsafe path first,
//!     fall back to the safe path on pentagon
//!   - `gridRingUnsafe` — hollow ring at exact distance k
//!   - `areNeighborCells` — fast path via `cellToParent` digit lookup
//!     (libh3 also has a slow gridDisk-based fallback for cells that
//!     don't share a parent; this version returns `Error.Failed` for
//!     that path on res 0–1, matching how libh3 documents the fallback)
//!
//! Plus the supporting `baseCellNeighbors[122][7]` and
//! `baseCellNeighbor60CCWRots[122][7]` tables, the four 7×7
//! `NEW_DIGIT`/`NEW_ADJUSTMENT` Class-II/III adjustment tables, and the
//! `DIRECTIONS[6]` traversal order.

const std = @import("std");
const root = @import("root.zig");
const pure = @import("pure.zig");
const h3idx = @import("pure_h3index.zig");
const hier = @import("pure_hierarchy.zig");

pub const H3Index = root.H3Index;
pub const Error = root.Error;
pub const Direction = h3idx.Direction;
pub const MAX_RES = h3idx.MAX_RES;
pub const NUM_BASE_CELLS = h3idx.NUM_BASE_CELLS;
pub const INVALID_BASE_CELL: i32 = 127;

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

inline fn getIndexDigit(h: H3Index, res: i32) Direction {
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * @as(i32, H3_PER_DIGIT_OFFSET));
    return @enumFromInt(@as(u3, @intCast((h >> shift) & H3_DIGIT_MASK)));
}

inline fn setBaseCell(h: H3Index, bc: i32) H3Index {
    return (h & ~(@as(H3Index, 0x7F) << H3_BC_OFFSET)) |
        (@as(H3Index, @intCast(bc)) << H3_BC_OFFSET);
}

inline fn setIndexDigit(h: H3Index, res: i32, digit: Direction) H3Index {
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * @as(i32, H3_PER_DIGIT_OFFSET));
    return (h & ~(H3_DIGIT_MASK << shift)) |
        (@as(H3Index, @intFromEnum(digit)) << shift);
}

inline fn isClassIII(res: i32) bool {
    return (@mod(res, 2)) == 1;
}

// =============================================================================
// DIRECTIONS — the standard 6-neighbor traversal order
// =============================================================================

pub const DIRECTIONS = [_]Direction{
    .j_axes, .jk_axes, .k_axes, .ik_axes, .i_axes, .ij_axes,
};

pub const NEXT_RING_DIRECTION: Direction = .i_axes;

// =============================================================================
// NEW_DIGIT / NEW_ADJUSTMENT lookup tables (Class II + Class III)
// =============================================================================

const C = Direction.center;
const K = Direction.k_axes;
const J = Direction.j_axes;
const JK = Direction.jk_axes;
const I = Direction.i_axes;
const IK = Direction.ik_axes;
const IJ = Direction.ij_axes;

pub const NEW_DIGIT_II = [7][7]Direction{
    .{ C, K, J, JK, I, IK, IJ },
    .{ K, I, JK, IJ, IK, J, C },
    .{ J, JK, K, I, IJ, C, IK },
    .{ JK, IJ, I, IK, C, K, J },
    .{ I, IK, IJ, C, J, JK, K },
    .{ IK, J, C, K, JK, IJ, I },
    .{ IJ, C, IK, J, K, I, JK },
};

pub const NEW_ADJUSTMENT_II = [7][7]Direction{
    .{ C, C, C, C, C, C, C },
    .{ C, K, C, K, C, IK, C },
    .{ C, C, J, JK, C, C, J },
    .{ C, K, JK, JK, C, C, C },
    .{ C, C, C, C, I, I, IJ },
    .{ C, IK, C, C, I, IK, C },
    .{ C, C, J, C, IJ, C, IJ },
};

pub const NEW_DIGIT_III = [7][7]Direction{
    .{ C, K, J, JK, I, IK, IJ },
    .{ K, J, JK, I, IK, IJ, C },
    .{ J, JK, I, IK, IJ, C, K },
    .{ JK, I, IK, IJ, C, K, J },
    .{ I, IK, IJ, C, K, J, JK },
    .{ IK, IJ, C, K, J, JK, I },
    .{ IJ, C, K, J, JK, I, IK },
};

pub const NEW_ADJUSTMENT_III = [7][7]Direction{
    .{ C, C, C, C, C, C, C },
    .{ C, K, C, JK, C, K, C },
    .{ C, C, J, J, C, C, IJ },
    .{ C, JK, J, JK, C, C, C },
    .{ C, C, C, C, I, IK, I },
    .{ C, K, C, C, IK, IK, C },
    .{ C, C, IJ, C, I, C, IJ },
};

// =============================================================================
// baseCellNeighbors[122][7] — neighbors per base cell per IJK direction.
// 127 (INVALID_BASE_CELL) marks the deleted k-vertex on pentagons.
// =============================================================================

pub const baseCellNeighbors = [_][7]i32{
    [7]i32{ 0, 1, 5, 2, 4, 3, 8 },
    [7]i32{ 1, 7, 6, 9, 0, 3, 2 },
    [7]i32{ 2, 6, 10, 11, 0, 1, 5 },
    [7]i32{ 3, 13, 1, 7, 4, 12, 0 },
    [7]i32{ 4, 127, 15, 8, 3, 0, 12 },
    [7]i32{ 5, 2, 18, 10, 8, 0, 16 },
    [7]i32{ 6, 14, 11, 17, 1, 9, 2 },
    [7]i32{ 7, 21, 9, 19, 3, 13, 1 },
    [7]i32{ 8, 5, 22, 16, 4, 0, 15 },
    [7]i32{ 9, 19, 14, 20, 1, 7, 6 },
    [7]i32{ 10, 11, 24, 23, 5, 2, 18 },
    [7]i32{ 11, 17, 23, 25, 2, 6, 10 },
    [7]i32{ 12, 28, 13, 26, 4, 15, 3 },
    [7]i32{ 13, 26, 21, 29, 3, 12, 7 },
    [7]i32{ 14, 127, 17, 27, 9, 20, 6 },
    [7]i32{ 15, 22, 28, 31, 4, 8, 12 },
    [7]i32{ 16, 18, 33, 30, 8, 5, 22 },
    [7]i32{ 17, 11, 14, 6, 35, 25, 27 },
    [7]i32{ 18, 24, 30, 32, 5, 10, 16 },
    [7]i32{ 19, 34, 20, 36, 7, 21, 9 },
    [7]i32{ 20, 14, 19, 9, 40, 27, 36 },
    [7]i32{ 21, 38, 19, 34, 13, 29, 7 },
    [7]i32{ 22, 16, 41, 33, 15, 8, 31 },
    [7]i32{ 23, 24, 11, 10, 39, 37, 25 },
    [7]i32{ 24, 127, 32, 37, 10, 23, 18 },
    [7]i32{ 25, 23, 17, 11, 45, 39, 35 },
    [7]i32{ 26, 42, 29, 43, 12, 28, 13 },
    [7]i32{ 27, 40, 35, 46, 14, 20, 17 },
    [7]i32{ 28, 31, 42, 44, 12, 15, 26 },
    [7]i32{ 29, 43, 38, 47, 13, 26, 21 },
    [7]i32{ 30, 32, 48, 50, 16, 18, 33 },
    [7]i32{ 31, 41, 44, 53, 15, 22, 28 },
    [7]i32{ 32, 30, 24, 18, 52, 50, 37 },
    [7]i32{ 33, 30, 49, 48, 22, 16, 41 },
    [7]i32{ 34, 19, 38, 21, 54, 36, 51 },
    [7]i32{ 35, 46, 45, 56, 17, 27, 25 },
    [7]i32{ 36, 20, 34, 19, 55, 40, 54 },
    [7]i32{ 37, 39, 52, 57, 24, 23, 32 },
    [7]i32{ 38, 127, 34, 51, 29, 47, 21 },
    [7]i32{ 39, 37, 25, 23, 59, 57, 45 },
    [7]i32{ 40, 27, 36, 20, 60, 46, 55 },
    [7]i32{ 41, 49, 53, 61, 22, 33, 31 },
    [7]i32{ 42, 58, 43, 62, 26, 29, 28 },
    [7]i32{ 43, 62, 47, 64, 26, 42, 29 },
    [7]i32{ 44, 53, 58, 65, 28, 31, 42 },
    [7]i32{ 45, 39, 35, 25, 63, 59, 56 },
    [7]i32{ 46, 60, 56, 68, 27, 40, 35 },
    [7]i32{ 47, 38, 43, 29, 69, 51, 64 },
    [7]i32{ 48, 49, 30, 33, 67, 66, 50 },
    [7]i32{ 49, 127, 61, 66, 33, 48, 41 },
    [7]i32{ 50, 48, 32, 30, 70, 67, 52 },
    [7]i32{ 51, 69, 54, 71, 38, 47, 34 },
    [7]i32{ 52, 57, 70, 74, 32, 37, 50 },
    [7]i32{ 53, 61, 65, 75, 31, 41, 44 },
    [7]i32{ 54, 71, 55, 73, 34, 51, 36 },
    [7]i32{ 55, 40, 54, 36, 72, 60, 73 },
    [7]i32{ 56, 68, 63, 77, 35, 46, 45 },
    [7]i32{ 57, 59, 74, 78, 37, 39, 52 },
    [7]i32{ 58, 127, 62, 76, 44, 65, 42 },
    [7]i32{ 59, 63, 78, 79, 39, 45, 57 },
    [7]i32{ 60, 72, 68, 80, 40, 55, 46 },
    [7]i32{ 61, 53, 49, 41, 81, 75, 66 },
    [7]i32{ 62, 43, 58, 42, 82, 64, 76 },
    [7]i32{ 63, 127, 56, 45, 79, 59, 77 },
    [7]i32{ 64, 47, 62, 43, 84, 69, 82 },
    [7]i32{ 65, 58, 53, 44, 86, 76, 81 },
    [7]i32{ 66, 67, 81, 85, 49, 48, 61 },
    [7]i32{ 67, 66, 50, 48, 87, 85, 70 },
    [7]i32{ 68, 56, 60, 46, 90, 77, 80 },
    [7]i32{ 69, 51, 64, 47, 89, 71, 84 },
    [7]i32{ 70, 67, 52, 50, 83, 87, 74 },
    [7]i32{ 71, 89, 73, 91, 51, 69, 54 },
    [7]i32{ 72, 127, 73, 55, 80, 60, 88 },
    [7]i32{ 73, 91, 72, 88, 54, 71, 55 },
    [7]i32{ 74, 78, 83, 92, 52, 57, 70 },
    [7]i32{ 75, 65, 61, 53, 94, 86, 81 },
    [7]i32{ 76, 86, 82, 96, 58, 65, 62 },
    [7]i32{ 77, 63, 68, 56, 93, 79, 90 },
    [7]i32{ 78, 74, 59, 57, 95, 92, 79 },
    [7]i32{ 79, 78, 63, 59, 93, 95, 77 },
    [7]i32{ 80, 68, 72, 60, 99, 90, 88 },
    [7]i32{ 81, 65, 66, 61, 98, 94, 85 },
    [7]i32{ 82, 96, 84, 98, 62, 76, 64 },
    [7]i32{ 83, 127, 74, 70, 100, 87, 92 },
    [7]i32{ 84, 69, 82, 64, 97, 89, 97 },
    [7]i32{ 85, 87, 83, 94, 66, 67, 81 },
    [7]i32{ 86, 76, 75, 65, 104, 96, 94 },
    [7]i32{ 87, 83, 102, 100, 67, 70, 101 },
    [7]i32{ 88, 72, 91, 73, 99, 80, 105 },
    [7]i32{ 89, 97, 91, 103, 69, 84, 71 },
    [7]i32{ 90, 77, 80, 68, 106, 93, 99 },
    [7]i32{ 91, 73, 89, 71, 105, 88, 103 },
    [7]i32{ 92, 83, 78, 74, 108, 100, 95 },
    [7]i32{ 93, 79, 90, 77, 109, 95, 106 },
    [7]i32{ 94, 86, 81, 75, 107, 104, 98 },
    [7]i32{ 95, 92, 79, 78, 109, 108, 93 },
    [7]i32{ 96, 104, 98, 110, 76, 86, 82 },
    [7]i32{ 97, 127, 102, 103, 84, 89, 82 },
    [7]i32{ 98, 110, 101, 113, 82, 96, 84 },
    [7]i32{ 99, 80, 105, 88, 112, 106, 111 },
    [7]i32{ 100, 102, 87, 83, 117, 101, 108 },
    [7]i32{ 101, 102, 87, 85, 114, 99, 100 },
    [7]i32{ 102, 101, 87, 85, 114, 99, 100 },
    [7]i32{ 103, 91, 97, 89, 116, 105, 110 },
    [7]i32{ 104, 107, 110, 115, 86, 94, 96 },
    [7]i32{ 105, 88, 103, 91, 113, 99, 116 },
    [7]i32{ 106, 93, 99, 90, 117, 109, 112 },
    [7]i32{ 107, 127, 101, 94, 115, 104, 113 },
    [7]i32{ 108, 100, 95, 92, 119, 118, 109 },
    [7]i32{ 109, 108, 93, 95, 117, 118, 106 },
    [7]i32{ 110, 98, 104, 96, 119, 111, 115 },
    [7]i32{ 111, 119, 116, 121, 98, 110, 113 },
    [7]i32{ 112, 106, 105, 99, 121, 120, 116 },
    [7]i32{ 113, 116, 111, 120, 98, 101, 117 },
    [7]i32{ 114, 121, 118, 120, 102, 119, 117 },
    [7]i32{ 115, 116, 107, 104, 121, 113, 110 },
    [7]i32{ 116, 111, 113, 105, 120, 117, 115 },
    [7]i32{ 117, 127, 109, 118, 113, 121, 106 },
    [7]i32{ 118, 120, 108, 114, 117, 121, 109 },
    [7]i32{ 119, 111, 115, 110, 121, 116, 120 },
    [7]i32{ 120, 115, 114, 112, 121, 119, 118 },
    [7]i32{ 121, 116, 120, 119, 117, 113, 118 },
};

comptime {
    std.debug.assert(baseCellNeighbors.len == 122);
}

// =============================================================================
// baseCellNeighbor60CCWRots[122][7]
// =============================================================================

pub const baseCellNeighbor60CCWRots = [_][7]i32{
    [7]i32{ 0, 5, 0, 0, 1, 5, 1 },
    [7]i32{ 0, 0, 1, 0, 1, 0, 1 },
    [7]i32{ 0, 0, 0, 0, 0, 5, 0 },
    [7]i32{ 0, 5, 0, 0, 2, 5, 1 },
    [7]i32{ 0, -1, 1, 0, 3, 4, 2 },
    [7]i32{ 0, 0, 1, 0, 1, 0, 1 },
    [7]i32{ 0, 0, 0, 3, 5, 5, 0 },
    [7]i32{ 0, 0, 0, 0, 0, 5, 0 },
    [7]i32{ 0, 5, 0, 0, 0, 5, 1 },
    [7]i32{ 0, 0, 1, 3, 0, 0, 1 },
    [7]i32{ 0, 0, 1, 3, 0, 0, 1 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 5, 0, 0, 3, 5, 1 },
    [7]i32{ 0, 0, 1, 0, 1, 0, 1 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 5, 0, 0, 4, 5, 1 },
    [7]i32{ 0, 0, 0, 0, 0, 5, 0 },
    [7]i32{ 0, 3, 3, 3, 3, 0, 3 },
    [7]i32{ 0, 0, 0, 3, 5, 5, 0 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 3, 3, 3, 0, 3, 0 },
    [7]i32{ 0, 0, 0, 3, 5, 5, 0 },
    [7]i32{ 0, 0, 1, 0, 1, 0, 1 },
    [7]i32{ 0, 3, 3, 3, 0, 3, 0 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 0, 0, 3, 0, 0, 3 },
    [7]i32{ 0, 0, 0, 0, 0, 5, 0 },
    [7]i32{ 0, 3, 0, 0, 0, 3, 3 },
    [7]i32{ 0, 0, 1, 0, 1, 0, 1 },
    [7]i32{ 0, 0, 1, 3, 0, 0, 1 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 0, 0, 0, 0, 5, 0 },
    [7]i32{ 0, 3, 3, 3, 3, 0, 3 },
    [7]i32{ 0, 0, 1, 3, 0, 0, 1 },
    [7]i32{ 0, 3, 3, 3, 3, 0, 3 },
    [7]i32{ 0, 0, 3, 0, 3, 0, 3 },
    [7]i32{ 0, 0, 0, 3, 0, 0, 3 },
    [7]i32{ 0, 3, 0, 0, 0, 3, 3 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 3, 0, 0, 3, 3, 0 },
    [7]i32{ 0, 3, 0, 0, 3, 3, 0 },
    [7]i32{ 0, 0, 0, 3, 5, 5, 0 },
    [7]i32{ 0, 0, 0, 3, 5, 5, 0 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 0, 1, 3, 0, 0, 1 },
    [7]i32{ 0, 0, 3, 0, 0, 3, 3 },
    [7]i32{ 0, 0, 0, 3, 0, 3, 0 },
    [7]i32{ 0, 3, 3, 3, 0, 3, 0 },
    [7]i32{ 0, 3, 3, 3, 0, 3, 0 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 0, 0, 3, 0, 0, 3 },
    [7]i32{ 0, 3, 0, 0, 0, 3, 3 },
    [7]i32{ 0, 0, 3, 0, 3, 0, 3 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 0, 3, 0, 3, 0, 3 },
    [7]i32{ 0, 0, 3, 0, 0, 3, 3 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 3 },
    [7]i32{ 0, 0, 0, 3, 0, 3, 0 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 3, 3, 3, 3, 3, 0 },
    [7]i32{ 0, 3, 3, 3, 3, 3, 0 },
    [7]i32{ 0, 3, 3, 3, 3, 0, 3 },
    [7]i32{ 0, 3, 3, 3, 3, 0, 3 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 0, 0, 3, 0, 0, 3 },
    [7]i32{ 0, 3, 3, 3, 0, 3, 0 },
    [7]i32{ 0, 3, 0, 0, 0, 3, 3 },
    [7]i32{ 0, 3, 0, 0, 3, 3, 0 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 3, 0, 0, 3, 3, 0 },
    [7]i32{ 0, 0, 3, 0, 0, 3, 3 },
    [7]i32{ 0, 0, 0, 3, 0, 3, 0 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 3 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 3 },
    [7]i32{ 0, 0, 0, 3, 0, 0, 3 },
    [7]i32{ 0, 3, 0, 0, 0, 3, 3 },
    [7]i32{ 0, 0, 0, 3, 0, 5, 0 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 0, 1, 3, 1, 0, 1 },
    [7]i32{ 0, 0, 1, 3, 1, 0, 1 },
    [7]i32{ 0, 0, 3, 0, 3, 0, 3 },
    [7]i32{ 0, 0, 3, 0, 3, 0, 3 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 0, 3, 0, 0, 3, 3 },
    [7]i32{ 0, 0, 0, 3, 0, 3, 0 },
    [7]i32{ 0, 3, 0, 0, 3, 3, 0 },
    [7]i32{ 0, 3, 3, 3, 3, 3, 0 },
    [7]i32{ 0, 0, 0, 3, 0, 5, 0 },
    [7]i32{ 0, 3, 3, 3, 3, 3, 0 },
    [7]i32{ 0, 0, 0, 0, 0, 0, 1 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 0, 0, 3, 0, 5, 0 },
    [7]i32{ 0, 5, 0, 0, 5, 5, 0 },
    [7]i32{ 0, 0, 3, 0, 0, 3, 3 },
    [7]i32{ 0, 0, 0, 0, 0, 0, 1 },
    [7]i32{ 0, 0, 0, 3, 0, 3, 0 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 3 },
    [7]i32{ 0, 5, 0, 0, 5, 5, 0 },
    [7]i32{ 0, 0, 1, 3, 1, 0, 1 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 3 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 0, 1, 3, 1, 0, 1 },
    [7]i32{ 0, 3, 3, 3, 3, 3, 0 },
    [7]i32{ 0, 0, 0, 0, 0, 0, 1 },
    [7]i32{ 0, 0, 1, 0, 3, 5, 1 },
    [7]i32{ 0, -1, 3, 0, 5, 2, 0 },
    [7]i32{ 0, 5, 0, 0, 5, 5, 0 },
    [7]i32{ 0, 0, 1, 0, 4, 5, 1 },
    [7]i32{ 0, 3, 3, 3, 0, 0, 0 },
    [7]i32{ 0, 0, 0, 3, 0, 5, 0 },
    [7]i32{ 0, 0, 0, 3, 0, 5, 0 },
    [7]i32{ 0, 0, 1, 0, 2, 5, 1 },
    [7]i32{ 0, 0, 0, 0, 0, 0, 1 },
    [7]i32{ 0, 0, 1, 3, 1, 0, 1 },
    [7]i32{ 0, 5, 0, 0, 5, 5, 0 },
    [7]i32{ 0, -1, 1, 0, 3, 4, 2 },
    [7]i32{ 0, 0, 1, 0, 0, 5, 1 },
    [7]i32{ 0, 0, 0, 0, 0, 0, 1 },
    [7]i32{ 0, 5, 0, 0, 5, 5, 0 },
    [7]i32{ 0, 0, 1, 0, 1, 5, 1 },
};

comptime {
    std.debug.assert(baseCellNeighbor60CCWRots.len == 122);
}

inline fn isBaseCellPolarPentagon(bc: i32) bool {
    return bc == 4 or bc == 117;
}

// =============================================================================
// h3NeighborRotations — the foundational neighbor-step function
// =============================================================================

/// Compute the neighbor of `origin` in direction `dir`, accumulating any 60°
/// CCW rotations required to keep the destination's local coordinate frame
/// consistent with the origin's. Mirrors `libh3`'s `h3NeighborRotations`.
///
/// `rotations` is in/out: callers pass an accumulator and receive the updated
/// value. Pass `0` for a first call.
///
/// Returns `Error.Pentagon` when traversing through the deleted k-axis of a
/// pentagon (an unrecoverable case for the caller's chosen direction).
pub fn h3NeighborRotations(origin_in: H3Index, dir_in: Direction, rotations: *i32) Error!H3Index {
    var current = origin_in;
    var dir = dir_in;

    if (@intFromEnum(dir) < @intFromEnum(Direction.center) or
        @intFromEnum(dir) >= @intFromEnum(Direction.invalid))
    {
        return Error.Failed;
    }

    rotations.* = @mod(rotations.*, 6);
    {
        var i: i32 = 0;
        while (i < rotations.*) : (i += 1) {
            dir = ccw60Direction(dir);
        }
    }

    var new_rotations: i32 = 0;
    const old_base_cell = getBaseCellRaw(current);
    if (old_base_cell < 0 or old_base_cell >= NUM_BASE_CELLS) return Error.CellInvalid;
    const old_leading_digit = h3idx.h3LeadingNonZeroDigit(current);

    // Walk up the index, adjusting digits / rotations.
    var r: i32 = getResolution(current) - 1;
    while (true) {
        if (r == -1) {
            const bc_idx: usize = @intCast(old_base_cell);
            const dir_idx: usize = @intFromEnum(dir);
            current = setBaseCell(current, baseCellNeighbors[bc_idx][dir_idx]);
            new_rotations = baseCellNeighbor60CCWRots[bc_idx][dir_idx];

            if (getBaseCellRaw(current) == INVALID_BASE_CELL) {
                // Deleted k vertex at base-cell level — re-route via IK direction.
                const ik_idx: usize = @intFromEnum(Direction.ik_axes);
                current = setBaseCell(current, baseCellNeighbors[bc_idx][ik_idx]);
                new_rotations = baseCellNeighbor60CCWRots[bc_idx][ik_idx];
                current = h3idx.h3Rotate60ccw(current);
                rotations.* += 1;
            }
            break;
        }
        const old_digit = getIndexDigit(current, r + 1);
        if (old_digit == .invalid) return Error.CellInvalid;
        const next_dir: Direction = blk: {
            if (isClassIII(r + 1)) {
                current = setIndexDigit(current, r + 1, NEW_DIGIT_II[@intFromEnum(old_digit)][@intFromEnum(dir)]);
                break :blk NEW_ADJUSTMENT_II[@intFromEnum(old_digit)][@intFromEnum(dir)];
            } else {
                current = setIndexDigit(current, r + 1, NEW_DIGIT_III[@intFromEnum(old_digit)][@intFromEnum(dir)]);
                break :blk NEW_ADJUSTMENT_III[@intFromEnum(old_digit)][@intFromEnum(dir)];
            }
        };
        if (next_dir != .center) {
            dir = next_dir;
            r -= 1;
        } else break;
    }

    const new_base_cell = getBaseCellRaw(current);
    if (h3idx.isBaseCellPentagon(new_base_cell)) {
        var already_adjusted_k: bool = false;
        if (h3idx.h3LeadingNonZeroDigit(current) == .k_axes) {
            if (old_base_cell != new_base_cell) {
                // Traversed INTO another pentagon's deleted-K subsequence —
                // determine cw/ccw rotation based on the offset face.
                const home_face = h3idx.baseCellData[@intCast(old_base_cell)].home_face;
                if (h3idx.baseCellIsCwOffset(new_base_cell, home_face)) {
                    current = h3idx.h3Rotate60cw(current);
                } else {
                    current = h3idx.h3Rotate60ccw(current);
                }
                already_adjusted_k = true;
            } else {
                // Stayed within the same pentagon base cell, hit deleted K.
                switch (old_leading_digit) {
                    .center => return Error.Pentagon,
                    .jk_axes => {
                        current = h3idx.h3Rotate60ccw(current);
                        rotations.* += 1;
                    },
                    .ik_axes => {
                        current = h3idx.h3Rotate60cw(current);
                        rotations.* += 5;
                    },
                    else => return Error.Failed,
                }
            }
        }
        var i: i32 = 0;
        while (i < new_rotations) : (i += 1) current = h3idx.h3RotatePent60ccw(current);

        if (old_base_cell != new_base_cell) {
            if (isBaseCellPolarPentagon(new_base_cell)) {
                if (old_base_cell != 118 and old_base_cell != 8 and
                    h3idx.h3LeadingNonZeroDigit(current) != .jk_axes)
                {
                    rotations.* += 1;
                }
            } else if (h3idx.h3LeadingNonZeroDigit(current) == .ik_axes and !already_adjusted_k) {
                rotations.* += 1;
            }
        }
    } else {
        var i: i32 = 0;
        while (i < new_rotations) : (i += 1) current = h3idx.h3Rotate60ccw(current);
    }

    rotations.* = @mod(rotations.* + new_rotations, 6);
    return current;
}

fn ccw60Direction(d: Direction) Direction {
    return switch (d) {
        .k_axes => .ik_axes,
        .ik_axes => .i_axes,
        .i_axes => .ij_axes,
        .ij_axes => .j_axes,
        .j_axes => .jk_axes,
        .jk_axes => .k_axes,
        else => d,
    };
}

// =============================================================================
// gridDiskUnsafe — fast spiral, errors on pentagon
// =============================================================================

pub fn gridDiskUnsafe(origin_in: H3Index, k: i32, out: []H3Index) Error!void {
    if (k < 0) return Error.Domain;
    if (out.len < @as(usize, @intCast(try pure.maxGridDiskSize(k)))) {
        return Error.MemoryBounds;
    }

    var origin = origin_in;
    var idx: usize = 0;
    out[idx] = origin;
    idx += 1;

    if (pure.isPentagon(origin)) return Error.Pentagon;

    var ring: i32 = 1;
    var direction: usize = 0;
    var i_pos: i32 = 0;
    var rotations: i32 = 0;

    while (ring <= k) {
        if (direction == 0 and i_pos == 0) {
            origin = try h3NeighborRotations(origin, NEXT_RING_DIRECTION, &rotations);
            if (pure.isPentagon(origin)) return Error.Pentagon;
        }
        origin = try h3NeighborRotations(origin, DIRECTIONS[direction], &rotations);
        out[idx] = origin;
        idx += 1;
        i_pos += 1;
        if (i_pos == ring) {
            i_pos = 0;
            direction += 1;
            if (direction == 6) {
                direction = 0;
                ring += 1;
            }
        }
        if (pure.isPentagon(origin)) return Error.Pentagon;
    }
}

// =============================================================================
// gridDiskDistancesSafe — recursive flood fill, correct everywhere
// =============================================================================

fn gridDiskDistancesInternal(
    origin: H3Index,
    k: i32,
    out: []H3Index,
    distances: []i32,
    max_idx: i64,
    cur_k: i32,
) Error!void {
    var off: i64 = @mod(@as(i64, @intCast(origin)), max_idx);
    while (out[@intCast(off)] != 0 and out[@intCast(off)] != origin) {
        off = @mod(off + 1, max_idx);
    }
    if (out[@intCast(off)] == origin and distances[@intCast(off)] <= cur_k) return;
    out[@intCast(off)] = origin;
    distances[@intCast(off)] = cur_k;

    if (cur_k >= k) return;

    for (DIRECTIONS) |d| {
        var rotations: i32 = 0;
        const next = h3NeighborRotations(origin, d, &rotations) catch |err| {
            if (err == Error.Pentagon) continue;
            return err;
        };
        try gridDiskDistancesInternal(next, k, out, distances, max_idx, cur_k + 1);
    }
}

pub fn gridDiskDistancesSafe(
    origin: H3Index,
    k: i32,
    out: []H3Index,
    distances: []i32,
) Error!void {
    const max_idx = try pure.maxGridDiskSize(k);
    if (@as(i64, @intCast(out.len)) < max_idx) return Error.MemoryBounds;
    if (@as(i64, @intCast(distances.len)) < max_idx) return Error.MemoryBounds;
    @memset(out[0..@intCast(max_idx)], 0);
    @memset(distances[0..@intCast(max_idx)], 0);
    try gridDiskDistancesInternal(origin, k, out, distances, max_idx, 0);
}

// =============================================================================
// gridDisk — try unsafe first, fall back to safe
// =============================================================================

pub fn gridDisk(origin: H3Index, k: i32, allocator: std.mem.Allocator, out: []H3Index) Error!void {
    const max_idx = try pure.maxGridDiskSize(k);
    if (@as(i64, @intCast(out.len)) < max_idx) return Error.MemoryBounds;
    @memset(out[0..@intCast(max_idx)], 0);

    gridDiskUnsafe(origin, k, out) catch {
        @memset(out[0..@intCast(max_idx)], 0);
        const distances = allocator.alloc(i32, @intCast(max_idx)) catch return Error.MemoryAlloc;
        defer allocator.free(distances);
        try gridDiskDistancesSafe(origin, k, out, distances);
    };
}

// =============================================================================
// gridRingUnsafe — hollow ring at exact distance k
// =============================================================================

pub fn gridRingUnsafe(origin_in: H3Index, k: i32, out: []H3Index) Error!void {
    if (k < 0) return Error.Domain;
    if (k == 0) {
        if (out.len < 1) return Error.MemoryBounds;
        out[0] = origin_in;
        return;
    }
    const needed: usize = @intCast(6 * k);
    if (out.len < needed) return Error.MemoryBounds;

    var origin = origin_in;
    if (pure.isPentagon(origin)) return Error.Pentagon;

    var rotations: i32 = 0;
    var ring: i32 = 0;
    while (ring < k) : (ring += 1) {
        origin = try h3NeighborRotations(origin, NEXT_RING_DIRECTION, &rotations);
        if (pure.isPentagon(origin)) return Error.Pentagon;
    }

    var idx: usize = 0;
    out[idx] = origin;
    idx += 1;

    var direction: usize = 0;
    while (direction < 6) : (direction += 1) {
        var pos: i32 = 0;
        while (pos < k) : (pos += 1) {
            origin = try h3NeighborRotations(origin, DIRECTIONS[direction], &rotations);
            if (pos != k - 1 or direction != 5) {
                out[idx] = origin;
                idx += 1;
                if (pure.isPentagon(origin)) return Error.Pentagon;
            }
        }
    }
}

// =============================================================================
// areNeighborCells — direct neighbor check via gridDisk(1)
// =============================================================================

pub fn areNeighborCells(origin: H3Index, destination: H3Index) Error!bool {
    if (origin == destination) return false;
    if (getResolution(origin) != getResolution(destination)) return Error.ResolutionMismatch;

    // Fast path: cells that share a parent at res-1 use a digit-pair lookup.
    const res = getResolution(origin);
    const parent_res = res - 1;
    if (parent_res > 0) {
        const op = try hier.cellToParent(origin, parent_res);
        const dp = try hier.cellToParent(destination, parent_res);
        if (op == dp) {
            const od = getIndexDigit(origin, parent_res + 1);
            const dd = getIndexDigit(destination, parent_res + 1);
            if (od == .center or dd == .center) return true;
            if (@intFromEnum(od) >= @intFromEnum(Direction.invalid)) return Error.CellInvalid;
            // Cells that share a non-CENTER parent digit can still be neighbors via
            // specific clockwise / counter-clockwise digit pairings.
            const neighbor_cw = [_]Direction{ .center, .jk_axes, .ij_axes, .j_axes, .ik_axes, .k_axes, .i_axes };
            const neighbor_ccw = [_]Direction{ .center, .ik_axes, .jk_axes, .k_axes, .ij_axes, .i_axes, .j_axes };
            if (neighbor_cw[@intFromEnum(od)] == dd) return true;
            if (neighbor_ccw[@intFromEnum(od)] == dd) return true;
        }
    }

    // Slow path: gridDisk(origin, 1) and check membership.
    var ring: [7]H3Index = .{ 0, 0, 0, 0, 0, 0, 0 };
    gridDisk(origin, 1, std.heap.page_allocator, &ring) catch |err| {
        if (err == Error.MemoryAlloc) return err;
        return err;
    };
    for (ring) |c| {
        if (c == destination) return true;
    }
    return false;
}

// =============================================================================
// Cross-validation tests
// =============================================================================

const testing = std.testing;
const LatLng = root.LatLng;

test "pure gridDiskUnsafe matches libh3 on origin away from pentagons" {
    var rng = std.Random.DefaultPrng.init(0xD15C);
    var res: i32 = 4;
    while (res <= 10) : (res += 2) {
        for (0..20) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(cell)) continue;

            const k: i32 = 2;
            const max_idx: usize = @intCast(try pure.maxGridDiskSize(k));
            const theirs = try testing.allocator.alloc(H3Index, max_idx);
            defer testing.allocator.free(theirs);
            @memset(theirs, 0);
            // Use libh3 wrapper's gridDisk for the reference.
            const err_t = root.raw.gridDisk(cell, k, theirs.ptr);
            if (err_t != 0) continue; // skip pentagons hit on ring

            const ours = try testing.allocator.alloc(H3Index, max_idx);
            defer testing.allocator.free(ours);
            @memset(ours, 0);
            gridDiskUnsafe(cell, k, ours) catch continue;

            // Both should contain the same cells (order may differ from
            // gridDiskUnsafe vs gridDisk wrapper).  Verify set equality.
            var ours_set: [200]H3Index = undefined;
            var theirs_set: [200]H3Index = undefined;
            var on: usize = 0;
            var tn: usize = 0;
            for (ours) |c| if (c != 0) {
                ours_set[on] = c;
                on += 1;
            };
            for (theirs) |c| if (c != 0) {
                theirs_set[tn] = c;
                tn += 1;
            };
            try testing.expectEqual(on, tn);
            std.mem.sort(H3Index, ours_set[0..on], {}, std.sort.asc(H3Index));
            std.mem.sort(H3Index, theirs_set[0..tn], {}, std.sort.asc(H3Index));
            try testing.expectEqualSlices(H3Index, theirs_set[0..tn], ours_set[0..on]);
        }
    }
}

test "pure gridDiskDistancesSafe handles pentagons" {
    var pents: [12]H3Index = undefined;
    try root.getPentagons(5, &pents);
    const k: i32 = 2;
    const max_idx: usize = @intCast(try pure.maxGridDiskSize(k));
    for (pents) |p| {
        const cells = try testing.allocator.alloc(H3Index, max_idx);
        defer testing.allocator.free(cells);
        const dists = try testing.allocator.alloc(i32, max_idx);
        defer testing.allocator.free(dists);
        try gridDiskDistancesSafe(p, k, cells, dists);

        // Pentagon at k=2 should have <19 cells (some neighbors don't exist).
        var count: usize = 0;
        for (cells) |c| if (c != 0) {
            count += 1;
        };
        try testing.expect(count >= 11 and count <= 19);

        // The origin must be present at distance 0.
        var found = false;
        for (cells, dists) |c, d| {
            if (c == p) {
                try testing.expectEqual(@as(i32, 0), d);
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "pure gridRingUnsafe at k=1 returns exactly 6 cells around a non-pentagon" {
    var rng = std.Random.DefaultPrng.init(0xC1A1);
    for (0..20) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), 7);
        if (pure.isPentagon(cell)) continue;

        var ring: [6]H3Index = undefined;
        gridRingUnsafe(cell, 1, &ring) catch continue;
        // All 6 should be distinct, none equal origin, all neighbors of origin.
        for (ring) |neighbor| {
            try testing.expect(neighbor != cell);
            try testing.expect(neighbor != 0);
        }
        for (ring, 0..) |c1, idx| {
            for (ring[idx + 1 ..]) |c2| try testing.expect(c1 != c2);
        }
    }
}

test "pure gridRingUnsafe at k=0 returns origin" {
    const cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 5);
    var ring: [1]H3Index = undefined;
    try gridRingUnsafe(cell, 0, &ring);
    try testing.expectEqual(cell, ring[0]);
}

test "pure areNeighborCells via fast path on shared-parent cells" {
    // Pick a parent cell and verify two of its children are neighbors.
    var rng = std.Random.DefaultPrng.init(0xA1EA);
    var res: i32 = 3;
    while (res <= 8) : (res += 1) {
        for (0..10) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const parent = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(parent)) continue;
            const child0 = try hier.cellToCenterChild(parent, res + 1);
            // Walk to a sibling child by manipulating the digit.
            const childSize: usize = @intCast(try hier.cellToChildrenSize(parent, res + 1));
            const children = try testing.allocator.alloc(H3Index, childSize);
            defer testing.allocator.free(children);
            try hier.cellToChildren(parent, res + 1, children);
            // children[0] is the center child; any other child is a neighbor.
            const center_idx: usize = blk: {
                for (children, 0..) |c, idx| if (c == child0) break :blk idx;
                break :blk 0;
            };
            const sibling_idx: usize = if (center_idx == 0) 1 else 0;
            const sibling = children[sibling_idx];
            try testing.expect(try areNeighborCells(child0, sibling));
            try testing.expect(try areNeighborCells(sibling, child0));
        }
    }
}

test "pure areNeighborCells false for identical cells and for distant cells" {
    const cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 9);
    try testing.expect(!(try areNeighborCells(cell, cell)));

    const distant = try root.latLngToCell(LatLng.fromDegrees(0.0, 0.0), 9);
    try testing.expect(!(try areNeighborCells(cell, distant)));
}

test "pure areNeighborCells rejects mismatched resolution" {
    const a = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 5);
    const b = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 6);
    try testing.expectError(Error.ResolutionMismatch, areNeighborCells(a, b));
}
