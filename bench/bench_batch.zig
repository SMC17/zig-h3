//! Comparative batch latLngToCell throughput:
//!   - libh3 scalar (per-point libh3 call in a loop)
//!   - pure-Zig scalar (per-point pure-Zig call in a loop)
//!   - pure-Zig batch (amortized hot loop, single-threaded)
//!   - pure-Zig batch parallel (4-thread + 8-thread variants)
//!
//! Output is parseable `bench=NAME ... ns_per_op=N ops_per_sec=N` lines.
//! Run with `zig build bench-batch -Doptimize=ReleaseFast`.

const std = @import("std");
const h3 = @import("h3");

inline fn nanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

const point_count: usize = 100_000;
const warmup_points: usize = 5_000;
const probes = [_]struct { label: []const u8, res: i32 }{
    .{ .label = "res7", .res = 7 },
    .{ .label = "res9", .res = 9 },
    .{ .label = "res11", .res = 11 },
};

pub fn main() !void {
    const a = std.heap.smp_allocator;

    const points = try a.alloc(h3.LatLng, point_count);
    defer a.free(points);
    const out = try a.alloc(h3.H3Index, point_count);
    defer a.free(out);

    var rng = std.Random.DefaultPrng.init(0xDEAD_60A1_C0DE_BE17);
    const r = rng.random();
    for (points) |*p| {
        p.* = .{
            .lat = (r.float(f64) - 0.5) * std.math.pi,
            .lng = (r.float(f64) - 0.5) * 2.0 * std.math.pi,
        };
    }

    std.debug.print("# zig-h3 bench: comparative batch latLngToCell (ReleaseFast, MONOTONIC ns)\n", .{});
    std.debug.print("# host cores: {d}\n", .{try std.Thread.getCpuCount()});

    for (probes) |p| {
        // --- libh3 scalar ---
        var w: usize = 0;
        while (w < warmup_points) : (w += 1) {
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

        // --- pure-Zig scalar ---
        w = 0;
        while (w < warmup_points) : (w += 1) {
            const cell = try h3.h3index.latLngToCell(points[w % point_count], p.res);
            std.mem.doNotOptimizeAway(cell);
        }
        t0 = nanos();
        i = 0;
        while (i < point_count) : (i += 1) {
            const cell = try h3.h3index.latLngToCell(points[i], p.res);
            std.mem.doNotOptimizeAway(cell);
        }
        const pure_scalar_ns = nanos() - t0;

        // --- pure-Zig batch (single-thread amortized) ---
        // Warmup
        _ = h3.h3index.latLngToCellBatch(points[0..warmup_points], p.res, out[0..warmup_points]);
        t0 = nanos();
        const ok_batch = h3.h3index.latLngToCellBatch(points, p.res, out);
        const batch_ns = nanos() - t0;
        std.mem.doNotOptimizeAway(ok_batch);

        // --- pure-Zig batch parallel (4-thread) ---
        _ = try h3.h3index.latLngToCellBatchParallel(a, points[0..warmup_points], p.res, out[0..warmup_points], 4);
        t0 = nanos();
        const ok4 = try h3.h3index.latLngToCellBatchParallel(a, points, p.res, out, 4);
        const par4_ns = nanos() - t0;
        std.mem.doNotOptimizeAway(ok4);

        // --- pure-Zig batch parallel (8-thread) ---
        _ = try h3.h3index.latLngToCellBatchParallel(a, points[0..warmup_points], p.res, out[0..warmup_points], 8);
        t0 = nanos();
        const ok8 = try h3.h3index.latLngToCellBatchParallel(a, points, p.res, out, 8);
        const par8_ns = nanos() - t0;
        std.mem.doNotOptimizeAway(ok8);

        const libh3_per = libh3_ns / point_count;
        const scalar_per = pure_scalar_ns / point_count;
        const batch_per = batch_ns / point_count;
        const par4_per = par4_ns / point_count;
        const par8_per = par8_ns / point_count;

        // Speedup ratios — pure_over_libh3 < 1.0 means pure-Zig is faster
        // (lower ns/op). 10× faster means ratio = 0.1.
        const scalar_ratio_x1000 = (pure_scalar_ns * 1000) / libh3_ns;
        const batch_ratio_x1000 = (batch_ns * 1000) / libh3_ns;
        const par4_ratio_x1000 = (par4_ns * 1000) / libh3_ns;
        const par8_ratio_x1000 = (par8_ns * 1000) / libh3_ns;

        std.debug.print(
            "bench=latLngToCell.libh3-scalar  res={s} ns_per_op={d} ops_per_sec={d}\n",
            .{ p.label, libh3_per, std.time.ns_per_s / libh3_per },
        );
        std.debug.print(
            "bench=latLngToCell.zig-scalar    res={s} ns_per_op={d} ops_per_sec={d} libh3_ratio_x1000={d}\n",
            .{ p.label, scalar_per, std.time.ns_per_s / scalar_per, scalar_ratio_x1000 },
        );
        std.debug.print(
            "bench=latLngToCell.zig-batch     res={s} ns_per_op={d} ops_per_sec={d} libh3_ratio_x1000={d}\n",
            .{ p.label, batch_per, std.time.ns_per_s / batch_per, batch_ratio_x1000 },
        );
        std.debug.print(
            "bench=latLngToCell.zig-par-4t    res={s} ns_per_op={d} ops_per_sec={d} libh3_ratio_x1000={d}\n",
            .{ p.label, par4_per, std.time.ns_per_s / par4_per, par4_ratio_x1000 },
        );
        std.debug.print(
            "bench=latLngToCell.zig-par-8t    res={s} ns_per_op={d} ops_per_sec={d} libh3_ratio_x1000={d}\n",
            .{ p.label, par8_per, std.time.ns_per_s / par8_per, par8_ratio_x1000 },
        );
    }

    // --- cellToLatLng batch + parallel ---
    // Pre-compute a fixed pool of cells to decode.
    const cell_count: usize = 100_000;
    const cells = try a.alloc(h3.H3Index, cell_count);
    defer a.free(cells);
    const ll_out = try a.alloc(h3.LatLng, cell_count);
    defer a.free(ll_out);
    for (cells, 0..) |*cell, i| {
        cell.* = try h3.latLngToCell(points[i % point_count], 9);
    }

    // Warmup
    _ = h3.h3decode.cellToLatLngBatch(cells[0..warmup_points], ll_out[0..warmup_points]);

    // libh3 scalar inverse
    var t0_inv = nanos();
    for (cells, 0..) |cell, i| {
        ll_out[i] = h3.cellToLatLng(cell) catch .{ .lat = 0, .lng = 0 };
    }
    const inv_libh3_ns = nanos() - t0_inv;

    // pure-Zig scalar inverse
    t0_inv = nanos();
    for (cells, 0..) |cell, i| {
        ll_out[i] = h3.h3decode.cellToLatLng(cell) catch .{ .lat = 0, .lng = 0 };
    }
    const inv_scalar_ns = nanos() - t0_inv;

    // pure-Zig batch
    t0_inv = nanos();
    _ = h3.h3decode.cellToLatLngBatch(cells, ll_out);
    const inv_batch_ns = nanos() - t0_inv;

    // pure-Zig parallel 8t
    t0_inv = nanos();
    _ = try h3.h3decode.cellToLatLngBatchParallel(a, cells, ll_out, 8);
    const inv_par8_ns = nanos() - t0_inv;

    std.debug.print(
        "bench=cellToLatLng.libh3-scalar res=res9 ns_per_op={d} ops_per_sec={d}\n",
        .{ inv_libh3_ns / cell_count, std.time.ns_per_s / (inv_libh3_ns / cell_count) },
    );
    std.debug.print(
        "bench=cellToLatLng.zig-scalar   res=res9 ns_per_op={d} ops_per_sec={d} libh3_ratio_x1000={d}\n",
        .{ inv_scalar_ns / cell_count, std.time.ns_per_s / (inv_scalar_ns / cell_count), (inv_scalar_ns * 1000) / inv_libh3_ns },
    );
    std.debug.print(
        "bench=cellToLatLng.zig-batch    res=res9 ns_per_op={d} ops_per_sec={d} libh3_ratio_x1000={d}\n",
        .{ inv_batch_ns / cell_count, std.time.ns_per_s / (inv_batch_ns / cell_count), (inv_batch_ns * 1000) / inv_libh3_ns },
    );
    std.debug.print(
        "bench=cellToLatLng.zig-par-8t   res=res9 ns_per_op={d} ops_per_sec={d} libh3_ratio_x1000={d}\n",
        .{ inv_par8_ns / cell_count, std.time.ns_per_s / (inv_par8_ns / cell_count), (inv_par8_ns * 1000) / inv_libh3_ns },
    );

    // --- gridDisk batch + parallel ---
    const origin_count: usize = 10_000;
    const origins = try a.alloc(h3.H3Index, origin_count);
    defer a.free(origins);
    for (origins, 0..) |*o, i| {
        o.* = try h3.latLngToCell(points[i % point_count], 9);
    }
    const k_val: i32 = 3;
    const stride: usize = @intCast(try h3.maxGridDiskSize(k_val));
    const disk_out = try a.alloc(h3.H3Index, origin_count * stride);
    defer a.free(disk_out);

    // libh3 scalar
    var t0d = nanos();
    var di: usize = 0;
    while (di < origin_count) : (di += 1) {
        const slice = disk_out[di * stride .. (di + 1) * stride];
        h3.gridDisk(origins[di], k_val, slice) catch {};
    }
    const disk_libh3_ns = nanos() - t0d;

    // pure-Zig batch
    t0d = nanos();
    _ = try h3.gridDiskBatch(a, origins, k_val, stride, disk_out);
    const disk_batch_ns = nanos() - t0d;

    // pure-Zig parallel 8t
    t0d = nanos();
    _ = try h3.gridDiskBatchParallel(a, origins, k_val, stride, disk_out, 8);
    const disk_par8_ns = nanos() - t0d;

    std.debug.print(
        "bench=gridDisk.libh3-scalar res=res9 k={d} disk_size={d} ns_per_origin={d} origins_per_sec={d}\n",
        .{ k_val, stride, disk_libh3_ns / origin_count, std.time.ns_per_s / (disk_libh3_ns / origin_count) },
    );
    std.debug.print(
        "bench=gridDisk.zig-batch    res=res9 k={d} disk_size={d} ns_per_origin={d} origins_per_sec={d} libh3_ratio_x1000={d}\n",
        .{ k_val, stride, disk_batch_ns / origin_count, std.time.ns_per_s / (disk_batch_ns / origin_count), (disk_batch_ns * 1000) / disk_libh3_ns },
    );
    std.debug.print(
        "bench=gridDisk.zig-par-8t   res=res9 k={d} disk_size={d} ns_per_origin={d} origins_per_sec={d} libh3_ratio_x1000={d}\n",
        .{ k_val, stride, disk_par8_ns / origin_count, std.time.ns_per_s / (disk_par8_ns / origin_count), (disk_par8_ns * 1000) / disk_libh3_ns },
    );
}
