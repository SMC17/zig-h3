//! tests/h3py/h3py_diff.zig — runs a fixed set of zig-h3 queries against
//! the h3-py reference oracle (the official Python binding for Uber's
//! libh3). This is the **second-reference differential** — zig-h3's
//! existing tests cross-validate the pure-Zig backend against the
//! vendored libh3 C library (single reference), but both layers ultimately
//! consume the same libh3 source. The h3-py binding runs against the same
//! C library too, BUT through Python/Cython packaging, so it independently
//! confirms that our wrapper-level argument marshalling, return-value
//! handling, and string conversion all match what an external consumer
//! sees.
//!
//! This file emits a fixed query list to stdout. `tests/h3py/run.sh`
//! pipes it into the Python oracle and diffs the two outputs.

const std = @import("std");
const h3 = @import("h3");

const Query = struct {
    label: []const u8,
    lat_rad: f64,
    lng_rad: f64,
    res: i32,
};

const FIXTURES = [_]Query{
    // San Francisco (Pier 39): lat ≈ 37.808°, lng ≈ -122.410°
    .{ .label = "sf-pier-39", .lat_rad = 0.65993, .lng_rad = -2.13649, .res = 9 },
    // New York City (Times Square): lat ≈ 40.758°, lng ≈ -73.985°
    .{ .label = "nyc-times-sq", .lat_rad = 0.71135, .lng_rad = -1.29135, .res = 9 },
    // London (Westminster): lat ≈ 51.500°, lng ≈ -0.125°
    .{ .label = "london-westminster", .lat_rad = 0.89884, .lng_rad = -0.00218, .res = 9 },
    // Tokyo (Shibuya): lat ≈ 35.659°, lng ≈ 139.700°
    .{ .label = "tokyo-shibuya", .lat_rad = 0.62236, .lng_rad = 2.43824, .res = 9 },
    // Sydney (Opera House): lat ≈ -33.857°, lng ≈ 151.215°
    .{ .label = "sydney-opera", .lat_rad = -0.59093, .lng_rad = 2.63920, .res = 9 },
    // Coarse resolution stress: same SF coordinate at res 0, 5, 12.
    .{ .label = "sf-res-0", .lat_rad = 0.65993, .lng_rad = -2.13649, .res = 0 },
    .{ .label = "sf-res-5", .lat_rad = 0.65993, .lng_rad = -2.13649, .res = 5 },
    .{ .label = "sf-res-12", .lat_rad = 0.65993, .lng_rad = -2.13649, .res = 12 },
};

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [4 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const w = &stdout.interface;

    for (FIXTURES) |q| {
        const point: h3.LatLng = .{ .lat = q.lat_rad, .lng = q.lng_rad };
        const cell = try h3.latLngToCell(point, q.res);
        try w.print("{s} cell={x}\n", .{ q.label, cell });
        // Also exercise getResolution + isPentagon as round-trip sanity.
        const res = h3.getResolution(cell);
        try w.print("{s} resolution={d}\n", .{ q.label, res });
        try w.print("{s} pentagon={d}\n", .{ q.label, @intFromBool(h3.isPentagon(cell)) });
    }
    try w.flush();
}
