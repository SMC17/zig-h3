// examples/quickstart.zig
//
// This file is the README "Quickstart" code block, vendored verbatim
// (lines 109..134 of README.md). It exists so the documentation claim is
// EXECUTABLE: `tools/doctest.sh` extracts the block from README and
// diffs against this file; drift between README and code FAILS the
// doc-test. The build wires this as `zig build example-quickstart`,
// which compiles + runs the program — a non-zero exit signals a
// regression.
//
// If you edit the README Quickstart, you MUST update this file too.
// Conversely, if you change the API, you MUST update the README
// Quickstart. The doctest enforces the contract.

const std = @import("std");
const h3 = @import("h3");

pub fn main() !void {
    // Statue of Liberty, resolution 9.
    const point = h3.LatLng.fromDegrees(40.6892, -74.0445);
    const cell = try h3.latLngToCell(point, 9);

    var buf: [17]u8 = undefined;
    const hex = try h3.h3ToString(cell, &buf);
    std.debug.print("cell: {s}\n", .{hex});
    std.debug.print("resolution: {d}\n", .{h3.getResolution(cell)});
    std.debug.print("base cell: {d}\n", .{h3.getBaseCellNumber(cell)});
    std.debug.print("pentagon: {}\n", .{h3.isPentagon(cell)});

    // Walk the k=1 ring.
    var ring: [7]h3.H3Index = undefined;
    try h3.gridDisk(cell, 1, &ring);
    for (ring, 0..) |neighbor, i| {
        if (neighbor == h3.H3_NULL) continue;
        std.debug.print("ring[{d}]: distance {d}\n", .{
            i,
            try h3.gridDistance(cell, neighbor),
        });
    }
}
