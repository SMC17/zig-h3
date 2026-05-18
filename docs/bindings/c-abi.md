# C-ABI shim (`libzig_h3.so`)

The C-ABI surface that all language bindings link against. Defined in
[`src/cabi.zig`](../../src/cabi.zig); built as both
`libzig_h3.so` (shared) and `libzig_h3_static.a` (static archive).

## Building

```sh
zig build -Doptimize=ReleaseFast
ls zig-out/lib/
# libzig_h3.so
# libzig_h3_static.a
```

Cross-compile examples:

```sh
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
```

## Surface

```c
#include <stdint.h>
#include <stddef.h>

// Lat/lng pair (radians, matching libh3's convention)
typedef struct {
    double lat;
    double lng;
} ZigH3LatLng;

// Forward batch
size_t zig_h3_latlng_to_cell_batch(
    const ZigH3LatLng* points, size_t n,
    int32_t res,
    uint64_t* out);

size_t zig_h3_latlng_to_cell_batch_parallel(
    const ZigH3LatLng* points, size_t n,
    int32_t res,
    uint64_t* out,
    size_t threads);

// Inverse batch
size_t zig_h3_cell_to_latlng_batch(
    const uint64_t* cells, size_t n,
    ZigH3LatLng* out);

size_t zig_h3_cell_to_latlng_batch_parallel(
    const uint64_t* cells, size_t n,
    ZigH3LatLng* out,
    size_t threads);

// Grid disk batch
size_t zig_h3_grid_disk_batch(
    const uint64_t* origins, size_t n,
    int32_t k, size_t stride,
    uint64_t* out);

size_t zig_h3_grid_disk_batch_parallel(
    const uint64_t* origins, size_t n,
    int32_t k, size_t stride,
    uint64_t* out,
    size_t threads);

// Helpers
int64_t zig_h3_max_grid_disk_size(int32_t k);  // -1 on bad k
const char* zig_h3_version();                  // null-terminated UTF-8
```

## ABI guarantees

- Every function uses `extern "C"` calling convention.
- The `ZigH3LatLng` struct is bit-identical to libh3's `LatLng`.
- Return values:
  - Batch functions return the count of successful operations.
  - Parallel functions return `SIZE_MAX` (-1 unsigned) on allocator
    failure. Otherwise the success count.
  - `zig_h3_max_grid_disk_size` returns `-1` on invalid k.

## Threading

- Caller's thread invokes `*_parallel` functions, which internally
  spawn `threads` workers via `std.Thread` (POSIX pthread on Linux,
  pthread on macOS, kernel32 on Windows).
- Workers are joined before the function returns. No background
  state escapes.
- Allocator: `std.heap.c_allocator` (so `malloc`/`free` from libc).
  Safe for multi-threaded use.

## Example C client

```c
#include <stdio.h>
#include "zig_h3.h"  // declare the prototypes above

int main(void) {
    ZigH3LatLng points[] = {
        {40.6892 * 0.0174533, -74.0445 * 0.0174533},   // NYC, radians
        {37.7749 * 0.0174533, -122.4194 * 0.0174533},  // SF, radians
    };
    uint64_t cells[2];
    size_t ok = zig_h3_latlng_to_cell_batch_parallel(
        points, 2, 9, cells, 4);
    printf("encoded %zu cells: %llx %llx\n",
           ok, (unsigned long long)cells[0], (unsigned long long)cells[1]);
    return 0;
}
```

Compile with:

```sh
gcc client.c -L/path/to/zig-h3/zig-out/lib -lzig_h3 -o client
LD_LIBRARY_PATH=/path/to/zig-h3/zig-out/lib ./client
```

## Rust binding stub

For a Rust binding, use `libc::` + raw pointers:

```rust
#[link(name = "zig_h3")]
unsafe extern "C" {
    fn zig_h3_latlng_to_cell_batch_parallel(
        points: *const [f64; 2],
        n: usize,
        res: i32,
        out: *mut u64,
        threads: usize,
    ) -> usize;
}
```

Or use `bindgen` against the C header.

## Node N-API stub

A Node binding uses `napi-rs` or `node-addon-api` to wrap the same
six functions. The pattern matches the Python ctypes binding —
NumPy → TypedArray, ctypes pointer → N-API external memory.

Not yet shipped; PRs welcome.
