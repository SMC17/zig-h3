//! gridDisk throughput benchmark for zig-h3 (libh3-backed wrapper).
//!
//! For resolutions 7, 9, 11 and k = 1, 3, 5 — measure gridDisk traversal on a
//! random sample of origin cells. Each gridDisk call fills `1 + 3*k*(k+1)`
//! cells, so cells/sec is the load-bearing throughput metric (e.g. for
//! polygon-rasterisation workloads).
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

const origin_count: usize = 1_000;
const calls_per_origin: usize = 100;
const warmup_iters: usize = 1_000;

const resolutions = [_]i32{ 7, 9, 11 };
const ks = [_]i32{ 1, 3, 5 };

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // Pre-resolve a deterministic set of origin cells at each resolution.
    var rng = std.Random.DefaultPrng.init(0xDA1A_C0DE_60A1_BE17);
    const r = rng.random();
    const points = try allocator.alloc(h3.LatLng, origin_count);
    defer allocator.free(points);
    for (points) |*p| {
        p.* = .{
            .lat = (r.float(f64) - 0.5) * std.math.pi,
            .lng = (r.float(f64) - 0.5) * 2.0 * std.math.pi,
        };
    }

    // Largest needed scratch buffer is for the largest k in the matrix.
    const max_k = blk: {
        var m: i32 = 0;
        for (ks) |k| if (k > m) {
            m = k;
        };
        break :blk m;
    };
    const max_disk_size = try h3.maxGridDiskSize(max_k);
    const scratch = try allocator.alloc(h3.H3Index, @intCast(max_disk_size));
    defer allocator.free(scratch);

    std.debug.print("# zig-h3 bench: gridDisk (ReleaseFast, MONOTONIC ns)\n", .{});

    for (resolutions) |res| {
        // Resolve origins for this resolution.
        const origins = try allocator.alloc(h3.H3Index, origin_count);
        defer allocator.free(origins);
        for (points, 0..) |p, i| origins[i] = try h3.latLngToCell(p, res);

        for (ks) |k| {
            const disk_size: usize = @intCast(try h3.maxGridDiskSize(k));
            const slice = scratch[0..disk_size];

            // Warm-up — discarded.
            var w: usize = 0;
            while (w < warmup_iters) : (w += 1) {
                try h3.gridDisk(origins[w % origin_count], k, slice);
                std.mem.doNotOptimizeAway(slice[0]);
            }

            const total_calls = origin_count * calls_per_origin;
            const t0 = nanos();
            var i: usize = 0;
            while (i < total_calls) : (i += 1) {
                try h3.gridDisk(origins[i % origin_count], k, slice);
                std.mem.doNotOptimizeAway(slice[0]);
            }
            const total_ns = nanos() - t0;

            const ns_per_op = total_ns / total_calls;
            const total_cells: u128 = @as(u128, total_calls) * @as(u128, disk_size);
            const cells_per_sec: u128 =
                (total_cells * @as(u128, std.time.ns_per_s)) /
                @max(@as(u128, total_ns), 1);
            const ops_per_sec: u128 =
                (@as(u128, total_calls) * @as(u128, std.time.ns_per_s)) /
                @max(@as(u128, total_ns), 1);

            std.debug.print(
                "bench=gridDisk res={d} k={d} disk_size={d} op=GRID_DISK iters={d} total_ns={d} ns_per_op={d} ops_per_sec={d} cells_per_sec={d}\n",
                .{ res, k, disk_size, total_calls, total_ns, ns_per_op, ops_per_sec, cells_per_sec },
            );
        }
    }
}
