# Tutorial 02 — Batch + parallel API

The 6 batch + parallel functions added in v1.4.0 are what makes
zig-h3 worth using over libh3 directly: 3.6-6× faster on multi-core
systems with no API surface complexity.

## The mental model

For each of the three hot primitives — `latLngToCell`, `cellToLatLng`,
`gridDisk` — there are three variants:

| Variant         | Use when                                       |
|-----------------|------------------------------------------------|
| **scalar**      | Single call (e.g., a user clicks a map pin)   |
| **batch**       | 10+ calls in a row (amortizes overhead)       |
| **batchParallel** | 1000+ calls (splits across N threads)        |

The batch + parallel APIs accept slices, return slices. No per-call
allocator pressure, no Zig-Error-Set ABI cost across the loop body.

## Worked example: process 100k random points

```zig
const std = @import("std");
const h3 = @import("h3");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const N = 100_000;
    const points = try a.alloc(h3.LatLng, N);
    defer a.free(points);
    const out = try a.alloc(h3.H3Index, N);
    defer a.free(out);

    var prng = std.Random.DefaultPrng.init(42);
    for (points) |*p| {
        const lat = (prng.random().float(f64) - 0.5) * 178.0;
        const lng = (prng.random().float(f64) - 0.5) * 358.0;
        p.* = h3.LatLng.fromDegrees(lat, lng);
    }

    // 8-thread parallel batch — splits across CPU cores
    const ok = try h3.latLngToCellBatchParallel(a, points, 9, out, 8);
    std.debug.print("encoded {d} of {d} points\n", .{ ok, N });

    // Compute the gridDisk(k=2) of each cell — also batchable
    const stride: usize = @intCast(try h3.maxGridDiskSize(2));
    const disks = try a.alloc(h3.H3Index, N * stride);
    defer a.free(disks);
    _ = try h3.gridDiskBatchParallel(a, out, 2, stride, disks, 8);

    std.debug.print("computed {d} disks, total {d} cells\n", .{
        N, N * stride,
    });
}
```

## Performance reference

From [`../../BENCH.md`](../../BENCH.md), Intel i7-1065G7, ReleaseFast,
MONOTONIC timing:

| Primitive (res 9)        | libh3 ns/op | Zig parallel-8t ns/op | Speedup |
|--------------------------|-------------|-----------------------|---------|
| latLngToCell             | 3001        | 558                   | **5.4×** |
| cellToLatLng             | 1617        | 441                   | **3.7×** |
| gridDisk(k=3)            | 6297        | 1690                  | **3.7×** |

The parallel path only beats serial above ~1000 points (thread spawn
overhead dominates below). The batch API auto-degenerates to serial
in that case — calling `batchParallel(..., 4)` with 500 points is
safe and uses the serial code internally.

## Failure modes

Each batch function returns a count of *successes*:

```zig
const ok = h3.latLngToCellBatch(points, 9, out);
if (ok < points.len) {
    // Some points had non-finite lat/lng. Those slots are H3_NULL.
}
```

Per-slot validity check:

```zig
for (out, 0..) |cell, i| {
    if (cell == h3.H3_NULL) {
        std.debug.print("point[{d}] failed encoding\n", .{i});
    }
}
```

## Threading model

`*BatchParallel` functions use `std.Thread.spawn` internally:

- Threads are joined before return.
- The allocator must be thread-safe (`smp_allocator`,
  `GeneralPurposeAllocator` with `.thread_safe = true`,
  `c_allocator`, etc.).
- Each thread processes a roughly-equal slice of the input.

The implementation is `pure_h3index.zig:latLngToCellBatchParallel`
(and its peers); read those if you want to verify the threading is
race-free. The `4096-point parallel-vs-scalar cross-check` test in
the same file ensures correctness on every CI run.

## When to NOT use this

- **One call.** Use the scalar API; the batch entry has setup cost.
- **Below 1000 calls.** The serial batch is fine; the parallel one
  degrades to serial here anyway.
- **You need `gridDisk` with arbitrary k per origin.** Currently
  batch takes a single `k`; mixed-k workloads should loop the scalar
  version.

## Next

- [03 — Cross-validation against libh3](03-cross-validation.md)
- [Batch API reference](../reference/batch-api.md)
- [Parallel architecture](../internals/parallel-architecture.md)
