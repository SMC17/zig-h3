# Rust binding (`zigh3`)

Raw FFI Rust binding around the zig-h3 batch + parallel API via the
`libzig_h3.so` C-ABI shim. Ships at
[`bindings/rust/zigh3/`](../../bindings/rust/zigh3/).

## Build

```sh
cd /path/to/zig-h3
zig build -Doptimize=ReleaseFast

cd bindings/rust/zigh3
RUSTFLAGS="-L $HOME/zig-h3/zig-out/lib" \
LD_LIBRARY_PATH="$HOME/zig-h3/zig-out/lib:$LD_LIBRARY_PATH" \
  cargo test
```

## API

```rust
use zigh3::{LatLng, latlng_to_cell_batch_parallel, max_grid_disk_size, lib_version};

fn main() {
    println!("zig-h3 lib version: {}", lib_version());

    let points = [
        LatLng { lat: 40.6892, lng: -74.0445 },
        LatLng { lat: 37.7749, lng: -122.4194 },
    ];
    let mut cells = vec![0u64; points.len()];
    let ok = latlng_to_cell_batch_parallel(&points, 9, &mut cells, 8);
    println!("encoded {} cells: {:?}", ok, cells);
}
```

## Why this exists

Compared to `h3o` (community Rust port of H3):

| Feature                  | `h3o`       | `zigh3` |
|--------------------------|-------------|---------|
| Pure-Rust                | yes         | no (links libzig_h3.so) |
| Batch + parallel API     | partial     | **yes** |
| Production-stable        | yes         | pre-1.0 |

`zigh3` is the FFI route to the Zig parallel batch path — useful
when you're integrating with a stack that already ships
`libzig_h3.so` (e.g., Python service + Go gateway + Rust analytics
all sharing one .so).

For pure-Rust H3 without an FFI dependency, use `h3o`.

## Tests

7 tests, including a 4096-point parallel-vs-serial cross-check and
a 1000-trial roundtrip property.

## What's NOT exposed

Same as Python/Go bindings: polygon-to-cells, per-cell inspection,
distance/area. These wrap libh3 features that haven't been added
to the C-ABI shim yet.
