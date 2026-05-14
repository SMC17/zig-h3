//! latLngToCell throughput benchmark for zig-h3 (libh3-backed wrapper).
//!
//! At resolutions 7, 9, 11, 13, 15, run a fixed-size deterministic stream of
//! random lat/lng points through `h3.latLngToCell` and report ns per call and
//! ops per second. Resolution affects the inverse-projection cost via the
//! aperture-7 step count; this benchmark surfaces that scaling.
//!
//! Timing: `std.os.linux.clock_gettime(.MONOTONIC, &ts)` directly — Zig 0.16
//! removed `std.time.Timer` and `std.time.nanoTimestamp`.
//!
//! Output is parseable `key=value` whitespace-separated.

const std = @import("std");
const h3 = @import("h3");

inline fn nanos() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

const point_count: usize = 1_000_000;
const warmup_iters: usize = 10_000;

const resolutions = [_]i32{ 7, 9, 11, 13, 15 };

pub fn main() !void {
    const allocator = std.heap.smp_allocator;

    // Pre-generate the random lat/lng stream once and reuse it across all
    // resolutions so we're measuring the H3 path, not the RNG.
    const points = try allocator.alloc(h3.LatLng, point_count);
    defer allocator.free(points);

    var rng = std.Random.DefaultPrng.init(0xC0DE_BE17_C0DE_DEAD);
    const r = rng.random();
    for (points) |*p| {
        // Uniform-ish across the sphere: lat in [-π/2, π/2], lng in [-π, π].
        // (Not equal-area uniform, but representative of real-world workloads
        // that index addresses / GPS pings.)
        p.* = .{
            .lat = (r.float(f64) - 0.5) * std.math.pi,
            .lng = (r.float(f64) - 0.5) * 2.0 * std.math.pi,
        };
    }

    std.debug.print("# zig-h3 bench: latLngToCell (ReleaseFast, MONOTONIC ns)\n", .{});

    for (resolutions) |res| {
        // Warm-up — discarded.
        var w: usize = 0;
        while (w < warmup_iters) : (w += 1) {
            const cell = try h3.latLngToCell(points[w % point_count], res);
            std.mem.doNotOptimizeAway(cell);
        }

        const t0 = nanos();
        var i: usize = 0;
        while (i < point_count) : (i += 1) {
            const cell = try h3.latLngToCell(points[i], res);
            std.mem.doNotOptimizeAway(cell);
        }
        const total_ns = nanos() - t0;

        const ns_per_op = total_ns / point_count;
        const ops_per_sec: u128 =
            (@as(u128, point_count) * @as(u128, std.time.ns_per_s)) /
            @max(@as(u128, total_ns), 1);

        std.debug.print(
            "bench=latLngToCell res={d} op=LATLNG_TO_CELL iters={d} total_ns={d} ns_per_op={d} ops_per_sec={d}\n",
            .{ res, point_count, total_ns, ns_per_op, ops_per_sec },
        );
    }
}
