# Batch API reference

The 6 batch + parallel functions added in v1.4.0. All live in
[`src/pure_h3index.zig`](../../src/pure_h3index.zig) +
[`src/pure_h3decode.zig`](../../src/pure_h3decode.zig) +
[`src/pure_grid.zig`](../../src/pure_grid.zig) and are re-exported
from [`src/root.zig`](../../src/root.zig).

## `latLngToCellBatch`

```zig
pub fn latLngToCellBatch(
    points: []const LatLng,
    res: i32,
    out: []H3Index,
) usize
```

Single-threaded amortized batch. Returns count of successful
conversions. Non-finite lat/lng or out-of-range `res` produces an
`H3_NULL=0` slot in `out`.

**Contract**: `out.len >= points.len`.

## `latLngToCellBatchParallel`

```zig
pub fn latLngToCellBatchParallel(
    allocator: std.mem.Allocator,
    points: []const LatLng,
    res: i32,
    out: []H3Index,
    thread_count: usize,
) !usize
```

Multi-threaded variant. Spawns `thread_count` workers via
`std.Thread.spawn`, splits `points` across them, joins before
return. Returns total successful count.

**Notes**:
- Below 1024 points OR `thread_count <= 1`, falls back to serial.
- Allocator must be thread-safe.
- Tested on a 4096-point cross-validation against the scalar path
  in `pure_h3index.zig`.

## `cellToLatLngBatch`

```zig
pub fn cellToLatLngBatch(
    cells: []const H3Index,
    out: []LatLng,
) usize
```

Inverse of `latLngToCellBatch`. Invalid cells produce NaN-LatLng.

## `cellToLatLngBatchParallel`

```zig
pub fn cellToLatLngBatchParallel(
    allocator: std.mem.Allocator,
    cells: []const H3Index,
    out: []LatLng,
    thread_count: usize,
) !usize
```

Parallel inverse. Same fallback rules as `latLngToCellBatchParallel`.

## `gridDiskBatch`

```zig
pub fn gridDiskBatch(
    allocator: std.mem.Allocator,
    origins: []const H3Index,
    k: i32,
    stride: usize,
    out: []H3Index,
) !usize
```

For each origin, computes the k-disk into a contiguous slice of
`stride` cells in `out[i*stride .. (i+1)*stride]`. `stride` should
equal `maxGridDiskSize(k)`. Origins whose disk hits a pentagon edge
produce all-zero slots.

**Contract**: `out.len >= origins.len * stride`.

## `gridDiskBatchParallel`

```zig
pub fn gridDiskBatchParallel(
    allocator: std.mem.Allocator,
    origins: []const H3Index,
    k: i32,
    stride: usize,
    out: []H3Index,
    thread_count: usize,
) !usize
```

Parallel. Below 64 origins OR `thread_count <= 1`, falls back to
serial. Tested on 256-origin cross-validation against scalar.

## Performance (Intel i7-1065G7, ReleaseFast)

See [`../../BENCH.md`](../../BENCH.md) for the full table. Headlines:

| Operation              | libh3 scalar | Zig par-8t | Speedup |
|------------------------|-------------:|-----------:|--------:|
| latLngToCell res9      | 3001 ns/op   | 558 ns/op  | **5.4×** |
| cellToLatLng res9      | 1617 ns/op   | 441 ns/op  | **3.7×** |
| gridDisk(k=3) res9     | 6297 ns/op   | 1690 ns/op | **3.7×** |

## C-ABI export

Each function has a matching `extern "C"` export in
[`src/cabi.zig`](../../src/cabi.zig). The shim is what Python ctypes
+ Go cgo bindings call into.

| Zig                            | C-ABI symbol                              |
|--------------------------------|-------------------------------------------|
| latLngToCellBatch              | zig_h3_latlng_to_cell_batch               |
| latLngToCellBatchParallel      | zig_h3_latlng_to_cell_batch_parallel      |
| cellToLatLngBatch              | zig_h3_cell_to_latlng_batch               |
| cellToLatLngBatchParallel      | zig_h3_cell_to_latlng_batch_parallel      |
| gridDiskBatch                  | zig_h3_grid_disk_batch                    |
| gridDiskBatchParallel          | zig_h3_grid_disk_batch_parallel           |

See [`../bindings/c-abi.md`](../bindings/c-abi.md) for the full
C-ABI surface including the helper functions.
