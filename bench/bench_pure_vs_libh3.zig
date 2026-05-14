//! Pure-Zig vs libh3 throughput comparison for zig-h3.
//!
//! This is the killer chart for the v0.1.0 pure-Zig port. The C reference
//! `libh3` is built in via the existing `h3.*` API; the pure-Zig path is
//! exposed under `h3.h3index.latLngToCell` / `h3.h3decode.cellToLatLng` /
//! `h3.grid.gridDisk`. Both are run against the same deterministic input
//! stream so we can report side-by-side ns/op and a slowdown ratio.
//!
//! If pure-Zig is 5x slower, this benchmark reports 5x slower. The numbers
//! are honest; they're the only way to know whether the port is competitive
//! with the C reference (and where it isn't yet, what to optimise).
//!
//! Timing: `std.os.linux.clock_gettime(.MONOTONIC, &ts)` directly.

const std = @import("std");
const h3 = @import("h3");

inline fn nanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

const point_count: usize = 200_000;
const warmup_iters: usize = 5_000;

const Probe = struct {
    label: []const u8,
    res: i32,
};

const probes = [_]Probe{
    .{ .label = "res7", .res = 7 },
    .{ .label = "res9", .res = 9 },
    .{ .label = "res11", .res = 11 },
};

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    const points = try allocator.alloc(h3.LatLng, point_count);
    defer allocator.free(points);

    var rng = std.Random.DefaultPrng.init(0xDEAD_60A1_C0DE_BE17);
    const r = rng.random();
    for (points) |*p| {
        p.* = .{
            .lat = (r.float(f64) - 0.5) * std.math.pi,
            .lng = (r.float(f64) - 0.5) * 2.0 * std.math.pi,
        };
    }

    std.debug.print("# zig-h3 bench: pure-Zig vs libh3 (ReleaseFast, MONOTONIC ns)\n", .{});

    for (probes) |p| {
        // -------- latLngToCell: libh3 --------
        var w: usize = 0;
        while (w < warmup_iters) : (w += 1) {
            const cell = try h3.latLngToCell(points[w % point_count], p.res);
            std.mem.doNotOptimizeAway(cell);
        }
        var t0 = nanos();
        var i: usize = 0;
        while (i < point_count) : (i += 1) {
            const cell = try h3.latLngToCell(points[i], p.res);
            std.mem.doNotOptimizeAway(cell);
        }
        const libh3_ns = nanos() - t0;

        // -------- latLngToCell: pure-Zig --------
        w = 0;
        while (w < warmup_iters) : (w += 1) {
            const cell = try h3.h3index.latLngToCell(points[w % point_count], p.res);
            std.mem.doNotOptimizeAway(cell);
        }
        t0 = nanos();
        i = 0;
        while (i < point_count) : (i += 1) {
            const cell = try h3.h3index.latLngToCell(points[i], p.res);
            std.mem.doNotOptimizeAway(cell);
        }
        const pure_ns = nanos() - t0;

        const libh3_ns_per_op = libh3_ns / point_count;
        const pure_ns_per_op = pure_ns / point_count;
        const ratio_x1000: u128 =
            (@as(u128, pure_ns) * 1000) / @max(@as(u128, libh3_ns), 1);

        std.debug.print(
            "bench=latLngToCell.cmp {s} libh3_ns_per_op={d} pure_ns_per_op={d} pure_over_libh3_x1000={d} iters={d} libh3_total_ns={d} pure_total_ns={d}\n",
            .{ p.label, libh3_ns_per_op, pure_ns_per_op, ratio_x1000, point_count, libh3_ns, pure_ns },
        );

        // -------- cellToLatLng: cross-compare --------
        // Resolve cells once via libh3 (cheap) so both paths see identical input.
        const cells = try allocator.alloc(h3.H3Index, point_count);
        defer allocator.free(cells);
        for (points, 0..) |pt, idx| cells[idx] = try h3.latLngToCell(pt, p.res);

        w = 0;
        while (w < warmup_iters) : (w += 1) {
            const ll = try h3.cellToLatLng(cells[w % point_count]);
            std.mem.doNotOptimizeAway(ll.lat);
        }
        t0 = nanos();
        i = 0;
        while (i < point_count) : (i += 1) {
            const ll = try h3.cellToLatLng(cells[i]);
            std.mem.doNotOptimizeAway(ll.lat);
        }
        const libh3_dec_ns = nanos() - t0;

        w = 0;
        while (w < warmup_iters) : (w += 1) {
            const ll = try h3.h3decode.cellToLatLng(cells[w % point_count]);
            std.mem.doNotOptimizeAway(ll.lat);
        }
        t0 = nanos();
        i = 0;
        while (i < point_count) : (i += 1) {
            const ll = try h3.h3decode.cellToLatLng(cells[i]);
            std.mem.doNotOptimizeAway(ll.lat);
        }
        const pure_dec_ns = nanos() - t0;

        const libh3_dec_per_op = libh3_dec_ns / point_count;
        const pure_dec_per_op = pure_dec_ns / point_count;
        const dec_ratio_x1000: u128 =
            (@as(u128, pure_dec_ns) * 1000) / @max(@as(u128, libh3_dec_ns), 1);

        std.debug.print(
            "bench=cellToLatLng.cmp {s} libh3_ns_per_op={d} pure_ns_per_op={d} pure_over_libh3_x1000={d} iters={d} libh3_total_ns={d} pure_total_ns={d}\n",
            .{ p.label, libh3_dec_per_op, pure_dec_per_op, dec_ratio_x1000, point_count, libh3_dec_ns, pure_dec_ns },
        );
    }

    // -------- gridDisk k=3: cross-compare at res 9 --------
    const grid_res: i32 = 9;
    const k: i32 = 3;
    const disk_size: usize = @intCast(try h3.maxGridDiskSize(k));
    const scratch_libh3 = try allocator.alloc(h3.H3Index, disk_size);
    defer allocator.free(scratch_libh3);
    const scratch_pure = try allocator.alloc(h3.H3Index, disk_size);
    defer allocator.free(scratch_pure);

    const origin_pool = try allocator.alloc(h3.H3Index, 1_000);
    defer allocator.free(origin_pool);
    for (origin_pool, 0..) |*o, idx| o.* = try h3.latLngToCell(points[idx % point_count], grid_res);

    const grid_iters: usize = 50_000;

    var w: usize = 0;
    while (w < warmup_iters) : (w += 1) {
        try h3.gridDisk(origin_pool[w % origin_pool.len], k, scratch_libh3);
        std.mem.doNotOptimizeAway(scratch_libh3[0]);
    }
    var t0 = nanos();
    var i: usize = 0;
    while (i < grid_iters) : (i += 1) {
        try h3.gridDisk(origin_pool[i % origin_pool.len], k, scratch_libh3);
        std.mem.doNotOptimizeAway(scratch_libh3[0]);
    }
    const libh3_grid_ns = nanos() - t0;

    w = 0;
    while (w < warmup_iters) : (w += 1) {
        try h3.grid.gridDisk(origin_pool[w % origin_pool.len], k, allocator, scratch_pure);
        std.mem.doNotOptimizeAway(scratch_pure[0]);
    }
    t0 = nanos();
    i = 0;
    while (i < grid_iters) : (i += 1) {
        try h3.grid.gridDisk(origin_pool[i % origin_pool.len], k, allocator, scratch_pure);
        std.mem.doNotOptimizeAway(scratch_pure[0]);
    }
    const pure_grid_ns = nanos() - t0;

    const libh3_grid_per_op = libh3_grid_ns / grid_iters;
    const pure_grid_per_op = pure_grid_ns / grid_iters;
    const grid_ratio_x1000: u128 =
        (@as(u128, pure_grid_ns) * 1000) / @max(@as(u128, libh3_grid_ns), 1);

    std.debug.print(
        "bench=gridDisk.cmp res9_k3 libh3_ns_per_op={d} pure_ns_per_op={d} pure_over_libh3_x1000={d} iters={d} libh3_total_ns={d} pure_total_ns={d}\n",
        .{ libh3_grid_per_op, pure_grid_per_op, grid_ratio_x1000, grid_iters, libh3_grid_ns, pure_grid_ns },
    );
}
