//! Minimal zig-h3 example — index a Manhattan landmark, print the cell,
//! walk its k=1 ring of neighbors, show edge length and cell area.
//!
//! Build: `zig build example-nyc-neighbors`
//! Run:   `./zig-out/bin/example-nyc-neighbors`

const std = @import("std");
const h3 = @import("h3");

pub fn main() !void {
    // Times Square, resolution 9 (~0.105 km² average cell area).
    const times_sq = h3.LatLng.fromDegrees(40.7580, -73.9855);
    const cell = try h3.latLngToCell(times_sq, 9);

    var hex_buf: [17]u8 = undefined;
    const hex = try h3.h3ToString(cell, &hex_buf);

    std.debug.print("Times Square at res 9:\n", .{});
    std.debug.print("  cell        = {s}\n", .{hex});
    std.debug.print("  resolution  = {d}\n", .{h3.getResolution(cell)});
    std.debug.print("  base cell   = {d}\n", .{h3.getBaseCellNumber(cell)});
    std.debug.print("  pentagon    = {}\n", .{h3.isPentagon(cell)});
    std.debug.print("  area        = {d:.6} km²\n", .{try h3.cellAreaKm2(cell)});
    std.debug.print("  edge avg    = {d:.4} km\n", .{try h3.hexagonEdgeLengthAvgKm(9)});

    std.debug.print("\nk=1 neighbors:\n", .{});
    var ring: [7]h3.H3Index = undefined;
    try h3.gridDisk(cell, 1, &ring);
    for (ring) |neighbor| {
        if (neighbor == h3.H3_NULL) continue;
        const dist = try h3.gridDistance(cell, neighbor);
        const ll = try h3.cellToLatLng(neighbor);
        const ns = try h3.h3ToString(neighbor, &hex_buf);
        std.debug.print("  {s}  distance={d}  lat={d:.4}°  lng={d:.4}°\n", .{
            ns,
            dist,
            ll.latDegrees(),
            ll.lngDegrees(),
        });
    }

    // Demonstrate the pure-Zig parallel track — same answer, no C dependency
    // at this layer.
    const pure_cell = try h3.h3index.latLngToCell(times_sq, 9);
    std.debug.assert(pure_cell == cell);
    std.debug.print("\npure-Zig path produced identical cell — libh3 cross-validation OK\n", .{});
}
