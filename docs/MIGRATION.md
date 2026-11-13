# Migration guide

Per-version migration paths for downstream consumers. This document
exists because BAKEOFF axis 11 (API stability) explicitly named
"Uber ships migration guides; we don't" as a gap. Closing it.

## v0.x → v1.0

The v0.x line covered ~14 of libh3's 70 public functions. v1.0 added
the remaining 56 + production-grade hygiene (LICENSE, SECURITY,
CONTRIBUTING, CODE_OF_CONDUCT, dependabot).

**No source-level breaks** — every v0.x function still works in v1.0
with the same signature. v1.0 only adds.

If you used the `raw` C-bindings escape hatch in v0.x, those calls
still work but now have an idiomatic Zig sibling. Prefer the
idiomatic version when porting:

```zig
// v0.x
var out: c.H3Index = 0;
try check(c.latLngToCell(&ll, res, &out));

// v1.0
const cell = try h3.latLngToCell(point, res);  // typed Error!H3Index
```

## v1.0 → v1.1

Wraps the libh3 polygon / vertex / directed-edge / local-IJ /
grid-path / compact APIs that v1.0 left in the `raw` escape hatch.

**No source-level breaks.** v1.0 code continues to compile against
v1.1. The new public functions are added next to the existing ones.

## v1.1 → v1.2

Hits 70/70 libh3 coverage. Adds `tools/coverage-check.sh` regression
guard. **No source-level breaks.**

## v1.2 → v1.3

Adds:
- **190 tests** including the 16-operator mutation testing harness,
  the 10k-trial H3-invariant property harness, the 2000-trial
  polygon round-trip, exhaustive resolution-sweep, and BAKEOFF.md.

**No source-level breaks.** This release was purely test-coverage
work + first-pass BAKEOFF audit.

## v1.3 → v1.4

The big one. **No source-level breaks**, but several **additions**
that users should adopt for new code:

### Batch API (new — adopt when you have 1000+ points)

```zig
// v1.3 — single-call loop
for (points) |p| {
    const cell = try h3.latLngToCell(p, res);
    // ...
}

// v1.4 — amortized + parallel (3.6-6× faster on 4C/8T)
const out = try allocator.alloc(h3.H3Index, points.len);
_ = try h3.latLngToCellBatchParallel(allocator, points, res, out, 8);
```

Same shape for the inverse and grid disk:
- `cellToLatLngBatch[Parallel](allocator?, cells, out[, threads])`
- `gridDiskBatch[Parallel](allocator, origins, k, stride, out[, threads])`

The serial `latLngToCell(point, res)` etc. continue to work
unchanged. The batch versions are pure additions.

### Composite functions beyond libh3

```zig
// All new in v1.4 — saves a per-call round-trip
const dist_km = h3.cellCentroidDistanceKm(cell_a, cell_b);
const cell7 = try h3.cellToParentN(cell9, 2);
_ = try h3.cellsKNearest(point, 6, 9, allocator, out_buf);  // 6 neighbors
_ = try h3.cellsInBbox(s_lat, w_lng, n_lat, e_lng, res, allocator, out);
```

### C-ABI shim library

v1.4 ships `libzig_h3.so` + `libzig_h3_static.a` alongside the Zig
module. Any C-FFI-capable language can link the shim:

```sh
zig build -Doptimize=ReleaseFast
ls zig-out/lib/
# libzig_h3.so
# libzig_h3_static.a
```

Bindings ship at `bindings/python/`, `bindings/go/zigh3/`,
`bindings/rust/zigh3/`, `bindings/node/zigh3/`.

### Python binding — degrees default (v0.2.0 → v0.3.0)

**The one wire-protocol-incompatible change** in the v1.4 line:

```python
# v0.2.0 — silently treated input as radians (Type-1 bug)
import zig_h3
import numpy as np
cells = zig_h3.latlng_to_cell_batch(np.array([[40.6892, -74.0445]]), res=9)
# Returned WRONG cell — 40.6892 interpreted as radians (~2331°)

# v0.3.0 — defaults to degrees (matches h3-py)
cells = zig_h3.latlng_to_cell_batch(np.array([[40.6892, -74.0445]]), res=9)
# Returns 0x892a1072b5bffff (correct NYC res 9 cell)
```

If you wrote v0.2.0 code that converted to radians manually before
calling, pass `units="radians"` to skip the v0.3.0 conversion:

```python
points_rad = np.deg2rad(points_deg)
cells = zig_h3.latlng_to_cell_batch(points_rad, res=9, units="radians")
```

The Go, Rust, and Node bindings shipped degrees as the default from
day one (the bug was Python-only).

## Compatibility matrix

| Your code calls...    | Works on v1.0 | v1.1 | v1.2 | v1.3 | v1.4 |
|-----------------------|:-------------:|:----:|:----:|:----:|:----:|
| Core `h3.*` API       | ✓             | ✓    | ✓    | ✓    | ✓    |
| Polygon / vertex API  |               | ✓    | ✓    | ✓    | ✓    |
| `tools/coverage-check.sh` |           |      | ✓    | ✓    | ✓    |
| Property test harness |               |      |      | ✓    | ✓    |
| `*Batch[Parallel]` API|               |      |      |      | ✓    |
| Composite functions      |            |      |      |      | ✓    |
| `libzig_h3.so` C-ABI  |               |      |      |      | ✓    |

## Pre-v1.0 dependency pin

If you're stuck on an older Zig that can't take v1.4's `std.Thread`
batch path, pin to v1.3 in your `build.zig.zon`:

```zig
.h3 = .{
    .url = "https://github.com/SMC17/zig-h3/archive/refs/tags/v1.3.0.tar.gz",
    .hash = "...",  // fetch will fill in
},
```

## Reporting migration friction

If you hit a friction point during migration that this guide didn't
cover, open an issue with the `migration` label — we'll fold the
answer back into this document.
