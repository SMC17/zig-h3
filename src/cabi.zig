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
    return "1.3.1";
}
