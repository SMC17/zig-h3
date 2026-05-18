//! C-ABI shim — exposes the batch + parallel zig-h3 API as a shared
//! library that any language with C-FFI can call (Python ctypes, Go cgo,
//! Rust libc::, Node N-API via prebuild).
//!
//! Symbol naming: `zig_h3_<verb>` to avoid collision with libh3's symbols.

const std = @import("std");
const root = @import("root.zig");

const LatLng = extern struct {
    lat: f64,
    lng: f64,
};

const c_allocator = std.heap.c_allocator;

/// Batch lat/lng → cell. Returns number of successful conversions
/// (slots written with H3_NULL=0 for non-finite inputs).
///
/// `points` and `out` must both be pre-allocated with `n` elements.
export fn zig_h3_latlng_to_cell_batch(
    points: [*]const LatLng,
    n: usize,
    res: i32,
    out: [*]u64,
) callconv(.c) usize {
    const slice: []const root.LatLng = @ptrCast(points[0..n]);
    const out_slice: []u64 = out[0..n];
    return root.latLngToCellBatch(slice, res, out_slice);
}

/// Parallel batch lat/lng → cell. Same contract as the serial version,
/// plus a `thread_count` parameter. Returns number of successes.
///
/// Returns `0xFFFFFFFFFFFFFFFF` (-1 as usize) on allocator failure.
export fn zig_h3_latlng_to_cell_batch_parallel(
    points: [*]const LatLng,
    n: usize,
    res: i32,
    out: [*]u64,
    thread_count: usize,
) callconv(.c) usize {
    const slice: []const root.LatLng = @ptrCast(points[0..n]);
    const out_slice: []u64 = out[0..n];
    return root.latLngToCellBatchParallel(c_allocator, slice, res, out_slice, thread_count) catch return std.math.maxInt(usize);
}

/// Batch cell → lat/lng. Returns number of successful decodes
/// (slots written with NaN for invalid cells).
export fn zig_h3_cell_to_latlng_batch(
    cells: [*]const u64,
    n: usize,
    out: [*]LatLng,
) callconv(.c) usize {
    const cell_slice: []const u64 = cells[0..n];
    const out_slice: []root.LatLng = @ptrCast(out[0..n]);
    return root.cellToLatLngBatch(cell_slice, out_slice);
}

/// Parallel batch cell → lat/lng. Returns -1 on allocator failure.
export fn zig_h3_cell_to_latlng_batch_parallel(
    cells: [*]const u64,
    n: usize,
    out: [*]LatLng,
    thread_count: usize,
) callconv(.c) usize {
    const cell_slice: []const u64 = cells[0..n];
    const out_slice: []root.LatLng = @ptrCast(out[0..n]);
    return root.cellToLatLngBatchParallel(c_allocator, cell_slice, out_slice, thread_count) catch return std.math.maxInt(usize);
}

/// Batch gridDisk. `stride` should equal `maxGridDiskSize(k)`. The output
/// buffer must have `n * stride` elements. Returns number of successful
/// disks (origins whose disk didn't cross a pentagon).
export fn zig_h3_grid_disk_batch(
    origins: [*]const u64,
    n: usize,
    k: i32,
    stride: usize,
    out: [*]u64,
) callconv(.c) usize {
    const slice: []const u64 = origins[0..n];
    const out_slice: []u64 = out[0 .. n * stride];
    return root.gridDiskBatch(c_allocator, slice, k, stride, out_slice) catch return std.math.maxInt(usize);
}

/// Parallel batch gridDisk. Returns -1 on error.
export fn zig_h3_grid_disk_batch_parallel(
    origins: [*]const u64,
    n: usize,
    k: i32,
    stride: usize,
    out: [*]u64,
    thread_count: usize,
) callconv(.c) usize {
    const slice: []const u64 = origins[0..n];
    const out_slice: []u64 = out[0 .. n * stride];
    return root.gridDiskBatchParallel(c_allocator, slice, k, stride, out_slice, thread_count) catch return std.math.maxInt(usize);
}

/// Max disk size for a given k. Returns -1 on bad k.
export fn zig_h3_max_grid_disk_size(k: i32) callconv(.c) i64 {
    return root.maxGridDiskSize(k) catch -1;
}

/// Library version. Returns null-terminated UTF-8 string.
export fn zig_h3_version() callconv(.c) [*:0]const u8 {
    return "1.4.0";
}

// ============================================================================
// Single-cell scalar surface — exposed for downstream bindings that need to
// replace h3-py / h3-go / h3-js / h3o feature-for-feature.
// ============================================================================

/// Scalar latLngToCell. Returns 0 on error (out-of-range res, non-finite lat/lng).
export fn zig_h3_latlng_to_cell(lat: f64, lng: f64, res: i32) callconv(.c) u64 {
    const p = root.LatLng{ .lat = lat, .lng = lng };
    return root.latLngToCell(p, res) catch 0;
}

/// Scalar cellToLatLng. Writes NaN/NaN on error.
export fn zig_h3_cell_to_latlng(cell: u64, out_lat: *f64, out_lng: *f64) callconv(.c) bool {
    const ll = root.cellToLatLng(cell) catch {
        out_lat.* = std.math.nan(f64);
        out_lng.* = std.math.nan(f64);
        return false;
    };
    out_lat.* = ll.lat;
    out_lng.* = ll.lng;
    return true;
}

/// True iff `cell` is a syntactically valid H3 cell.
export fn zig_h3_is_valid_cell(cell: u64) callconv(.c) bool {
    return root.isValidCell(cell);
}

/// True iff `cell` is one of the 12 pentagons at its resolution.
export fn zig_h3_is_pentagon(cell: u64) callconv(.c) bool {
    return root.isPentagon(cell);
}

/// True iff `cell` is at a Class III resolution (odd-numbered).
export fn zig_h3_is_res_class_iii(cell: u64) callconv(.c) bool {
    return root.isResClassIII(cell);
}

/// Resolution (0-15) of `cell`. -1 if invalid.
export fn zig_h3_get_resolution(cell: u64) callconv(.c) i32 {
    return root.getResolution(cell);
}

/// Base-cell index (0-121) of `cell`.
export fn zig_h3_get_base_cell_number(cell: u64) callconv(.c) i32 {
    return root.getBaseCellNumber(cell);
}

/// Convert cell to 15-char hex string. `out_buf` must be 17+ bytes.
/// Writes null-terminated UTF-8. Returns false on error.
export fn zig_h3_to_string(cell: u64, out_buf: [*]u8, buf_len: usize) callconv(.c) bool {
    if (buf_len < 17) return false;
    const slice = out_buf[0..buf_len];
    _ = root.h3ToString(cell, slice) catch return false;
    return true;
}

/// Convert null-terminated hex string to cell. Returns 0 on parse error.
/// The input must be null-terminated.
export fn zig_h3_string_to_h3(str: [*:0]const u8) callconv(.c) u64 {
    const slice = std.mem.sliceTo(str, 0);
    // root.stringToH3 wants a sentinel-terminated slice; the conversion is
    // safe because we know `str` is null-terminated.
    const sentinel_slice: [:0]const u8 = slice.ptr[0..slice.len :0];
    return root.stringToH3(sentinel_slice) catch 0;
}

/// Cell-to-parent at the given parent resolution. Returns 0 on error.
export fn zig_h3_cell_to_parent(cell: u64, parent_res: i32) callconv(.c) u64 {
    return root.cellToParent(cell, parent_res) catch 0;
}

/// Cell-to-center-child at the given child resolution. Returns 0 on error.
export fn zig_h3_cell_to_center_child(cell: u64, child_res: i32) callconv(.c) u64 {
    return root.cellToCenterChild(cell, child_res) catch 0;
}

/// Max children count for the cell at the target resolution. Returns -1 on error.
export fn zig_h3_cell_to_children_size(cell: u64, child_res: i32) callconv(.c) i64 {
    return root.cellToChildrenSize(cell, child_res) catch -1;
}

/// Children of `cell` at `child_res`. `out` must be at least
/// `zig_h3_cell_to_children_size(cell, child_res)` long. Returns false on error.
export fn zig_h3_cell_to_children(cell: u64, child_res: i32, out: [*]u64, out_len: usize) callconv(.c) bool {
    root.cellToChildren(cell, child_res, out[0..out_len]) catch return false;
    return true;
}

/// Grid distance between two cells (must be same resolution). Returns -1 on error.
export fn zig_h3_grid_distance(a: u64, b: u64) callconv(.c) i64 {
    return root.gridDistance(a, b) catch -1;
}

/// True iff a and b are neighbors. Returns false on error or non-neighbor.
export fn zig_h3_are_neighbor_cells(a: u64, b: u64) callconv(.c) bool {
    return root.areNeighborCells(a, b) catch false;
}

/// Single-cell gridDisk (k-disk). `out.len >= max_grid_disk_size(k)`.
/// Returns false on error.
export fn zig_h3_grid_disk(origin: u64, k: i32, out: [*]u64, out_len: usize) callconv(.c) bool {
    root.gridDisk(origin, k, out[0..out_len]) catch return false;
    return true;
}

/// Great-circle distance in km between two lat/lng points.
export fn zig_h3_great_circle_distance_km(a_lat: f64, a_lng: f64, b_lat: f64, b_lng: f64) callconv(.c) f64 {
    return root.greatCircleDistanceKm(
        .{ .lat = a_lat, .lng = a_lng },
        .{ .lat = b_lat, .lng = b_lng },
    );
}

/// Great-circle distance in radians.
export fn zig_h3_great_circle_distance_rads(a_lat: f64, a_lng: f64, b_lat: f64, b_lng: f64) callconv(.c) f64 {
    return root.greatCircleDistanceRads(
        .{ .lat = a_lat, .lng = a_lng },
        .{ .lat = b_lat, .lng = b_lng },
    );
}

/// Average hexagon area at the given resolution, in km².
export fn zig_h3_get_hexagon_area_avg_km2(res: i32) callconv(.c) f64 {
    return root.hexagonAreaAvgKm2(res) catch std.math.nan(f64);
}

/// Cell-specific area in km².
export fn zig_h3_cell_area_km2(cell: u64) callconv(.c) f64 {
    return root.cellAreaKm2(cell) catch std.math.nan(f64);
}

/// Number of unique cells at the given resolution.
export fn zig_h3_get_num_cells(res: i32) callconv(.c) i64 {
    return root.getNumCells(res) catch -1;
}

/// Average edge length at the given resolution, in km.
export fn zig_h3_get_hexagon_edge_length_avg_km(res: i32) callconv(.c) f64 {
    return root.hexagonEdgeLengthAvgKm(res) catch std.math.nan(f64);
}

// ============================================================================
// Convenience functions that go BEYOND libh3 — closes axis 1 ("we lead")
// ============================================================================

/// Compute the great-circle distance (in km) between the centroids of two
/// cells. Combines cellToLatLng + greatCircleDistanceKm in one call to save
/// a round-trip per binding. Returns NaN on error.
export fn zig_h3_cell_centroid_distance_km(a: u64, b: u64) callconv(.c) f64 {
    const ll_a = root.cellToLatLng(a) catch return std.math.nan(f64);
    const ll_b = root.cellToLatLng(b) catch return std.math.nan(f64);
    return root.greatCircleDistanceKm(ll_a, ll_b);
}

/// cellToParentN — walk up N hierarchy levels in one call.
/// Convenience that libh3 doesn't ship. Returns 0 on error.
export fn zig_h3_cell_to_parent_n(cell: u64, levels: i32) callconv(.c) u64 {
    if (levels < 0) return 0;
    const res = root.getResolution(cell);
    const target_res = res - levels;
    if (target_res < 0) return 0;
    return root.cellToParent(cell, target_res) catch 0;
}
