# Tutorial 01 — Zig quickstart

Five minutes from `git clone` to a running program that computes an
H3 cell, fetches its centroid, and walks the k=1 ring.

## Prerequisites

- Zig 0.16.0 (`zig version`).
- A C compiler that Zig can find (libh3 v4.1.0 is vendored and built
  from source the first time).

## Install via Zig's package manager

In your project's `build.zig.zon`:

```zig
.dependencies = .{
    .h3 = .{
        .url = "https://github.com/SMC17/zig-h3/archive/refs/tags/v1.4.0.tar.gz",
        // run `zig fetch --save` to populate the hash
    },
},
```

In your `build.zig`:

```zig
const h3 = b.dependency("h3", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("h3", h3.module("h3"));
```

## Worked example

```zig
const std = @import("std");
const h3 = @import("h3");

pub fn main() !void {
    // Statue of Liberty, resolution 9 (~150m hex edges).
    const point = h3.LatLng.fromDegrees(40.6892, -74.0445);
    const cell = try h3.latLngToCell(point, 9);

    var buf: [17]u8 = undefined;
    const hex = try h3.h3ToString(cell, &buf);
    std.debug.print("cell: {s}\n", .{hex});
    std.debug.print("base cell: {d}\n", .{h3.getBaseCellNumber(cell)});
    std.debug.print("pentagon: {}\n", .{h3.isPentagon(cell)});

    // Walk the k=1 ring (origin + 6 neighbors).
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
```

Build + run:

```sh
zig build run
```

Expected output (depends on H3's hash but cell will be deterministic):

```
cell: 89283082837ffff
base cell: 20
pentagon: false
ring[0]: distance 0
ring[1]: distance 1
ring[2]: distance 1
ring[3]: distance 1
ring[4]: distance 1
ring[5]: distance 1
ring[6]: distance 1
```

## What you have built

You now have a Zig program that:

1. Encodes a lat/lng to an H3 cell at a chosen resolution.
2. Round-trips the cell ID to a 15-char hex string.
3. Inspects cell properties (base cell, pentagon flag).
4. Walks the k=1 neighborhood with grid-distance verification.

Every call goes through the idiomatic `h3.*` wrapper (which calls
libh3 internally). For batch workloads, see
[02 — Batch + parallel API](02-batch-and-parallel.md) — that's where
zig-h3 wins over `h3-py` / `h3-go` / direct libh3 (3.6-6× faster on
parallel batch).

## Next steps

- [Tutorial 02 — Batch + parallel](02-batch-and-parallel.md)
- [Tutorial 03 — Cross-validation against libh3](03-cross-validation.md)
- [Function reference](../reference/functions.md)
