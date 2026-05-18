# Tutorial 03 — Cross-validation against libh3

zig-h3 ships **two parallel implementations** of every load-bearing
H3 function: the libh3 wrapper layer (`h3.*`) and the pure-Zig
reimplementation (`h3.h3index.*`, `h3.h3decode.*`, `h3.grid.*`,
etc.). Both are compiled into the same binary, and every test
cross-validates one against the other.

This tutorial shows how to use that cross-validation directly in
your code — useful for differential testing, regression guards,
and verifying that a future libh3 update doesn't drift from spec.

## Why two implementations?

Because we needed to prove the pure-Zig port is correct, the only
way is to A/B against the canonical C reference. The infrastructure
that runs ~27 000 cross-validation cases per `zig build test` is the
same machinery you can use in your own application:

```zig
const std = @import("std");
const h3 = @import("h3");

pub fn main() !void {
    const point = h3.LatLng.fromDegrees(40.6892, -74.0445);

    // Two paths to the same answer
    const via_libh3 = try h3.latLngToCell(point, 9);
    const via_pure = try h3.h3index.latLngToCell(point, 9);

    if (via_libh3 != via_pure) {
        std.debug.print("DIVERGENCE: libh3={x} pure={x}\n", .{
            via_libh3, via_pure,
        });
        return error.PureZigDivergence;
    }
    std.debug.print("OK: cell={x}\n", .{via_libh3});
}
```

## Use case: regression-guard a deployment pipeline

If you deploy `zig-h3` to a production service, you can run a
cross-validation sweep as a startup check:

```zig
const std = @import("std");
const h3 = @import("h3");

pub fn crossValidationSelfTest() !void {
    // Walk 1000 deterministic points × all 16 resolutions = 16 000 cases.
    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const lat = (prng.random().float(f64) - 0.5) * 178.0;
        const lng = (prng.random().float(f64) - 0.5) * 358.0;
        const p = h3.LatLng.fromDegrees(lat, lng);
        var res: i32 = 0;
        while (res <= 15) : (res += 1) {
            const a = try h3.latLngToCell(p, res);
            const b = try h3.h3index.latLngToCell(p, res);
            if (a != b) return error.LatLngToCellDivergence;
        }
    }
}
```

If libh3 ever updates and produces different cell IDs than our
pure-Zig path, your service refuses to start. That's the same
guard our CI uses on every push.

## Use case: differential test before deploy

In CI:

```sh
zig build test --summary all
```

The 5 exhaustive corpora + 2 Monte Carlo loops run automatically
and cover 27 000+ cases per invocation. Add your own custom
cross-validation cases in a `test "..."` block:

```zig
test "my domain: every cell at every res in my service region" {
    const my_region = [_]h3.LatLng{
        // ... your service's lat/lng inputs ...
    };
    for (my_region) |point| {
        var res: i32 = 0;
        while (res <= 15) : (res += 1) {
            const libh3_cell = try h3.latLngToCell(point, res);
            const pure_cell = try h3.h3index.latLngToCell(point, res);
            try std.testing.expectEqual(libh3_cell, pure_cell);
        }
    }
}
```

## What's NOT cross-validated

Not every libh3 surface has a pure-Zig parallel. Specifically:

- The polygon → cells `LinkedMultiPolygon` chain. The polygon code
  has a pure-Zig path at `h3.polygon.*` but the linked-output side
  is wrapper-only.
- Cell area / edge length in km² and m². These are exposed only via
  the wrapper.

For these, you have one source of truth (libh3) and no internal
differential. If you need differential coverage on these, file an
issue or contribute a pure-Zig port.

## Next

- [Function reference](../reference/functions.md) for the full API.
- [Internals → pure-Zig vs libh3](../internals/pure-zig-vs-libh3.md)
  for the why-and-how of two implementations.
