//! Pure-Zig H3 v4 index encoding — Phase 3b.
//!
//! This file completes the forward projection: `latLngToCell(point, res) →
//! H3Index`. Translates `libh3`'s `_faceIjkToH3`, the 122-entry
//! `baseCellData` table, the 540-entry `faceIjkBaseCells` lookup, and the
//! aperture-7 hierarchy helpers (`_upAp7`, `_downAp7`, `_upAp7r`,
//! `_downAp7r`) plus digit/coord rotation primitives.
//!
//! Cross-validation: every test in this file compares the pure-Zig output
//! against `root.latLngToCell` (the libh3 wrapper) on a wide set of inputs
//! and expects exact `H3Index` equality.

const std = @import("std");
const root = @import("root.zig");
const proj = @import("pure_proj.zig");

pub const LatLng = root.LatLng;
pub const H3Index = root.H3Index;
pub const Error = root.Error;
pub const CoordIJK = proj.CoordIJK;

pub const MAX_RES: i32 = 15;
pub const NUM_BASE_CELLS: i32 = 122;
pub const NUM_ICOSA_FACES: i32 = 20;
pub const MAX_FACE_COORD: i32 = 2;

// =============================================================================
// Direction enum + UNIT_VECS
// =============================================================================

pub const Direction = enum(u3) {
    center = 0,
    k_axes = 1,
    j_axes = 2,
    jk_axes = 3,
    i_axes = 4,
    ik_axes = 5,
    ij_axes = 6,
    invalid = 7,
};

pub const UNIT_VECS = [_]CoordIJK{
    .{ .i = 0, .j = 0, .k = 0 }, // 0 center
    .{ .i = 0, .j = 0, .k = 1 }, // 1 k_axes
    .{ .i = 0, .j = 1, .k = 0 }, // 2 j_axes
    .{ .i = 0, .j = 1, .k = 1 }, // 3 jk_axes
    .{ .i = 1, .j = 0, .k = 0 }, // 4 i_axes
    .{ .i = 1, .j = 0, .k = 1 }, // 5 ik_axes
    .{ .i = 1, .j = 1, .k = 0 }, // 6 ij_axes
};

// =============================================================================
// FaceIJK + base cell types
// =============================================================================

pub const FaceIJK = extern struct {
    face: i32,
    coord: CoordIJK,
};

pub const BaseCellData = struct {
    home_face: i32,
    home_i: i32,
    home_j: i32,
    home_k: i32,
    is_pentagon: bool,
    /// CW-offset adjacent faces for pentagon base cells. Both are `-1` for
    /// non-pentagons or for polar pentagons.
    cw_offset: [2]i32,
};

inline fn bc(face: i32, i: i32, j: i32, k: i32, pent: bool, o0: i32, o1: i32) BaseCellData {
    return .{
        .home_face = face,
        .home_i = i,
        .home_j = j,
        .home_k = k,
        .is_pentagon = pent,
        .cw_offset = .{ o0, o1 },
    };
}

pub const BaseCellRotation = struct {
    base: i32,
    ccw_rot: i32,
};

// =============================================================================
// baseCellData[122] — verbatim from libh3 src/h3lib/lib/baseCells.c
// =============================================================================

pub const baseCellData = [_]BaseCellData{
    bc(1, 1, 0, 0, false, 0, 0), //   base cell 0
    bc(2, 1, 1, 0, false, 0, 0), //   base cell 1
    bc(1, 0, 0, 0, false, 0, 0), //   base cell 2
    bc(2, 1, 0, 0, false, 0, 0), //   base cell 3
    bc(0, 2, 0, 0, true, -1, -1), //  base cell 4 (pentagon)
    bc(1, 1, 1, 0, false, 0, 0), //   base cell 5
    bc(1, 0, 0, 1, false, 0, 0), //   base cell 6
    bc(2, 0, 0, 0, false, 0, 0), //   base cell 7
    bc(0, 1, 0, 0, false, 0, 0), //   base cell 8
    bc(2, 0, 1, 0, false, 0, 0), //   base cell 9
    bc(1, 0, 1, 0, false, 0, 0), //   base cell 10
    bc(1, 0, 1, 1, false, 0, 0), //   base cell 11
    bc(3, 1, 0, 0, false, 0, 0), //   base cell 12
    bc(3, 1, 1, 0, false, 0, 0), //   base cell 13
    bc(11, 2, 0, 0, true, 2, 6), //   base cell 14 (pentagon)
    bc(4, 1, 0, 0, false, 0, 0), //   base cell 15
    bc(0, 0, 0, 0, false, 0, 0), //   base cell 16
    bc(6, 0, 1, 0, false, 0, 0), //   base cell 17
    bc(0, 0, 0, 1, false, 0, 0), //   base cell 18
    bc(2, 0, 1, 1, false, 0, 0), //   base cell 19
    bc(7, 0, 0, 1, false, 0, 0), //   base cell 20
    bc(2, 0, 0, 1, false, 0, 0), //   base cell 21
    bc(0, 1, 1, 0, false, 0, 0), //   base cell 22
    bc(6, 0, 0, 1, false, 0, 0), //   base cell 23
    bc(10, 2, 0, 0, true, 1, 5), //   base cell 24 (pentagon)
    bc(6, 0, 0, 0, false, 0, 0), //   base cell 25
    bc(3, 0, 0, 0, false, 0, 0), //   base cell 26
    bc(11, 1, 0, 0, false, 0, 0), //  base cell 27
    bc(4, 1, 1, 0, false, 0, 0), //   base cell 28
    bc(3, 0, 1, 0, false, 0, 0), //   base cell 29
    bc(0, 0, 1, 1, false, 0, 0), //   base cell 30
    bc(4, 0, 0, 0, false, 0, 0), //   base cell 31
    bc(5, 0, 1, 0, false, 0, 0), //   base cell 32
    bc(0, 0, 1, 0, false, 0, 0), //   base cell 33
    bc(7, 0, 1, 0, false, 0, 0), //   base cell 34
    bc(11, 1, 1, 0, false, 0, 0), //  base cell 35
    bc(7, 0, 0, 0, false, 0, 0), //   base cell 36
    bc(10, 1, 0, 0, false, 0, 0), //  base cell 37
    bc(12, 2, 0, 0, true, 3, 7), //   base cell 38 (pentagon)
    bc(6, 1, 0, 1, false, 0, 0), //   base cell 39
    bc(7, 1, 0, 1, false, 0, 0), //   base cell 40
    bc(4, 0, 0, 1, false, 0, 0), //   base cell 41
    bc(3, 0, 0, 1, false, 0, 0), //   base cell 42
    bc(3, 0, 1, 1, false, 0, 0), //   base cell 43
    bc(4, 0, 1, 0, false, 0, 0), //   base cell 44
    bc(6, 1, 0, 0, false, 0, 0), //   base cell 45
    bc(11, 0, 0, 0, false, 0, 0), //  base cell 46
    bc(8, 0, 0, 1, false, 0, 0), //   base cell 47
    bc(5, 0, 0, 1, false, 0, 0), //   base cell 48
    bc(14, 2, 0, 0, true, 0, 9), //   base cell 49 (pentagon)
    bc(5, 0, 0, 0, false, 0, 0), //   base cell 50
    bc(12, 1, 0, 0, false, 0, 0), //  base cell 51
    bc(10, 1, 1, 0, false, 0, 0), //  base cell 52
    bc(4, 0, 1, 1, false, 0, 0), //   base cell 53
    bc(12, 1, 1, 0, false, 0, 0), //  base cell 54
    bc(7, 1, 0, 0, false, 0, 0), //   base cell 55
    bc(11, 0, 1, 0, false, 0, 0), //  base cell 56
    bc(10, 0, 0, 0, false, 0, 0), //  base cell 57
    bc(13, 2, 0, 0, true, 4, 8), //   base cell 58 (pentagon)
    bc(10, 0, 0, 1, false, 0, 0), //  base cell 59
    bc(11, 0, 0, 1, false, 0, 0), //  base cell 60
    bc(9, 0, 1, 0, false, 0, 0), //   base cell 61
    bc(8, 0, 1, 0, false, 0, 0), //   base cell 62
    bc(6, 2, 0, 0, true, 11, 15), //  base cell 63 (pentagon)
    bc(8, 0, 0, 0, false, 0, 0), //   base cell 64
    bc(9, 0, 0, 1, false, 0, 0), //   base cell 65
    bc(14, 1, 0, 0, false, 0, 0), //  base cell 66
    bc(5, 1, 0, 1, false, 0, 0), //   base cell 67
    bc(16, 0, 1, 1, false, 0, 0), //  base cell 68
    bc(8, 1, 0, 1, false, 0, 0), //   base cell 69
    bc(5, 1, 0, 0, false, 0, 0), //   base cell 70
    bc(12, 0, 0, 0, false, 0, 0), //  base cell 71
    bc(7, 2, 0, 0, true, 12, 16), //  base cell 72 (pentagon)
    bc(12, 0, 1, 0, false, 0, 0), //  base cell 73
    bc(10, 0, 1, 0, false, 0, 0), //  base cell 74
    bc(9, 0, 0, 0, false, 0, 0), //   base cell 75
    bc(13, 1, 0, 0, false, 0, 0), //  base cell 76
    bc(16, 0, 0, 1, false, 0, 0), //  base cell 77
    bc(15, 0, 1, 1, false, 0, 0), //  base cell 78
    bc(15, 0, 1, 0, false, 0, 0), //  base cell 79
    bc(16, 0, 1, 0, false, 0, 0), //  base cell 80
    bc(14, 1, 1, 0, false, 0, 0), //  base cell 81
    bc(13, 1, 1, 0, false, 0, 0), //  base cell 82
    bc(5, 2, 0, 0, true, 10, 19), //  base cell 83 (pentagon)
    bc(8, 1, 0, 0, false, 0, 0), //   base cell 84
    bc(14, 0, 0, 0, false, 0, 0), //  base cell 85
    bc(9, 1, 0, 1, false, 0, 0), //   base cell 86
    bc(14, 0, 0, 1, false, 0, 0), //  base cell 87
    bc(17, 0, 0, 1, false, 0, 0), //  base cell 88
    bc(12, 0, 0, 1, false, 0, 0), //  base cell 89
    bc(16, 0, 0, 0, false, 0, 0), //  base cell 90
    bc(17, 0, 1, 1, false, 0, 0), //  base cell 91
    bc(15, 0, 0, 1, false, 0, 0), //  base cell 92
    bc(16, 1, 0, 1, false, 0, 0), //  base cell 93
    bc(9, 1, 0, 0, false, 0, 0), //   base cell 94
    bc(15, 0, 0, 0, false, 0, 0), //  base cell 95
    bc(13, 0, 0, 0, false, 0, 0), //  base cell 96
    bc(8, 2, 0, 0, true, 13, 17), //  base cell 97 (pentagon)
    bc(13, 0, 1, 0, false, 0, 0), //  base cell 98
    bc(17, 1, 0, 1, false, 0, 0), //  base cell 99
    bc(19, 0, 1, 0, false, 0, 0), //  base cell 100
    bc(14, 0, 1, 0, false, 0, 0), //  base cell 101
    bc(19, 0, 1, 1, false, 0, 0), //  base cell 102
    bc(17, 0, 1, 0, false, 0, 0), //  base cell 103
    bc(13, 0, 0, 1, false, 0, 0), //  base cell 104
    bc(17, 0, 0, 0, false, 0, 0), //  base cell 105
    bc(16, 1, 0, 0, false, 0, 0), //  base cell 106
    bc(9, 2, 0, 0, true, 14, 18), //  base cell 107 (pentagon)
    bc(15, 1, 0, 1, false, 0, 0), //  base cell 108
    bc(15, 1, 0, 0, false, 0, 0), //  base cell 109
    bc(18, 0, 1, 1, false, 0, 0), //  base cell 110
    bc(18, 0, 0, 1, false, 0, 0), //  base cell 111
    bc(19, 0, 0, 1, false, 0, 0), //  base cell 112
    bc(17, 1, 0, 0, false, 0, 0), //  base cell 113
    bc(19, 0, 0, 0, false, 0, 0), //  base cell 114
    bc(18, 0, 1, 0, false, 0, 0), //  base cell 115
    bc(18, 1, 0, 1, false, 0, 0), //  base cell 116
    bc(19, 2, 0, 0, true, -1, -1), // base cell 117 (pentagon)
    bc(19, 1, 0, 0, false, 0, 0), //  base cell 118
    bc(18, 0, 0, 0, false, 0, 0), //  base cell 119
    bc(19, 1, 0, 1, false, 0, 0), //  base cell 120
    bc(18, 1, 0, 0, false, 0, 0), //  base cell 121
};

comptime {
    std.debug.assert(baseCellData.len == 122);
}

// =============================================================================
// faceIjkBaseCells[20][3][3][3] — verbatim from libh3
//
// Stored flat as 540 entries. Index = face * 27 + i * 9 + j * 3 + k.
// =============================================================================

pub const faceIjkBaseCells = [_]BaseCellRotation{
    // 540 entries — face-major, row-major: [face*27 + i*9 + j*3 + k]
    .{ .base = 16, .ccw_rot = 0 },
    .{ .base = 18, .ccw_rot = 0 },
    .{ .base = 24, .ccw_rot = 0 },
    .{ .base = 33, .ccw_rot = 0 },
    .{ .base = 30, .ccw_rot = 0 },
    .{ .base = 32, .ccw_rot = 3 },
    .{ .base = 49, .ccw_rot = 1 },
    .{ .base = 48, .ccw_rot = 3 },
    .{ .base = 50, .ccw_rot = 3 },
    .{ .base = 8, .ccw_rot = 0 },
    .{ .base = 5, .ccw_rot = 5 },
    .{ .base = 10, .ccw_rot = 5 },
    .{ .base = 22, .ccw_rot = 0 },
    .{ .base = 16, .ccw_rot = 0 },
    .{ .base = 18, .ccw_rot = 0 },
    .{ .base = 41, .ccw_rot = 1 },
    .{ .base = 33, .ccw_rot = 0 },
    .{ .base = 30, .ccw_rot = 0 },
    .{ .base = 4, .ccw_rot = 0 },
    .{ .base = 0, .ccw_rot = 5 },
    .{ .base = 2, .ccw_rot = 5 },
    .{ .base = 15, .ccw_rot = 1 },
    .{ .base = 8, .ccw_rot = 0 },
    .{ .base = 5, .ccw_rot = 5 },
    .{ .base = 31, .ccw_rot = 1 },
    .{ .base = 22, .ccw_rot = 0 },
    .{ .base = 16, .ccw_rot = 0 },
    .{ .base = 2, .ccw_rot = 0 },
    .{ .base = 6, .ccw_rot = 0 },
    .{ .base = 14, .ccw_rot = 0 },
    .{ .base = 10, .ccw_rot = 0 },
    .{ .base = 11, .ccw_rot = 0 },
    .{ .base = 17, .ccw_rot = 3 },
    .{ .base = 24, .ccw_rot = 1 },
    .{ .base = 23, .ccw_rot = 3 },
    .{ .base = 25, .ccw_rot = 3 },
    .{ .base = 0, .ccw_rot = 0 },
    .{ .base = 1, .ccw_rot = 5 },
    .{ .base = 9, .ccw_rot = 5 },
    .{ .base = 5, .ccw_rot = 0 },
    .{ .base = 2, .ccw_rot = 0 },
    .{ .base = 6, .ccw_rot = 0 },
    .{ .base = 18, .ccw_rot = 1 },
    .{ .base = 10, .ccw_rot = 0 },
    .{ .base = 11, .ccw_rot = 0 },
    .{ .base = 4, .ccw_rot = 1 },
    .{ .base = 3, .ccw_rot = 5 },
    .{ .base = 7, .ccw_rot = 5 },
    .{ .base = 8, .ccw_rot = 1 },
    .{ .base = 0, .ccw_rot = 0 },
    .{ .base = 1, .ccw_rot = 5 },
    .{ .base = 16, .ccw_rot = 1 },
    .{ .base = 5, .ccw_rot = 0 },
    .{ .base = 2, .ccw_rot = 0 },
    .{ .base = 7, .ccw_rot = 0 },
    .{ .base = 21, .ccw_rot = 0 },
    .{ .base = 38, .ccw_rot = 0 },
    .{ .base = 9, .ccw_rot = 0 },
    .{ .base = 19, .ccw_rot = 0 },
    .{ .base = 34, .ccw_rot = 3 },
    .{ .base = 14, .ccw_rot = 1 },
    .{ .base = 20, .ccw_rot = 3 },
    .{ .base = 36, .ccw_rot = 3 },
    .{ .base = 3, .ccw_rot = 0 },
    .{ .base = 13, .ccw_rot = 5 },
    .{ .base = 29, .ccw_rot = 5 },
    .{ .base = 1, .ccw_rot = 0 },
    .{ .base = 7, .ccw_rot = 0 },
    .{ .base = 21, .ccw_rot = 0 },
    .{ .base = 6, .ccw_rot = 1 },
    .{ .base = 9, .ccw_rot = 0 },
    .{ .base = 19, .ccw_rot = 0 },
    .{ .base = 4, .ccw_rot = 2 },
    .{ .base = 12, .ccw_rot = 5 },
    .{ .base = 26, .ccw_rot = 5 },
    .{ .base = 0, .ccw_rot = 1 },
    .{ .base = 3, .ccw_rot = 0 },
    .{ .base = 13, .ccw_rot = 5 },
    .{ .base = 2, .ccw_rot = 1 },
    .{ .base = 1, .ccw_rot = 0 },
    .{ .base = 7, .ccw_rot = 0 },
    .{ .base = 26, .ccw_rot = 0 },
    .{ .base = 42, .ccw_rot = 0 },
    .{ .base = 58, .ccw_rot = 0 },
    .{ .base = 29, .ccw_rot = 0 },
    .{ .base = 43, .ccw_rot = 0 },
    .{ .base = 62, .ccw_rot = 3 },
    .{ .base = 38, .ccw_rot = 1 },
    .{ .base = 47, .ccw_rot = 3 },
    .{ .base = 64, .ccw_rot = 3 },
    .{ .base = 12, .ccw_rot = 0 },
    .{ .base = 28, .ccw_rot = 5 },
    .{ .base = 44, .ccw_rot = 5 },
    .{ .base = 13, .ccw_rot = 0 },
    .{ .base = 26, .ccw_rot = 0 },
    .{ .base = 42, .ccw_rot = 0 },
    .{ .base = 21, .ccw_rot = 1 },
    .{ .base = 29, .ccw_rot = 0 },
    .{ .base = 43, .ccw_rot = 0 },
    .{ .base = 4, .ccw_rot = 3 },
    .{ .base = 15, .ccw_rot = 5 },
    .{ .base = 31, .ccw_rot = 5 },
    .{ .base = 3, .ccw_rot = 1 },
    .{ .base = 12, .ccw_rot = 0 },
    .{ .base = 28, .ccw_rot = 5 },
    .{ .base = 7, .ccw_rot = 1 },
    .{ .base = 13, .ccw_rot = 0 },
    .{ .base = 26, .ccw_rot = 0 },
    .{ .base = 31, .ccw_rot = 0 },
    .{ .base = 41, .ccw_rot = 0 },
    .{ .base = 49, .ccw_rot = 0 },
    .{ .base = 44, .ccw_rot = 0 },
    .{ .base = 53, .ccw_rot = 0 },
    .{ .base = 61, .ccw_rot = 3 },
    .{ .base = 58, .ccw_rot = 1 },
    .{ .base = 65, .ccw_rot = 3 },
    .{ .base = 75, .ccw_rot = 3 },
    .{ .base = 15, .ccw_rot = 0 },
    .{ .base = 22, .ccw_rot = 5 },
    .{ .base = 33, .ccw_rot = 5 },
    .{ .base = 28, .ccw_rot = 0 },
    .{ .base = 31, .ccw_rot = 0 },
    .{ .base = 41, .ccw_rot = 0 },
    .{ .base = 42, .ccw_rot = 1 },
    .{ .base = 44, .ccw_rot = 0 },
    .{ .base = 53, .ccw_rot = 0 },
    .{ .base = 4, .ccw_rot = 4 },
    .{ .base = 8, .ccw_rot = 5 },
    .{ .base = 16, .ccw_rot = 5 },
    .{ .base = 12, .ccw_rot = 1 },
    .{ .base = 15, .ccw_rot = 0 },
    .{ .base = 22, .ccw_rot = 5 },
    .{ .base = 26, .ccw_rot = 1 },
    .{ .base = 28, .ccw_rot = 0 },
    .{ .base = 31, .ccw_rot = 0 },
    .{ .base = 50, .ccw_rot = 0 },
    .{ .base = 48, .ccw_rot = 0 },
    .{ .base = 49, .ccw_rot = 3 },
    .{ .base = 32, .ccw_rot = 0 },
    .{ .base = 30, .ccw_rot = 3 },
    .{ .base = 33, .ccw_rot = 3 },
    .{ .base = 24, .ccw_rot = 3 },
    .{ .base = 18, .ccw_rot = 3 },
    .{ .base = 16, .ccw_rot = 3 },
    .{ .base = 70, .ccw_rot = 0 },
    .{ .base = 67, .ccw_rot = 0 },
    .{ .base = 66, .ccw_rot = 3 },
    .{ .base = 52, .ccw_rot = 3 },
    .{ .base = 50, .ccw_rot = 0 },
    .{ .base = 48, .ccw_rot = 0 },
    .{ .base = 37, .ccw_rot = 3 },
    .{ .base = 32, .ccw_rot = 0 },
    .{ .base = 30, .ccw_rot = 3 },
    .{ .base = 83, .ccw_rot = 0 },
    .{ .base = 87, .ccw_rot = 3 },
    .{ .base = 85, .ccw_rot = 3 },
    .{ .base = 74, .ccw_rot = 3 },
    .{ .base = 70, .ccw_rot = 0 },
    .{ .base = 67, .ccw_rot = 0 },
    .{ .base = 57, .ccw_rot = 1 },
    .{ .base = 52, .ccw_rot = 3 },
    .{ .base = 50, .ccw_rot = 0 },
    .{ .base = 25, .ccw_rot = 0 },
    .{ .base = 23, .ccw_rot = 0 },
    .{ .base = 24, .ccw_rot = 3 },
    .{ .base = 17, .ccw_rot = 0 },
    .{ .base = 11, .ccw_rot = 3 },
    .{ .base = 10, .ccw_rot = 3 },
    .{ .base = 14, .ccw_rot = 3 },
    .{ .base = 6, .ccw_rot = 3 },
    .{ .base = 2, .ccw_rot = 3 },
    .{ .base = 45, .ccw_rot = 0 },
    .{ .base = 39, .ccw_rot = 0 },
    .{ .base = 37, .ccw_rot = 3 },
    .{ .base = 35, .ccw_rot = 3 },
    .{ .base = 25, .ccw_rot = 0 },
    .{ .base = 23, .ccw_rot = 0 },
    .{ .base = 27, .ccw_rot = 3 },
    .{ .base = 17, .ccw_rot = 0 },
    .{ .base = 11, .ccw_rot = 3 },
    .{ .base = 63, .ccw_rot = 0 },
    .{ .base = 59, .ccw_rot = 3 },
    .{ .base = 57, .ccw_rot = 3 },
    .{ .base = 56, .ccw_rot = 3 },
    .{ .base = 45, .ccw_rot = 0 },
    .{ .base = 39, .ccw_rot = 0 },
    .{ .base = 46, .ccw_rot = 3 },
    .{ .base = 35, .ccw_rot = 3 },
    .{ .base = 25, .ccw_rot = 0 },
    .{ .base = 36, .ccw_rot = 0 },
    .{ .base = 20, .ccw_rot = 0 },
    .{ .base = 14, .ccw_rot = 3 },
    .{ .base = 34, .ccw_rot = 0 },
    .{ .base = 19, .ccw_rot = 3 },
    .{ .base = 9, .ccw_rot = 3 },
    .{ .base = 38, .ccw_rot = 3 },
    .{ .base = 21, .ccw_rot = 3 },
    .{ .base = 7, .ccw_rot = 3 },
    .{ .base = 55, .ccw_rot = 0 },
    .{ .base = 40, .ccw_rot = 0 },
    .{ .base = 27, .ccw_rot = 3 },
    .{ .base = 54, .ccw_rot = 3 },
    .{ .base = 36, .ccw_rot = 0 },
    .{ .base = 20, .ccw_rot = 0 },
    .{ .base = 51, .ccw_rot = 3 },
    .{ .base = 34, .ccw_rot = 0 },
    .{ .base = 19, .ccw_rot = 3 },
    .{ .base = 72, .ccw_rot = 0 },
    .{ .base = 60, .ccw_rot = 3 },
    .{ .base = 46, .ccw_rot = 3 },
    .{ .base = 73, .ccw_rot = 3 },
    .{ .base = 55, .ccw_rot = 0 },
    .{ .base = 40, .ccw_rot = 0 },
    .{ .base = 71, .ccw_rot = 3 },
    .{ .base = 54, .ccw_rot = 3 },
    .{ .base = 36, .ccw_rot = 0 },
    .{ .base = 64, .ccw_rot = 0 },
    .{ .base = 47, .ccw_rot = 0 },
    .{ .base = 38, .ccw_rot = 3 },
    .{ .base = 62, .ccw_rot = 0 },
    .{ .base = 43, .ccw_rot = 3 },
    .{ .base = 29, .ccw_rot = 3 },
    .{ .base = 58, .ccw_rot = 3 },
    .{ .base = 42, .ccw_rot = 3 },
    .{ .base = 26, .ccw_rot = 3 },
    .{ .base = 84, .ccw_rot = 0 },
    .{ .base = 69, .ccw_rot = 0 },
    .{ .base = 51, .ccw_rot = 3 },
    .{ .base = 82, .ccw_rot = 3 },
    .{ .base = 64, .ccw_rot = 0 },
    .{ .base = 47, .ccw_rot = 0 },
    .{ .base = 76, .ccw_rot = 3 },
    .{ .base = 62, .ccw_rot = 0 },
    .{ .base = 43, .ccw_rot = 3 },
    .{ .base = 97, .ccw_rot = 0 },
    .{ .base = 89, .ccw_rot = 3 },
    .{ .base = 71, .ccw_rot = 3 },
    .{ .base = 98, .ccw_rot = 3 },
    .{ .base = 84, .ccw_rot = 0 },
    .{ .base = 69, .ccw_rot = 0 },
    .{ .base = 96, .ccw_rot = 3 },
    .{ .base = 82, .ccw_rot = 3 },
    .{ .base = 64, .ccw_rot = 0 },
    .{ .base = 75, .ccw_rot = 0 },
    .{ .base = 65, .ccw_rot = 0 },
    .{ .base = 58, .ccw_rot = 3 },
    .{ .base = 61, .ccw_rot = 0 },
    .{ .base = 53, .ccw_rot = 3 },
    .{ .base = 44, .ccw_rot = 3 },
    .{ .base = 49, .ccw_rot = 3 },
    .{ .base = 41, .ccw_rot = 3 },
    .{ .base = 31, .ccw_rot = 3 },
    .{ .base = 94, .ccw_rot = 0 },
    .{ .base = 86, .ccw_rot = 0 },
    .{ .base = 76, .ccw_rot = 3 },
    .{ .base = 81, .ccw_rot = 3 },
    .{ .base = 75, .ccw_rot = 0 },
    .{ .base = 65, .ccw_rot = 0 },
    .{ .base = 66, .ccw_rot = 3 },
    .{ .base = 61, .ccw_rot = 0 },
    .{ .base = 53, .ccw_rot = 3 },
    .{ .base = 107, .ccw_rot = 0 },
    .{ .base = 104, .ccw_rot = 3 },
    .{ .base = 96, .ccw_rot = 3 },
    .{ .base = 101, .ccw_rot = 3 },
    .{ .base = 94, .ccw_rot = 0 },
    .{ .base = 86, .ccw_rot = 0 },
    .{ .base = 85, .ccw_rot = 3 },
    .{ .base = 81, .ccw_rot = 3 },
    .{ .base = 75, .ccw_rot = 0 },
    .{ .base = 57, .ccw_rot = 0 },
    .{ .base = 59, .ccw_rot = 0 },
    .{ .base = 63, .ccw_rot = 3 },
    .{ .base = 74, .ccw_rot = 0 },
    .{ .base = 78, .ccw_rot = 3 },
    .{ .base = 79, .ccw_rot = 3 },
    .{ .base = 83, .ccw_rot = 3 },
    .{ .base = 92, .ccw_rot = 3 },
    .{ .base = 95, .ccw_rot = 3 },
    .{ .base = 37, .ccw_rot = 0 },
    .{ .base = 39, .ccw_rot = 3 },
    .{ .base = 45, .ccw_rot = 3 },
    .{ .base = 52, .ccw_rot = 0 },
    .{ .base = 57, .ccw_rot = 0 },
    .{ .base = 59, .ccw_rot = 0 },
    .{ .base = 70, .ccw_rot = 3 },
    .{ .base = 74, .ccw_rot = 0 },
    .{ .base = 78, .ccw_rot = 3 },
    .{ .base = 24, .ccw_rot = 0 },
    .{ .base = 23, .ccw_rot = 3 },
    .{ .base = 25, .ccw_rot = 3 },
    .{ .base = 32, .ccw_rot = 3 },
    .{ .base = 37, .ccw_rot = 0 },
    .{ .base = 39, .ccw_rot = 3 },
    .{ .base = 50, .ccw_rot = 3 },
    .{ .base = 52, .ccw_rot = 0 },
    .{ .base = 57, .ccw_rot = 0 },
    .{ .base = 46, .ccw_rot = 0 },
    .{ .base = 60, .ccw_rot = 0 },
    .{ .base = 72, .ccw_rot = 3 },
    .{ .base = 56, .ccw_rot = 0 },
    .{ .base = 68, .ccw_rot = 3 },
    .{ .base = 80, .ccw_rot = 3 },
    .{ .base = 63, .ccw_rot = 3 },
    .{ .base = 77, .ccw_rot = 3 },
    .{ .base = 90, .ccw_rot = 3 },
    .{ .base = 27, .ccw_rot = 0 },
    .{ .base = 40, .ccw_rot = 3 },
    .{ .base = 55, .ccw_rot = 3 },
    .{ .base = 35, .ccw_rot = 0 },
    .{ .base = 46, .ccw_rot = 0 },
    .{ .base = 60, .ccw_rot = 0 },
    .{ .base = 45, .ccw_rot = 3 },
    .{ .base = 56, .ccw_rot = 0 },
    .{ .base = 68, .ccw_rot = 3 },
    .{ .base = 14, .ccw_rot = 0 },
    .{ .base = 20, .ccw_rot = 3 },
    .{ .base = 36, .ccw_rot = 3 },
    .{ .base = 17, .ccw_rot = 3 },
    .{ .base = 27, .ccw_rot = 0 },
    .{ .base = 40, .ccw_rot = 3 },
    .{ .base = 25, .ccw_rot = 3 },
    .{ .base = 35, .ccw_rot = 0 },
    .{ .base = 46, .ccw_rot = 0 },
    .{ .base = 71, .ccw_rot = 0 },
    .{ .base = 89, .ccw_rot = 0 },
    .{ .base = 97, .ccw_rot = 3 },
    .{ .base = 73, .ccw_rot = 0 },
    .{ .base = 91, .ccw_rot = 3 },
    .{ .base = 103, .ccw_rot = 3 },
    .{ .base = 72, .ccw_rot = 3 },
    .{ .base = 88, .ccw_rot = 3 },
    .{ .base = 105, .ccw_rot = 3 },
    .{ .base = 51, .ccw_rot = 0 },
    .{ .base = 69, .ccw_rot = 3 },
    .{ .base = 84, .ccw_rot = 3 },
    .{ .base = 54, .ccw_rot = 0 },
    .{ .base = 71, .ccw_rot = 0 },
    .{ .base = 89, .ccw_rot = 0 },
    .{ .base = 55, .ccw_rot = 3 },
    .{ .base = 73, .ccw_rot = 0 },
    .{ .base = 91, .ccw_rot = 3 },
    .{ .base = 38, .ccw_rot = 0 },
    .{ .base = 47, .ccw_rot = 3 },
    .{ .base = 64, .ccw_rot = 3 },
    .{ .base = 34, .ccw_rot = 3 },
    .{ .base = 51, .ccw_rot = 0 },
    .{ .base = 69, .ccw_rot = 3 },
    .{ .base = 36, .ccw_rot = 3 },
    .{ .base = 54, .ccw_rot = 0 },
    .{ .base = 71, .ccw_rot = 0 },
    .{ .base = 96, .ccw_rot = 0 },
    .{ .base = 104, .ccw_rot = 0 },
    .{ .base = 107, .ccw_rot = 3 },
    .{ .base = 98, .ccw_rot = 0 },
    .{ .base = 110, .ccw_rot = 3 },
    .{ .base = 115, .ccw_rot = 3 },
    .{ .base = 97, .ccw_rot = 3 },
    .{ .base = 111, .ccw_rot = 3 },
    .{ .base = 119, .ccw_rot = 3 },
    .{ .base = 76, .ccw_rot = 0 },
    .{ .base = 86, .ccw_rot = 3 },
    .{ .base = 94, .ccw_rot = 3 },
    .{ .base = 82, .ccw_rot = 0 },
    .{ .base = 96, .ccw_rot = 0 },
    .{ .base = 104, .ccw_rot = 0 },
    .{ .base = 84, .ccw_rot = 3 },
    .{ .base = 98, .ccw_rot = 0 },
    .{ .base = 110, .ccw_rot = 3 },
    .{ .base = 58, .ccw_rot = 0 },
    .{ .base = 65, .ccw_rot = 3 },
    .{ .base = 75, .ccw_rot = 3 },
    .{ .base = 62, .ccw_rot = 3 },
    .{ .base = 76, .ccw_rot = 0 },
    .{ .base = 86, .ccw_rot = 3 },
    .{ .base = 64, .ccw_rot = 3 },
    .{ .base = 82, .ccw_rot = 0 },
    .{ .base = 96, .ccw_rot = 0 },
    .{ .base = 85, .ccw_rot = 0 },
    .{ .base = 87, .ccw_rot = 0 },
    .{ .base = 83, .ccw_rot = 3 },
    .{ .base = 101, .ccw_rot = 0 },
    .{ .base = 102, .ccw_rot = 3 },
    .{ .base = 100, .ccw_rot = 3 },
    .{ .base = 107, .ccw_rot = 3 },
    .{ .base = 112, .ccw_rot = 3 },
    .{ .base = 114, .ccw_rot = 3 },
    .{ .base = 66, .ccw_rot = 0 },
    .{ .base = 67, .ccw_rot = 3 },
    .{ .base = 70, .ccw_rot = 3 },
    .{ .base = 81, .ccw_rot = 0 },
    .{ .base = 85, .ccw_rot = 0 },
    .{ .base = 87, .ccw_rot = 0 },
    .{ .base = 94, .ccw_rot = 3 },
    .{ .base = 101, .ccw_rot = 0 },
    .{ .base = 102, .ccw_rot = 3 },
    .{ .base = 49, .ccw_rot = 0 },
    .{ .base = 48, .ccw_rot = 3 },
    .{ .base = 50, .ccw_rot = 3 },
    .{ .base = 61, .ccw_rot = 3 },
    .{ .base = 66, .ccw_rot = 0 },
    .{ .base = 67, .ccw_rot = 3 },
    .{ .base = 75, .ccw_rot = 3 },
    .{ .base = 81, .ccw_rot = 0 },
    .{ .base = 85, .ccw_rot = 0 },
    .{ .base = 95, .ccw_rot = 0 },
    .{ .base = 92, .ccw_rot = 0 },
    .{ .base = 83, .ccw_rot = 0 },
    .{ .base = 79, .ccw_rot = 0 },
    .{ .base = 78, .ccw_rot = 0 },
    .{ .base = 74, .ccw_rot = 3 },
    .{ .base = 63, .ccw_rot = 1 },
    .{ .base = 59, .ccw_rot = 3 },
    .{ .base = 57, .ccw_rot = 3 },
    .{ .base = 109, .ccw_rot = 0 },
    .{ .base = 108, .ccw_rot = 0 },
    .{ .base = 100, .ccw_rot = 5 },
    .{ .base = 93, .ccw_rot = 1 },
    .{ .base = 95, .ccw_rot = 0 },
    .{ .base = 92, .ccw_rot = 0 },
    .{ .base = 77, .ccw_rot = 1 },
    .{ .base = 79, .ccw_rot = 0 },
    .{ .base = 78, .ccw_rot = 0 },
    .{ .base = 117, .ccw_rot = 4 },
    .{ .base = 118, .ccw_rot = 5 },
    .{ .base = 114, .ccw_rot = 5 },
    .{ .base = 106, .ccw_rot = 1 },
    .{ .base = 109, .ccw_rot = 0 },
    .{ .base = 108, .ccw_rot = 0 },
    .{ .base = 90, .ccw_rot = 1 },
    .{ .base = 93, .ccw_rot = 1 },
    .{ .base = 95, .ccw_rot = 0 },
    .{ .base = 90, .ccw_rot = 0 },
    .{ .base = 77, .ccw_rot = 0 },
    .{ .base = 63, .ccw_rot = 0 },
    .{ .base = 80, .ccw_rot = 0 },
    .{ .base = 68, .ccw_rot = 0 },
    .{ .base = 56, .ccw_rot = 3 },
    .{ .base = 72, .ccw_rot = 1 },
    .{ .base = 60, .ccw_rot = 3 },
    .{ .base = 46, .ccw_rot = 3 },
    .{ .base = 106, .ccw_rot = 0 },
    .{ .base = 93, .ccw_rot = 0 },
    .{ .base = 79, .ccw_rot = 5 },
    .{ .base = 99, .ccw_rot = 1 },
    .{ .base = 90, .ccw_rot = 0 },
    .{ .base = 77, .ccw_rot = 0 },
    .{ .base = 88, .ccw_rot = 1 },
    .{ .base = 80, .ccw_rot = 0 },
    .{ .base = 68, .ccw_rot = 0 },
    .{ .base = 117, .ccw_rot = 3 },
    .{ .base = 109, .ccw_rot = 5 },
    .{ .base = 95, .ccw_rot = 5 },
    .{ .base = 113, .ccw_rot = 1 },
    .{ .base = 106, .ccw_rot = 0 },
    .{ .base = 93, .ccw_rot = 0 },
    .{ .base = 105, .ccw_rot = 1 },
    .{ .base = 99, .ccw_rot = 1 },
    .{ .base = 90, .ccw_rot = 0 },
    .{ .base = 105, .ccw_rot = 0 },
    .{ .base = 88, .ccw_rot = 0 },
    .{ .base = 72, .ccw_rot = 0 },
    .{ .base = 103, .ccw_rot = 0 },
    .{ .base = 91, .ccw_rot = 0 },
    .{ .base = 73, .ccw_rot = 3 },
    .{ .base = 97, .ccw_rot = 1 },
    .{ .base = 89, .ccw_rot = 3 },
    .{ .base = 71, .ccw_rot = 3 },
    .{ .base = 113, .ccw_rot = 0 },
    .{ .base = 99, .ccw_rot = 0 },
    .{ .base = 80, .ccw_rot = 5 },
    .{ .base = 116, .ccw_rot = 1 },
    .{ .base = 105, .ccw_rot = 0 },
    .{ .base = 88, .ccw_rot = 0 },
    .{ .base = 111, .ccw_rot = 1 },
    .{ .base = 103, .ccw_rot = 0 },
    .{ .base = 91, .ccw_rot = 0 },
    .{ .base = 117, .ccw_rot = 2 },
    .{ .base = 106, .ccw_rot = 5 },
    .{ .base = 90, .ccw_rot = 5 },
    .{ .base = 121, .ccw_rot = 1 },
    .{ .base = 113, .ccw_rot = 0 },
    .{ .base = 99, .ccw_rot = 0 },
    .{ .base = 119, .ccw_rot = 1 },
    .{ .base = 116, .ccw_rot = 1 },
    .{ .base = 105, .ccw_rot = 0 },
    .{ .base = 119, .ccw_rot = 0 },
    .{ .base = 111, .ccw_rot = 0 },
    .{ .base = 97, .ccw_rot = 0 },
    .{ .base = 115, .ccw_rot = 0 },
    .{ .base = 110, .ccw_rot = 0 },
    .{ .base = 98, .ccw_rot = 3 },
    .{ .base = 107, .ccw_rot = 1 },
    .{ .base = 104, .ccw_rot = 3 },
    .{ .base = 96, .ccw_rot = 3 },
    .{ .base = 121, .ccw_rot = 0 },
    .{ .base = 116, .ccw_rot = 0 },
    .{ .base = 103, .ccw_rot = 5 },
    .{ .base = 120, .ccw_rot = 1 },
    .{ .base = 119, .ccw_rot = 0 },
    .{ .base = 111, .ccw_rot = 0 },
    .{ .base = 112, .ccw_rot = 1 },
    .{ .base = 115, .ccw_rot = 0 },
    .{ .base = 110, .ccw_rot = 0 },
    .{ .base = 117, .ccw_rot = 1 },
    .{ .base = 113, .ccw_rot = 5 },
    .{ .base = 105, .ccw_rot = 5 },
    .{ .base = 118, .ccw_rot = 1 },
    .{ .base = 121, .ccw_rot = 0 },
    .{ .base = 116, .ccw_rot = 0 },
    .{ .base = 114, .ccw_rot = 1 },
    .{ .base = 120, .ccw_rot = 1 },
    .{ .base = 119, .ccw_rot = 0 },
    .{ .base = 114, .ccw_rot = 0 },
    .{ .base = 112, .ccw_rot = 0 },
    .{ .base = 107, .ccw_rot = 0 },
    .{ .base = 100, .ccw_rot = 0 },
    .{ .base = 102, .ccw_rot = 0 },
    .{ .base = 101, .ccw_rot = 3 },
    .{ .base = 83, .ccw_rot = 1 },
    .{ .base = 87, .ccw_rot = 3 },
    .{ .base = 85, .ccw_rot = 3 },
    .{ .base = 118, .ccw_rot = 0 },
    .{ .base = 120, .ccw_rot = 0 },
    .{ .base = 115, .ccw_rot = 5 },
    .{ .base = 108, .ccw_rot = 1 },
    .{ .base = 114, .ccw_rot = 0 },
    .{ .base = 112, .ccw_rot = 0 },
    .{ .base = 92, .ccw_rot = 1 },
    .{ .base = 100, .ccw_rot = 0 },
    .{ .base = 102, .ccw_rot = 0 },
    .{ .base = 117, .ccw_rot = 0 },
    .{ .base = 121, .ccw_rot = 5 },
    .{ .base = 119, .ccw_rot = 5 },
    .{ .base = 109, .ccw_rot = 1 },
    .{ .base = 118, .ccw_rot = 0 },
    .{ .base = 120, .ccw_rot = 0 },
    .{ .base = 95, .ccw_rot = 1 },
    .{ .base = 108, .ccw_rot = 1 },
    .{ .base = 114, .ccw_rot = 0 },
};

comptime {
    std.debug.assert(faceIjkBaseCells.len == 540);
}

inline fn faceIjkLookup(face: i32, i: i32, j: i32, k: i32) BaseCellRotation {
    const idx = @as(usize, @intCast(face)) * 27 +
        @as(usize, @intCast(i)) * 9 +
        @as(usize, @intCast(j)) * 3 +
        @as(usize, @intCast(k));
    return faceIjkBaseCells[idx];
}

// =============================================================================
// Base cell lookups
// =============================================================================

pub fn faceIjkToBaseCell(h: FaceIJK) i32 {
    return faceIjkLookup(h.face, h.coord.i, h.coord.j, h.coord.k).base;
}

pub fn faceIjkToBaseCellCCWrot60(h: FaceIJK) i32 {
    return faceIjkLookup(h.face, h.coord.i, h.coord.j, h.coord.k).ccw_rot;
}

pub fn isBaseCellPentagon(base_cell: i32) bool {
    if (base_cell < 0 or base_cell >= NUM_BASE_CELLS) return false;
    return baseCellData[@intCast(base_cell)].is_pentagon;
}

pub fn baseCellIsCwOffset(base_cell: i32, test_face: i32) bool {
    const bcd = baseCellData[@intCast(base_cell)];
    return bcd.cw_offset[0] == test_face or bcd.cw_offset[1] == test_face;
}

// =============================================================================
// IJK arithmetic (libh3 coordijk.c)
// =============================================================================

pub fn ijkAdd(a: CoordIJK, b: CoordIJK) CoordIJK {
    return .{ .i = a.i + b.i, .j = a.j + b.j, .k = a.k + b.k };
}

pub fn ijkSub(a: CoordIJK, b: CoordIJK) CoordIJK {
    return .{ .i = a.i - b.i, .j = a.j - b.j, .k = a.k - b.k };
}

pub fn ijkScale(c: *CoordIJK, factor: i32) void {
    c.i *= factor;
    c.j *= factor;
    c.k *= factor;
}

pub fn ijkMatches(a: CoordIJK, b: CoordIJK) bool {
    return a.i == b.i and a.j == b.j and a.k == b.k;
}

pub fn unitIjkToDigit(ijk: CoordIJK) Direction {
    var c = ijk;
    proj.ijkNormalize(&c);
    for (UNIT_VECS, 0..) |uv, i| {
        if (ijkMatches(c, uv)) return @enumFromInt(i);
    }
    return .invalid;
}

// =============================================================================
// Aperture-7 hierarchy (CCW and CW variants)
// =============================================================================

fn lroundf(x: f64) i32 {
    return @intFromFloat(@round(x));
}

pub fn upAp7(ijk: *CoordIJK) void {
    const i = ijk.i - ijk.k;
    const j = ijk.j - ijk.k;
    ijk.i = lroundf((3.0 * @as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(j))) / 7.0);
    ijk.j = lroundf((@as(f64, @floatFromInt(i)) + 2.0 * @as(f64, @floatFromInt(j))) / 7.0);
    ijk.k = 0;
    proj.ijkNormalize(ijk);
}

pub fn upAp7r(ijk: *CoordIJK) void {
    const i = ijk.i - ijk.k;
    const j = ijk.j - ijk.k;
    ijk.i = lroundf((2.0 * @as(f64, @floatFromInt(i)) + @as(f64, @floatFromInt(j))) / 7.0);
    ijk.j = lroundf((3.0 * @as(f64, @floatFromInt(j)) - @as(f64, @floatFromInt(i))) / 7.0);
    ijk.k = 0;
    proj.ijkNormalize(ijk);
}

pub fn downAp7(ijk: *CoordIJK) void {
    var iVec = CoordIJK{ .i = 3, .j = 0, .k = 1 };
    var jVec = CoordIJK{ .i = 1, .j = 3, .k = 0 };
    var kVec = CoordIJK{ .i = 0, .j = 1, .k = 3 };
    ijkScale(&iVec, ijk.i);
    ijkScale(&jVec, ijk.j);
    ijkScale(&kVec, ijk.k);
    const sum1 = ijkAdd(iVec, jVec);
    ijk.* = ijkAdd(sum1, kVec);
    proj.ijkNormalize(ijk);
}

pub fn downAp7r(ijk: *CoordIJK) void {
    var iVec = CoordIJK{ .i = 3, .j = 1, .k = 0 };
    var jVec = CoordIJK{ .i = 0, .j = 3, .k = 1 };
    var kVec = CoordIJK{ .i = 1, .j = 0, .k = 3 };
    ijkScale(&iVec, ijk.i);
    ijkScale(&jVec, ijk.j);
    ijkScale(&kVec, ijk.k);
    const sum1 = ijkAdd(iVec, jVec);
    ijk.* = ijkAdd(sum1, kVec);
    proj.ijkNormalize(ijk);
}

// =============================================================================
// Coord rotations (60° CCW / CW)
// =============================================================================

pub fn ijkRotate60ccw(ijk: *CoordIJK) void {
    var iVec = CoordIJK{ .i = 1, .j = 1, .k = 0 };
    var jVec = CoordIJK{ .i = 0, .j = 1, .k = 1 };
    var kVec = CoordIJK{ .i = 1, .j = 0, .k = 1 };
    ijkScale(&iVec, ijk.i);
    ijkScale(&jVec, ijk.j);
    ijkScale(&kVec, ijk.k);
    const sum1 = ijkAdd(iVec, jVec);
    ijk.* = ijkAdd(sum1, kVec);
    proj.ijkNormalize(ijk);
}

pub fn ijkRotate60cw(ijk: *CoordIJK) void {
    var iVec = CoordIJK{ .i = 1, .j = 0, .k = 1 };
    var jVec = CoordIJK{ .i = 1, .j = 1, .k = 0 };
    var kVec = CoordIJK{ .i = 0, .j = 1, .k = 1 };
    ijkScale(&iVec, ijk.i);
    ijkScale(&jVec, ijk.j);
    ijkScale(&kVec, ijk.k);
    const sum1 = ijkAdd(iVec, jVec);
    ijk.* = ijkAdd(sum1, kVec);
    proj.ijkNormalize(ijk);
}

pub fn rotate60ccw(digit: Direction) Direction {
    return switch (digit) {
        .k_axes => .ik_axes,
        .ik_axes => .i_axes,
        .i_axes => .ij_axes,
        .ij_axes => .j_axes,
        .j_axes => .jk_axes,
        .jk_axes => .k_axes,
        else => digit, // CENTER and INVALID are fixed points
    };
}

pub fn rotate60cw(digit: Direction) Direction {
    return switch (digit) {
        .k_axes => .jk_axes,
        .jk_axes => .j_axes,
        .j_axes => .ij_axes,
        .ij_axes => .i_axes,
        .i_axes => .ik_axes,
        .ik_axes => .k_axes,
        else => digit,
    };
}

// =============================================================================
// H3 index bit-level operations
// =============================================================================

const H3_MODE_OFFSET: u6 = 59;
const H3_RES_OFFSET: u6 = 52;
const H3_BC_OFFSET: u6 = 45;
const H3_DIGIT_MASK: u64 = 7;
const H3_PER_DIGIT_OFFSET: u6 = 3;
pub const H3_INIT: H3Index = 0x0000_1FFF_FFFF_FFFF;
pub const CELL_MODE: u4 = 1;

inline fn setMode(h: H3Index, mode: u4) H3Index {
    return (h & ~(@as(H3Index, 0xF) << H3_MODE_OFFSET)) | (@as(H3Index, mode) << H3_MODE_OFFSET);
}

inline fn setResolution(h: H3Index, res: i32) H3Index {
    return (h & ~(@as(H3Index, 0xF) << H3_RES_OFFSET)) | (@as(H3Index, @intCast(res)) << H3_RES_OFFSET);
}

inline fn setBaseCell(h: H3Index, bc_: i32) H3Index {
    return (h & ~(@as(H3Index, 0x7F) << H3_BC_OFFSET)) | (@as(H3Index, @intCast(bc_)) << H3_BC_OFFSET);
}

inline fn setIndexDigit(h: H3Index, res: i32, digit: Direction) H3Index {
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * @as(i32, H3_PER_DIGIT_OFFSET));
    return (h & ~(H3_DIGIT_MASK << shift)) | (@as(H3Index, @intFromEnum(digit)) << shift);
}

inline fn getIndexDigit(h: H3Index, res: i32) Direction {
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * @as(i32, H3_PER_DIGIT_OFFSET));
    return @enumFromInt(@as(u3, @intCast((h >> shift) & H3_DIGIT_MASK)));
}

inline fn getResolution(h: H3Index) i32 {
    return @intCast((h >> H3_RES_OFFSET) & 0xF);
}

pub fn h3LeadingNonZeroDigit(h: H3Index) Direction {
    const res = getResolution(h);
    var r: i32 = 1;
    while (r <= res) : (r += 1) {
        const d = getIndexDigit(h, r);
        if (d != .center) return d;
    }
    return .center;
}

pub fn h3Rotate60ccw(h_in: H3Index) H3Index {
    var h = h_in;
    const res = getResolution(h);
    var r: i32 = 1;
    while (r <= res) : (r += 1) {
        h = setIndexDigit(h, r, rotate60ccw(getIndexDigit(h, r)));
    }
    return h;
}

pub fn h3Rotate60cw(h_in: H3Index) H3Index {
    var h = h_in;
    const res = getResolution(h);
    var r: i32 = 1;
    while (r <= res) : (r += 1) {
        h = setIndexDigit(h, r, rotate60cw(getIndexDigit(h, r)));
    }
    return h;
}

pub fn h3RotatePent60ccw(h_in: H3Index) H3Index {
    var h = h_in;
    var found_first_nonzero = false;
    const res = getResolution(h);
    var r: i32 = 1;
    while (r <= res) : (r += 1) {
        h = setIndexDigit(h, r, rotate60ccw(getIndexDigit(h, r)));
        if (!found_first_nonzero and getIndexDigit(h, r) != .center) {
            found_first_nonzero = true;
            if (h3LeadingNonZeroDigit(h) == .k_axes) {
                h = h3Rotate60ccw(h);
            }
        }
    }
    return h;
}

pub fn h3RotatePent60cw(h_in: H3Index) H3Index {
    var h = h_in;
    var found_first_nonzero = false;
    const res = getResolution(h);
    var r: i32 = 1;
    while (r <= res) : (r += 1) {
        h = setIndexDigit(h, r, rotate60cw(getIndexDigit(h, r)));
        if (!found_first_nonzero and getIndexDigit(h, r) != .center) {
            found_first_nonzero = true;
            if (h3LeadingNonZeroDigit(h) == .k_axes) {
                h = h3Rotate60cw(h);
            }
        }
    }
    return h;
}

// =============================================================================
// _faceIjkToH3 — the core encoder
// =============================================================================

fn isClassIII(res: i32) bool {
    return (@mod(res, 2)) == 1;
}

pub fn faceIjkToH3(fijk_in: FaceIJK, res: i32) H3Index {
    var h: H3Index = H3_INIT;
    h = setMode(h, CELL_MODE);
    h = setResolution(h, res);

    if (res == 0) {
        if (fijk_in.coord.i > MAX_FACE_COORD or
            fijk_in.coord.j > MAX_FACE_COORD or
            fijk_in.coord.k > MAX_FACE_COORD)
        {
            return 0;
        }
        h = setBaseCell(h, faceIjkToBaseCell(fijk_in));
        return h;
    }

    var fijk_bc = fijk_in;
    const ijk = &fijk_bc.coord;

    // Walk up from finest resolution to base cell, recording the digit at each step.
    var r: i32 = res - 1;
    while (r >= 0) : (r -= 1) {
        const last_ijk = ijk.*;
        var last_center: CoordIJK = undefined;
        if (isClassIII(r + 1)) {
            upAp7(ijk);
            last_center = ijk.*;
            downAp7(&last_center);
        } else {
            upAp7r(ijk);
            last_center = ijk.*;
            downAp7r(&last_center);
        }
        var diff = ijkSub(last_ijk, last_center);
        proj.ijkNormalize(&diff);
        h = setIndexDigit(h, r + 1, unitIjkToDigit(diff));
    }

    if (fijk_bc.coord.i > MAX_FACE_COORD or
        fijk_bc.coord.j > MAX_FACE_COORD or
        fijk_bc.coord.k > MAX_FACE_COORD)
    {
        return 0;
    }

    const base_cell = faceIjkToBaseCell(fijk_bc);
    h = setBaseCell(h, base_cell);

    const num_rots = faceIjkToBaseCellCCWrot60(fijk_bc);
    if (isBaseCellPentagon(base_cell)) {
        if (h3LeadingNonZeroDigit(h) == .k_axes) {
            if (baseCellIsCwOffset(base_cell, fijk_bc.face)) {
                h = h3Rotate60cw(h);
            } else {
                h = h3Rotate60ccw(h);
            }
        }
        var i: i32 = 0;
        while (i < num_rots) : (i += 1) h = h3RotatePent60ccw(h);
    } else {
        var i: i32 = 0;
        while (i < num_rots) : (i += 1) h = h3Rotate60ccw(h);
    }

    return h;
}

// =============================================================================
// Public API: latLngToCell
// =============================================================================

pub fn latLngToCell(point: LatLng, res: i32) Error!H3Index {
    if (res < 0 or res > MAX_RES) return Error.ResolutionDomain;
    if (!std.math.isFinite(point.lat) or !std.math.isFinite(point.lng)) {
        return Error.LatLngDomain;
    }

    // _geoToFaceIjk is just geoToHex2d + hex2dToCoordIJK
    const h2 = proj.geoToHex2d(point, res);
    const ijk = proj.hex2dToCoordIJK(h2.v);
    const fijk = FaceIJK{ .face = h2.face, .coord = ijk };

    const out = faceIjkToH3(fijk, res);
    if (out == 0) return Error.Failed;
    return out;
}

// =============================================================================
// Cross-validation tests against libh3 (via root.latLngToCell)
// =============================================================================

const testing = std.testing;

test "pure latLngToCell matches libh3 on hand-picked landmark points across all resolutions" {
    const landmarks = [_]LatLng{
        LatLng.fromDegrees(40.6892, -74.0445), // Statue of Liberty
        LatLng.fromDegrees(37.7749, -122.4194), // San Francisco
        LatLng.fromDegrees(51.5074, -0.1278), // London
        LatLng.fromDegrees(35.6762, 139.6503), // Tokyo
        LatLng.fromDegrees(-33.8688, 151.2093), // Sydney
        LatLng.fromDegrees(0.0, 0.0), // null island
        LatLng.fromDegrees(89.0, 0.0), // near north pole
        LatLng.fromDegrees(-89.0, 0.0), // near south pole
    };

    for (landmarks) |point| {
        var res: i32 = 0;
        while (res <= MAX_RES) : (res += 1) {
            const theirs = try root.latLngToCell(point, res);
            const ours = try latLngToCell(point, res);
            try testing.expectEqual(theirs, ours);
        }
    }
}

test "pure latLngToCell matches libh3 on random points at every resolution" {
    var rng = std.Random.DefaultPrng.init(0xCAFEBABE_DEADBEEF);
    var res: i32 = 0;
    while (res <= MAX_RES) : (res += 1) {
        for (0..50) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const point = LatLng.fromDegrees(lat, lng);
            const theirs = try root.latLngToCell(point, res);
            const ours = try latLngToCell(point, res);
            try testing.expectEqual(theirs, ours);
        }
    }
}

test "pure latLngToCell rejects out-of-range resolution" {
    const p = LatLng.fromDegrees(40.0, -74.0);
    try testing.expectError(Error.ResolutionDomain, latLngToCell(p, -1));
    try testing.expectError(Error.ResolutionDomain, latLngToCell(p, 16));
}

test "pure latLngToCell rejects non-finite input" {
    const inf = LatLng{ .lat = std.math.inf(f64), .lng = 0.0 };
    const nan = LatLng{ .lat = std.math.nan(f64), .lng = 0.0 };
    try testing.expectError(Error.LatLngDomain, latLngToCell(inf, 5));
    try testing.expectError(Error.LatLngDomain, latLngToCell(nan, 5));
}

test "pure latLngToCell agrees with libh3 near every icosahedron face center" {
    for (proj.faceCenterGeo) |center| {
        var res: i32 = 0;
        while (res <= MAX_RES) : (res += 1) {
            const theirs = try root.latLngToCell(center, res);
            const ours = try latLngToCell(center, res);
            try testing.expectEqual(theirs, ours);
        }
    }
}

test "pure latLngToCell at res 0 produces only valid base cells" {
    var rng = std.Random.DefaultPrng.init(0xBC0_5EED);
    for (0..200) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const cell = try latLngToCell(LatLng.fromDegrees(lat, lng), 0);
        // Decode the base cell number from the H3Index.
        const bc_num: i32 = @intCast((cell >> H3_BC_OFFSET) & 0x7F);
        try testing.expect(bc_num >= 0 and bc_num < NUM_BASE_CELLS);
    }
}
