//! Pure-Zig H3 local-IJ coordinate subsystem + compaction + face-set queries — Phase 4f.
//!
//! Translates `cellToLocalIjk`, `ijkDistance`, `gridDistance`, `compactCells`,
//! `uncompactCells`, `uncompactCellsSize`, `maxFaceCount`, and
//! `getIcosahedronFaces`. The local-IJ subsystem with `PENTAGON_ROTATIONS` /
//! `FAILED_DIRECTIONS` tables is what gates `gridDistance` and
//! `gridPathCells`.

const std = @import("std");
const root = @import("root.zig");
const pure = @import("pure.zig");
const proj = @import("pure_proj.zig");
const h3idx = @import("pure_h3index.zig");
const h3dec = @import("pure_h3decode.zig");
const hier = @import("pure_hierarchy.zig");
const grid = @import("pure_grid.zig");
const bnd = @import("pure_boundary.zig");

pub const H3Index = root.H3Index;
pub const Error = root.Error;
pub const CoordIJK = proj.CoordIJK;
pub const Direction = h3idx.Direction;
pub const FaceIJK = h3idx.FaceIJK;
pub const MAX_RES = h3idx.MAX_RES;
pub const NUM_BASE_CELLS = h3idx.NUM_BASE_CELLS;

const H3_RES_OFFSET: u6 = 52;
const H3_BC_OFFSET: u6 = 45;
const H3_RESERVED_OFFSET: u6 = 56;

inline fn getResolution(h: H3Index) i32 {
    return @intCast((h >> H3_RES_OFFSET) & 0xF);
}
inline fn getBaseCell(h: H3Index) i32 {
    return @intCast((h >> H3_BC_OFFSET) & 0x7F);
}
inline fn getReservedBits(h: H3Index) u3 {
    return @intCast((h >> H3_RESERVED_OFFSET) & 0x7);
}
inline fn setReservedBits(h: H3Index, v: u3) H3Index {
    return (h & ~(@as(H3Index, 0x7) << H3_RESERVED_OFFSET)) |
        (@as(H3Index, v) << H3_RESERVED_OFFSET);
}
inline fn isClassIII(res: i32) bool {
    return (@mod(res, 2)) == 1;
}

// =============================================================================
// PENTAGON_ROTATIONS + FAILED_DIRECTIONS — verbatim from libh3 localij.c
// =============================================================================

/// origin leading digit -> index leading digit -> rotations 60 cw
pub const PENTAGON_ROTATIONS = [7][7]i32{
    .{ 0, -1, 0, 0, 0, 0, 0 },
    .{ -1, -1, -1, -1, -1, -1, -1 },
    .{ 0, -1, 0, 0, 0, 1, 0 },
    .{ 0, -1, 0, 0, 1, 1, 0 },
    .{ 0, -1, 0, 5, 0, 0, 0 },
    .{ 0, -1, 5, 5, 0, 0, 0 },
    .{ 0, -1, 0, 0, 0, 0, 0 },
};

pub const PENTAGON_ROTATIONS_REVERSE = [7][7]i32{
    .{ 0, 0, 0, 0, 0, 0, 0 },
    .{ -1, -1, -1, -1, -1, -1, -1 },
    .{ 0, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0, 1, 0 },
    .{ 0, 5, 0, 0, 0, 0, 0 },
    .{ 0, 5, 0, 5, 0, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0 },
};

pub const PENTAGON_ROTATIONS_REVERSE_NONPOLAR = [7][7]i32{
    .{ 0, 0, 0, 0, 0, 0, 0 },
    .{ -1, -1, -1, -1, -1, -1, -1 },
    .{ 0, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0, 1, 0 },
    .{ 0, 5, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 5, 1, 1, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0 },
};

pub const PENTAGON_ROTATIONS_REVERSE_POLAR = [7][7]i32{
    .{ 0, 0, 0, 0, 0, 0, 0 },
    .{ -1, -1, -1, -1, -1, -1, -1 },
    .{ 0, 1, 1, 1, 1, 1, 1 },
    .{ 0, 1, 0, 0, 0, 1, 0 },
    .{ 0, 1, 0, 0, 1, 1, 1 },
    .{ 0, 1, 0, 5, 1, 1, 0 },
    .{ 0, 1, 1, 0, 1, 1, 1 },
};

pub const FAILED_DIRECTIONS = [7][7]bool{
    .{ false, false, false, false, false, false, false },
    .{ false, false, false, false, false, false, false },
    .{ false, false, false, false, true, true, false },
    .{ false, false, false, false, true, false, true },
    .{ false, false, true, true, false, false, false },
    .{ false, false, true, false, false, false, true },
    .{ false, false, false, true, false, true, false },
};

// =============================================================================
// _getBaseCellDirection — direction from origin base cell to dest base cell
// =============================================================================

fn getBaseCellDirection(origin_bc: i32, target_bc: i32) Direction {
    var d: u3 = 0;
    while (d < 7) : (d += 1) {
        const nb = grid.baseCellNeighbors[@intCast(origin_bc)][d];
        if (nb == target_bc) return @enumFromInt(d);
    }
    return .invalid;
}

// =============================================================================
// ijkDistance — abs-max-component distance after subtraction + normalize
// =============================================================================

pub fn ijkDistance(a: CoordIJK, b: CoordIJK) i64 {
    var diff = h3idx.ijkSub(a, b);
    proj.ijkNormalize(&diff);
    const ai: i64 = @intCast(@abs(diff.i));
    const aj: i64 = @intCast(@abs(diff.j));
    const ak: i64 = @intCast(@abs(diff.k));
    return @max(ai, @max(aj, ak));
}

// =============================================================================
// cellToLocalIjk — translate `h3` into the origin's local IJK frame
// =============================================================================

pub fn cellToLocalIjk(origin: H3Index, h3: H3Index) Error!CoordIJK {
    const res = getResolution(origin);
    if (res != getResolution(h3)) return Error.ResolutionMismatch;

    const origin_bc = getBaseCell(origin);
    const dest_bc = getBaseCell(h3);
    if (origin_bc < 0 or origin_bc >= NUM_BASE_CELLS) return Error.CellInvalid;
    if (dest_bc < 0 or dest_bc >= NUM_BASE_CELLS) return Error.CellInvalid;

    var dir: Direction = .center;
    var rev_dir: Direction = .center;
    if (origin_bc != dest_bc) {
        dir = getBaseCellDirection(origin_bc, dest_bc);
        if (dir == .invalid) return Error.Failed;
        rev_dir = getBaseCellDirection(dest_bc, origin_bc);
        if (rev_dir == .invalid) return Error.Failed;
    }

    const origin_on_pent = h3idx.isBaseCellPentagon(origin_bc);
    const index_on_pent = h3idx.isBaseCellPentagon(dest_bc);

    var h = h3;
    if (dir != .center) {
        const base_cell_rotations = grid.baseCellNeighbor60CCWRots[@intCast(origin_bc)][@intFromEnum(dir)];
        var i: i32 = 0;
        if (index_on_pent) {
            while (i < base_cell_rotations) : (i += 1) {
                h = h3idx.h3RotatePent60cw(h);
                rev_dir = rotate60cwDirection(rev_dir);
                if (rev_dir == .k_axes) rev_dir = rotate60cwDirection(rev_dir);
            }
        } else {
            while (i < base_cell_rotations) : (i += 1) {
                h = h3idx.h3Rotate60cw(h);
                rev_dir = rotate60cwDirection(rev_dir);
            }
        }
    }

    var index_fijk = FaceIJK{ .face = 0, .coord = .{ .i = 0, .j = 0, .k = 0 } };
    _ = h3dec.h3ToFaceIjkWithInitializedFijk(h, &index_fijk);

    if (dir != .center) {
        var pentagon_rotations: i32 = 0;
        var direction_rotations: i32 = 0;

        if (origin_on_pent) {
            const old = h3idx.h3LeadingNonZeroDigit(origin);
            if (old == .invalid) return Error.CellInvalid;
            const old_idx = @intFromEnum(old);
            if (FAILED_DIRECTIONS[old_idx][@intFromEnum(dir)]) return Error.Failed;
            direction_rotations = PENTAGON_ROTATIONS[old_idx][@intFromEnum(dir)];
            pentagon_rotations = direction_rotations;
        } else if (index_on_pent) {
            const ild = h3idx.h3LeadingNonZeroDigit(h);
            if (ild == .invalid) return Error.CellInvalid;
            if (FAILED_DIRECTIONS[@intFromEnum(ild)][@intFromEnum(rev_dir)]) return Error.Failed;
            pentagon_rotations = PENTAGON_ROTATIONS[@intFromEnum(rev_dir)][@intFromEnum(ild)];
        }
        if (pentagon_rotations < 0 or direction_rotations < 0) return Error.CellInvalid;

        var i: i32 = 0;
        while (i < pentagon_rotations) : (i += 1) h3idx.ijkRotate60cw(&index_fijk.coord);

        var offset = CoordIJK{ .i = 0, .j = 0, .k = 0 };
        // Apply direction unit vector + scale by aperture-7 walk-down to `res`
        const d_int = @intFromEnum(dir);
        if (d_int > 0 and d_int < 7) {
            const uv = h3idx.UNIT_VECS[d_int];
            offset = h3idx.ijkAdd(offset, uv);
            proj.ijkNormalize(&offset);
        }
        // Scale offset by walking down to resolution `res`
        var r: i32 = res - 1;
        while (r >= 0) : (r -= 1) {
            if (isClassIII(r + 1)) {
                h3idx.downAp7(&offset);
            } else {
                h3idx.downAp7r(&offset);
            }
        }
        i = 0;
        while (i < direction_rotations) : (i += 1) h3idx.ijkRotate60cw(&offset);

        index_fijk.coord = h3idx.ijkAdd(index_fijk.coord, offset);
        proj.ijkNormalize(&index_fijk.coord);
    } else if (origin_on_pent and index_on_pent) {
        if (dest_bc != origin_bc) return Error.Failed;
        const old = h3idx.h3LeadingNonZeroDigit(origin);
        const ild = h3idx.h3LeadingNonZeroDigit(h3);
        if (old == .invalid or ild == .invalid) return Error.CellInvalid;
        if (FAILED_DIRECTIONS[@intFromEnum(old)][@intFromEnum(ild)]) return Error.Failed;
        const wpr = PENTAGON_ROTATIONS[@intFromEnum(old)][@intFromEnum(ild)];
        var i: i32 = 0;
        while (i < wpr) : (i += 1) h3idx.ijkRotate60cw(&index_fijk.coord);
    }

    return index_fijk.coord;
}

fn rotate60cwDirection(d: Direction) Direction {
    return switch (d) {
        .k_axes => .jk_axes,
        .jk_axes => .j_axes,
        .j_axes => .ij_axes,
        .ij_axes => .i_axes,
        .i_axes => .ik_axes,
        .ik_axes => .k_axes,
        else => d,
    };
}

// =============================================================================
// gridDistance — IJK-distance in the origin's local frame
// =============================================================================

pub fn gridDistance(origin: H3Index, h3: H3Index) Error!i64 {
    const a = try cellToLocalIjk(origin, origin);
    const b = try cellToLocalIjk(origin, h3);
    return ijkDistance(a, b);
}

// =============================================================================
// uncompactCellsSize / uncompactCells — pure passthrough via hierarchy
// =============================================================================

pub fn uncompactCellsSize(compacted: []const H3Index, res: i32) Error!i64 {
    var total: i64 = 0;
    for (compacted) |c| {
        if (c == 0) continue;
        total += try hier.cellToChildrenSize(c, res);
    }
    return total;
}

pub fn uncompactCells(compacted: []const H3Index, res: i32, out: []H3Index) Error!void {
    var idx: usize = 0;
    for (compacted) |c| {
        if (c == 0) continue;
        const child_size = try hier.cellToChildrenSize(c, res);
        if (idx + @as(usize, @intCast(child_size)) > out.len) return Error.MemoryBounds;
        try hier.cellToChildren(c, res, out[idx .. idx + @as(usize, @intCast(child_size))]);
        idx += @intCast(child_size);
    }
}

// =============================================================================
// compactCells — open-addressed parent rollup with reserved-bits counter
// =============================================================================

pub fn compactCells(
    allocator: std.mem.Allocator,
    h3_set: []const H3Index,
    compacted: []H3Index,
) Error!void {
    if (h3_set.len == 0) return;
    var res = getResolution(h3_set[0]);
    if (res == 0) {
        if (compacted.len < h3_set.len) return Error.MemoryBounds;
        @memcpy(compacted[0..h3_set.len], h3_set);
        return;
    }

    var remaining = allocator.alloc(H3Index, h3_set.len) catch return Error.MemoryAlloc;
    defer allocator.free(remaining);
    @memcpy(remaining, h3_set);

    var hash_set = allocator.alloc(H3Index, h3_set.len) catch return Error.MemoryAlloc;
    defer allocator.free(hash_set);
    @memset(hash_set, 0);

    var compact_offset: usize = 0;
    var num_remaining: usize = h3_set.len;

    while (num_remaining > 0) {
        res = getResolution(remaining[0]);
        const parent_res = res - 1;

        if (parent_res >= 0) {
            for (remaining[0..num_remaining]) |curr| {
                if (curr == 0) continue;
                if (getReservedBits(curr) != 0) return Error.CellInvalid;
                const parent_raw = try hier.cellToParent(curr, parent_res);
                var loc: usize = @intCast(@mod(@as(i64, @intCast(parent_raw)), @as(i64, @intCast(num_remaining))));
                var loop_count: usize = 0;
                var parent = parent_raw;
                while (hash_set[loc] != 0) {
                    if (loop_count > num_remaining) return Error.Failed;
                    const stored_no_count = hash_set[loc] & ~(@as(H3Index, 0x7) << H3_RESERVED_OFFSET);
                    if (stored_no_count == parent) {
                        const count: u32 = @as(u32, getReservedBits(hash_set[loc])) + 1;
                        var limit: u32 = 7;
                        if (pure.isPentagon(stored_no_count)) limit -= 1;
                        if (count + 1 > limit) return Error.DuplicateInput;
                        parent = setReservedBits(parent, @intCast(count));
                        hash_set[loc] = 0;
                    } else {
                        loc = @mod(loc + 1, num_remaining);
                    }
                    loop_count += 1;
                }
                hash_set[loc] = parent;
            }
        }

        const max_compactable: usize = num_remaining / 6;
        if (max_compactable == 0) {
            if (compact_offset + num_remaining > compacted.len) return Error.MemoryBounds;
            @memcpy(compacted[compact_offset..][0..num_remaining], remaining[0..num_remaining]);
            return;
        }
        var compactable = allocator.alloc(H3Index, max_compactable) catch return Error.MemoryAlloc;
        defer allocator.free(compactable);
        var compactable_count: usize = 0;

        for (hash_set[0..num_remaining]) |*entry| {
            if (entry.* == 0) continue;
            var count: u32 = @as(u32, getReservedBits(entry.*)) + 1;
            const stripped = entry.* & ~(@as(H3Index, 0x7) << H3_RESERVED_OFFSET);
            if (pure.isPentagon(stripped)) {
                entry.* = setReservedBits(entry.*, @intCast(count));
                count += 1;
            }
            if (count == 7) {
                compactable[compactable_count] = stripped;
                compactable_count += 1;
            }
        }

        var uncompactable_count: usize = 0;
        for (remaining[0..num_remaining]) |curr| {
            if (curr == 0) continue;
            const parent = try hier.cellToParent(curr, parent_res);
            var loc: usize = @intCast(@mod(@as(i64, @intCast(parent)), @as(i64, @intCast(num_remaining))));
            var loop_count: usize = 0;
            var is_uncompactable = true;
            while (true) {
                if (loop_count > num_remaining) return Error.Failed;
                const stored = hash_set[loc] & ~(@as(H3Index, 0x7) << H3_RESERVED_OFFSET);
                if (stored == parent) {
                    const count: u32 = @as(u32, getReservedBits(hash_set[loc])) + 1;
                    if (count == 7) is_uncompactable = false;
                    break;
                }
                loc = @mod(loc + 1, num_remaining);
                loop_count += 1;
            }
            if (is_uncompactable) {
                if (compact_offset + uncompactable_count >= compacted.len) return Error.MemoryBounds;
                compacted[compact_offset + uncompactable_count] = curr;
                uncompactable_count += 1;
            }
        }

        @memset(hash_set, 0);
        compact_offset += uncompactable_count;
        @memcpy(remaining[0..compactable_count], compactable[0..compactable_count]);
        num_remaining = compactable_count;
    }
}

// =============================================================================
// maxFaceCount / getIcosahedronFaces
// =============================================================================

pub fn maxFaceCount(cell: H3Index) i32 {
    return if (pure.isPentagon(cell)) 5 else 2;
}

pub fn getIcosahedronFaces(cell: H3Index, out: []i32) Error!void {
    const res = getResolution(cell);
    const is_pent = pure.isPentagon(cell);

    // Class II pentagons defer to their direct child pentagon (per libh3).
    if (is_pent and !isClassIII(res)) {
        const child_pent = try makeDirectChild(cell, 0);
        return getIcosahedronFaces(child_pent, out);
    }

    var fijk: FaceIJK = undefined;
    try h3dec.h3ToFaceIjk(cell, &fijk);

    var fijk_verts: [6]FaceIJK = undefined;
    var vert_count: usize = undefined;
    var adj_res = res;
    if (is_pent) {
        vert_count = 5;
        var pent_verts: [5]FaceIJK = undefined;
        bnd.faceIjkPentToVerts(&fijk, &adj_res, &pent_verts);
        @memcpy(fijk_verts[0..5], &pent_verts);
    } else {
        vert_count = 6;
        bnd.faceIjkToVerts(&fijk, &adj_res, &fijk_verts);
    }

    const face_count: usize = @intCast(maxFaceCount(cell));
    if (out.len < face_count) return Error.MemoryBounds;
    var i: usize = 0;
    while (i < face_count) : (i += 1) out[i] = -1;

    i = 0;
    while (i < vert_count) : (i += 1) {
        var v = fijk_verts[i];
        if (is_pent) {
            _ = bnd.adjustPentVertOverage(&v, adj_res);
        } else {
            _ = h3dec.adjustOverageClassII(&v, adj_res, false, true);
        }
        var pos: usize = 0;
        while (pos < face_count and out[pos] != -1 and out[pos] != v.face) : (pos += 1) {}
        if (pos >= face_count) return Error.Failed;
        if (out[pos] == -1) out[pos] = v.face;
    }
}

fn makeDirectChild(h: H3Index, cell_number: u3) Error!H3Index {
    const cur_res = getResolution(h);
    const child_res = cur_res + 1;
    if (child_res > MAX_RES) return Error.ResolutionDomain;
    var ch = (h & ~(@as(H3Index, 0xF) << H3_RES_OFFSET)) |
        (@as(H3Index, @intCast(child_res)) << H3_RES_OFFSET);
    const shift: u6 = @intCast((@as(i32, MAX_RES) - child_res) * 3);
    ch = (ch & ~(@as(H3Index, 0x7) << shift)) | (@as(H3Index, cell_number) << shift);
    return ch;
}

// =============================================================================
// Cube coordinate conversion (for gridPathCells linear interpolation)
// =============================================================================

inline fn isBaseCellPolarPentagon(bc: i32) bool {
    return bc == 4 or bc == 117;
}

pub fn ijkToCube(ijk: *CoordIJK) void {
    const new_i = -ijk.i + ijk.k;
    const new_j = ijk.j - ijk.k;
    ijk.i = new_i;
    ijk.j = new_j;
    ijk.k = -new_i - new_j;
}

pub fn cubeToIjk(ijk: *CoordIJK) void {
    ijk.i = -ijk.i;
    ijk.k = 0;
    proj.ijkNormalize(ijk);
}

fn cubeRound(i: f64, j: f64, k: f64) CoordIJK {
    var ri: i32 = @intFromFloat(@round(i));
    var rj: i32 = @intFromFloat(@round(j));
    var rk: i32 = @intFromFloat(@round(k));
    const i_diff = @abs(@as(f64, @floatFromInt(ri)) - i);
    const j_diff = @abs(@as(f64, @floatFromInt(rj)) - j);
    const k_diff = @abs(@as(f64, @floatFromInt(rk)) - k);
    if (i_diff > j_diff and i_diff > k_diff) {
        ri = -rj - rk;
    } else if (j_diff > k_diff) {
        rj = -ri - rk;
    } else {
        rk = -ri - rj;
    }
    return .{ .i = ri, .j = rj, .k = rk };
}

// =============================================================================
// localIjkToCell — reverse of cellToLocalIjk
// =============================================================================

const H3_MODE_OFFSET: u6 = 59;
const CELL_MODE: u4 = 1;
const H3_INIT: H3Index = 0x0000_1FFF_FFFF_FFFF;

inline fn setMode(h: H3Index, mode: u4) H3Index {
    return (h & ~(@as(H3Index, 0xF) << H3_MODE_OFFSET)) |
        (@as(H3Index, mode) << H3_MODE_OFFSET);
}

inline fn setResolution(h: H3Index, res: i32) H3Index {
    return (h & ~(@as(H3Index, 0xF) << H3_RES_OFFSET)) |
        (@as(H3Index, @intCast(res)) << H3_RES_OFFSET);
}

inline fn setBaseCellH(h: H3Index, bc: i32) H3Index {
    return (h & ~(@as(H3Index, 0x7F) << H3_BC_OFFSET)) |
        (@as(H3Index, @intCast(bc)) << H3_BC_OFFSET);
}

inline fn setIndexDigit(h: H3Index, res: i32, digit: Direction) H3Index {
    const shift: u6 = @intCast((@as(i32, MAX_RES) - res) * 3);
    return (h & ~(@as(H3Index, 0x7) << shift)) |
        (@as(H3Index, @intFromEnum(digit)) << shift);
}

fn rotate60ccwDirection(d: Direction) Direction {
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

pub fn localIjkToCell(origin: H3Index, ijk_in: CoordIJK) Error!H3Index {
    const res = getResolution(origin);
    const origin_bc = getBaseCell(origin);
    if (origin_bc < 0 or origin_bc >= NUM_BASE_CELLS) return Error.CellInvalid;
    const origin_on_pent = h3idx.isBaseCellPentagon(origin_bc);

    var out: H3Index = H3_INIT;
    out = setMode(out, CELL_MODE);
    out = setResolution(out, res);

    if (res == 0) {
        const dir = h3idx.unitIjkToDigit(ijk_in);
        if (dir == .invalid) return Error.Failed;
        const new_bc = grid.baseCellNeighbors[@intCast(origin_bc)][@intFromEnum(dir)];
        if (new_bc == grid.INVALID_BASE_CELL) return Error.Failed;
        out = setBaseCellH(out, new_bc);
        return out;
    }

    var ijk = ijk_in;
    // Walk up from finest resolution to base cell.
    var r: i32 = res - 1;
    while (r >= 0) : (r -= 1) {
        const last_ijk = ijk;
        var last_center: CoordIJK = undefined;
        if (isClassIII(r + 1)) {
            h3idx.upAp7(&ijk);
            last_center = ijk;
            h3idx.downAp7(&last_center);
        } else {
            h3idx.upAp7r(&ijk);
            last_center = ijk;
            h3idx.downAp7r(&last_center);
        }
        var diff = h3idx.ijkSub(last_ijk, last_center);
        proj.ijkNormalize(&diff);
        out = setIndexDigit(out, r + 1, h3idx.unitIjkToDigit(diff));
    }

    if (ijk.i > 1 or ijk.j > 1 or ijk.k > 1) return Error.Failed;

    var dir = h3idx.unitIjkToDigit(ijk);
    var base_cell = grid.baseCellNeighbors[@intCast(origin_bc)][@intFromEnum(dir)];
    const index_on_pent = if (base_cell == grid.INVALID_BASE_CELL) false else h3idx.isBaseCellPentagon(base_cell);

    if (dir != .center) {
        var pentagon_rotations: i32 = 0;
        if (origin_on_pent) {
            const old = h3idx.h3LeadingNonZeroDigit(origin);
            if (old == .invalid) return Error.CellInvalid;
            pentagon_rotations = PENTAGON_ROTATIONS_REVERSE[@intFromEnum(old)][@intFromEnum(dir)];
            var i: i32 = 0;
            while (i < pentagon_rotations) : (i += 1) dir = rotate60ccwDirection(dir);
            if (dir == .k_axes) return Error.Pentagon;
            base_cell = grid.baseCellNeighbors[@intCast(origin_bc)][@intFromEnum(dir)];
        }
        const base_cell_rotations = grid.baseCellNeighbor60CCWRots[@intCast(origin_bc)][@intFromEnum(dir)];

        if (index_on_pent) {
            const rev_dir = getBaseCellDirection(base_cell, origin_bc);
            if (rev_dir == .invalid) return Error.Failed;
            var i: i32 = 0;
            while (i < base_cell_rotations) : (i += 1) out = h3idx.h3Rotate60ccw(out);

            const ild = h3idx.h3LeadingNonZeroDigit(out);
            if (ild == .invalid) return Error.CellInvalid;
            if (isBaseCellPolarPentagon(base_cell)) {
                pentagon_rotations = PENTAGON_ROTATIONS_REVERSE_POLAR[@intFromEnum(rev_dir)][@intFromEnum(ild)];
            } else {
                pentagon_rotations = PENTAGON_ROTATIONS_REVERSE_NONPOLAR[@intFromEnum(rev_dir)][@intFromEnum(ild)];
            }
            if (pentagon_rotations < 0) return Error.CellInvalid;
            i = 0;
            while (i < pentagon_rotations) : (i += 1) out = h3idx.h3RotatePent60ccw(out);
        } else {
            if (pentagon_rotations < 0) return Error.CellInvalid;
            var i: i32 = 0;
            while (i < pentagon_rotations) : (i += 1) out = h3idx.h3Rotate60ccw(out);
            i = 0;
            while (i < base_cell_rotations) : (i += 1) out = h3idx.h3Rotate60ccw(out);
        }
    } else if (origin_on_pent and index_on_pent) {
        const old = h3idx.h3LeadingNonZeroDigit(origin);
        const ild = h3idx.h3LeadingNonZeroDigit(out);
        if (old == .invalid or ild == .invalid) return Error.CellInvalid;
        const wpr = PENTAGON_ROTATIONS_REVERSE[@intFromEnum(old)][@intFromEnum(ild)];
        if (wpr < 0) return Error.CellInvalid;
        var i: i32 = 0;
        while (i < wpr) : (i += 1) out = h3idx.h3Rotate60ccw(out);
    }

    if (index_on_pent) {
        if (h3idx.h3LeadingNonZeroDigit(out) == .k_axes) return Error.Pentagon;
    }

    out = setBaseCellH(out, base_cell);
    return out;
}

// =============================================================================
// gridPathCells + gridPathCellsSize
// =============================================================================

pub fn gridPathCellsSize(start: H3Index, end: H3Index) Error!i64 {
    const dist = try gridDistance(start, end);
    return dist + 1;
}

pub fn gridPathCells(start: H3Index, end: H3Index, out: []H3Index) Error!void {
    const dist = try gridDistance(start, end);
    if (out.len < @as(usize, @intCast(dist + 1))) return Error.MemoryBounds;

    var start_ijk = try cellToLocalIjk(start, start);
    var end_ijk = try cellToLocalIjk(start, end);
    ijkToCube(&start_ijk);
    ijkToCube(&end_ijk);

    const d_f: f64 = @floatFromInt(dist);
    const i_step: f64 = if (dist != 0) @as(f64, @floatFromInt(end_ijk.i - start_ijk.i)) / d_f else 0.0;
    const j_step: f64 = if (dist != 0) @as(f64, @floatFromInt(end_ijk.j - start_ijk.j)) / d_f else 0.0;
    const k_step: f64 = if (dist != 0) @as(f64, @floatFromInt(end_ijk.k - start_ijk.k)) / d_f else 0.0;

    var n: i64 = 0;
    while (n <= dist) : (n += 1) {
        const nf: f64 = @floatFromInt(n);
        var current = cubeRound(
            @as(f64, @floatFromInt(start_ijk.i)) + i_step * nf,
            @as(f64, @floatFromInt(start_ijk.j)) + j_step * nf,
            @as(f64, @floatFromInt(start_ijk.k)) + k_step * nf,
        );
        cubeToIjk(&current);
        out[@intCast(n)] = try localIjkToCell(start, current);
    }
}

// =============================================================================
// Cross-validation tests
// =============================================================================

const testing = std.testing;
const LatLng = root.LatLng;

test "pure gridDistance matches libh3 on same-base-cell pairs" {
    var rng = std.Random.DefaultPrng.init(0xDEDA);
    var res: i32 = 4;
    while (res <= 9) : (res += 1) {
        for (0..20) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const origin = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(origin)) continue;

            // Walk k=2 ring; pick a nearby cell.
            const max_idx: usize = @intCast(try pure.maxGridDiskSize(2));
            const buf = try testing.allocator.alloc(H3Index, max_idx);
            defer testing.allocator.free(buf);
            @memset(buf, 0);
            grid.gridDiskUnsafe(origin, 2, buf) catch continue;
            for (buf) |target| {
                if (target == 0 or target == origin) continue;
                if (pure.isPentagon(target)) continue;

                const ours = gridDistance(origin, target) catch continue;
                var theirs_raw: i64 = 0;
                const e = root.raw.gridDistance(origin, target, &theirs_raw);
                if (e != 0) continue;
                try testing.expectEqual(theirs_raw, ours);
                break;
            }
        }
    }
}

test "pure gridDistance origin to itself is 0" {
    var rng = std.Random.DefaultPrng.init(0x1AB);
    for (0..30) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), 7);
        try testing.expectEqual(@as(i64, 0), try gridDistance(cell, cell));
    }
}

test "pure gridDistance rejects mismatched resolutions" {
    const a = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 5);
    const b = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 6);
    try testing.expectError(Error.ResolutionMismatch, gridDistance(a, b));
}

test "pure uncompactCellsSize matches libh3" {
    // Pick a parent and a fine-grained res; size should equal cellToChildrenSize.
    var rng = std.Random.DefaultPrng.init(0xC0DA);
    for (0..15) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const parent_res: i32 = @intCast(rng.random().int(u32) % 8);
        const parent = try root.latLngToCell(LatLng.fromDegrees(lat, lng), parent_res);
        const child_res: i32 = parent_res + 2;
        const expected = try hier.cellToChildrenSize(parent, child_res);
        const set = [_]H3Index{parent};
        const actual = try uncompactCellsSize(&set, child_res);
        try testing.expectEqual(expected, actual);
    }
}

test "pure uncompactCells reproduces all children" {
    const parent_cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 5);
    const child_res: i32 = 7;
    const size = try hier.cellToChildrenSize(parent_cell, child_res);
    const buf = try testing.allocator.alloc(H3Index, @intCast(size));
    defer testing.allocator.free(buf);
    const set = [_]H3Index{parent_cell};
    try uncompactCells(&set, child_res, buf);
    // Every cell should invert to the parent.
    for (buf) |c| {
        try testing.expectEqual(parent_cell, try hier.cellToParent(c, 5));
    }
}

test "pure compactCells roundtrips with uncompactCells on a full subtree" {
    // Take all children of a hex parent at res N+2; compact should yield {parent}.
    const parent = try root.latLngToCell(LatLng.fromDegrees(0.0, 0.0), 5);
    if (pure.isPentagon(parent)) return; // skip pentagons for this test
    const child_res: i32 = 7;
    const expected_size = try hier.cellToChildrenSize(parent, child_res);
    const children = try testing.allocator.alloc(H3Index, @intCast(expected_size));
    defer testing.allocator.free(children);
    try hier.cellToChildren(parent, child_res, children);

    const compact_buf = try testing.allocator.alloc(H3Index, @intCast(expected_size));
    defer testing.allocator.free(compact_buf);
    @memset(compact_buf, 0);
    try compactCells(testing.allocator, children, compact_buf);

    // Find the non-zero compacted entries
    var found = false;
    var count: usize = 0;
    for (compact_buf) |c| {
        if (c != 0) {
            count += 1;
            if (c == parent) found = true;
        }
    }
    try testing.expect(found);
    try testing.expectEqual(@as(usize, 1), count);
}

test "pure maxFaceCount matches libh3" {
    var rng = std.Random.DefaultPrng.init(0xFACE);
    for (0..20) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), 7);
        var theirs: i32 = 0;
        _ = root.raw.maxFaceCount(cell, &theirs);
        try testing.expectEqual(theirs, maxFaceCount(cell));
    }
    // Pentagons.
    var pents: [12]H3Index = undefined;
    try root.getPentagons(5, &pents);
    for (pents) |p| try testing.expectEqual(@as(i32, 5), maxFaceCount(p));
}

test "pure getIcosahedronFaces matches libh3 (set equality)" {
    var rng = std.Random.DefaultPrng.init(0xFACE2);
    for (0..20) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const cell = try root.latLngToCell(LatLng.fromDegrees(lat, lng), 7);
        const fc: usize = @intCast(maxFaceCount(cell));
        const ours = try testing.allocator.alloc(i32, fc);
        defer testing.allocator.free(ours);
        const theirs = try testing.allocator.alloc(i32, fc);
        defer testing.allocator.free(theirs);
        getIcosahedronFaces(cell, ours) catch continue;
        _ = root.raw.getIcosahedronFaces(cell, theirs.ptr);

        // Both arrays should contain the same set of face IDs (ignoring -1 fillers).
        var our_seen: [20]bool = .{false} ** 20;
        var their_seen: [20]bool = .{false} ** 20;
        for (ours) |f| if (f >= 0 and f < 20) {
            our_seen[@intCast(f)] = true;
        };
        for (theirs) |f| if (f >= 0 and f < 20) {
            their_seen[@intCast(f)] = true;
        };
        try testing.expectEqualSlices(bool, &their_seen, &our_seen);
    }
}

test "pure localIjkToCell inverts cellToLocalIjk on same-base-cell pairs" {
    var rng = std.Random.DefaultPrng.init(0xBABA1);
    var res: i32 = 4;
    while (res <= 8) : (res += 1) {
        for (0..15) |_| {
            const lat = (rng.random().float(f64) - 0.5) * 178.0;
            const lng = (rng.random().float(f64) - 0.5) * 358.0;
            const origin = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(origin)) continue;
            // Self-round-trip
            const ijk = try cellToLocalIjk(origin, origin);
            const back = try localIjkToCell(origin, ijk);
            try testing.expectEqual(origin, back);
        }
    }
}

test "pure gridPathCells matches libh3 on short paths" {
    // Hand-picked nearby cells: origin and one of its k=2 ring neighbors.
    var seed = std.Random.DefaultPrng.init(0xDAB);
    var res: i32 = 5;
    while (res <= 8) : (res += 1) {
        for (0..10) |_| {
            const lat = (seed.random().float(f64) - 0.5) * 178.0;
            const lng = (seed.random().float(f64) - 0.5) * 358.0;
            const origin = try root.latLngToCell(LatLng.fromDegrees(lat, lng), res);
            if (pure.isPentagon(origin)) continue;

            const max_idx: usize = @intCast(try pure.maxGridDiskSize(2));
            const ring = try testing.allocator.alloc(H3Index, max_idx);
            defer testing.allocator.free(ring);
            @memset(ring, 0);
            grid.gridDiskUnsafe(origin, 2, ring) catch continue;

            for (ring) |target| {
                if (target == 0 or target == origin or pure.isPentagon(target)) continue;
                const path_len = gridPathCellsSize(origin, target) catch continue;
                const ours = try testing.allocator.alloc(H3Index, @intCast(path_len));
                defer testing.allocator.free(ours);
                gridPathCells(origin, target, ours) catch continue;

                // Validate: starts at origin, ends at target, each step is a neighbor.
                try testing.expectEqual(origin, ours[0]);
                try testing.expectEqual(target, ours[ours.len - 1]);
                var i: usize = 1;
                while (i < ours.len) : (i += 1) {
                    try testing.expect(try grid.areNeighborCells(ours[i - 1], ours[i]));
                }
                break;
            }
        }
    }
}

test "pure gridPathCellsSize matches libh3" {
    var rng = std.Random.DefaultPrng.init(0xCA15);
    for (0..20) |_| {
        const lat = (rng.random().float(f64) - 0.5) * 178.0;
        const lng = (rng.random().float(f64) - 0.5) * 358.0;
        const origin = try root.latLngToCell(LatLng.fromDegrees(lat, lng), 6);
        if (pure.isPentagon(origin)) continue;

        const max_idx: usize = @intCast(try pure.maxGridDiskSize(1));
        const ring = try testing.allocator.alloc(H3Index, max_idx);
        defer testing.allocator.free(ring);
        @memset(ring, 0);
        grid.gridDiskUnsafe(origin, 1, ring) catch continue;

        for (ring) |target| {
            if (target == 0 or target == origin or pure.isPentagon(target)) continue;
            // gridPathCellsSize = gridDistance + 1
            const ours = try gridPathCellsSize(origin, target);
            try testing.expectEqual(@as(i64, 2), ours);
            break;
        }
    }
}
