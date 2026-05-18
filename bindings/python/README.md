# zig_h3 — Python binding for SMC17/zig-h3

NumPy-aware Python wrapper around the zig-h3 batch + parallel API,
using `libzig_h3.so` (the C-ABI shim) via ctypes.

## Install

Build the shared library first:

```sh
cd /path/to/zig-h3
zig build -Doptimize=ReleaseFast
```

Then install the binding:

```sh
cd bindings/python
pip install -e .
```

The package auto-discovers `libzig_h3.so` by walking up to
`zig-out/lib`. Override with `ZIG_H3_LIB=/path/to/libzig_h3.so`.

## Usage

```python
import numpy as np
import zig_h3

# Batch lat/lng → cell
points = np.array([[40.6892, -74.0445], [37.7749, -122.4194]])
cells = zig_h3.latlng_to_cell_batch(points, res=9)
# → uint64 array

# Parallel (uses N threads via std.Thread in Zig)
cells = zig_h3.latlng_to_cell_batch(points, res=9, threads=8)

# Inverse
centers = zig_h3.cell_to_latlng_batch(cells)
# → float64 array of shape (N, 2)

# Grid disk
disks = zig_h3.grid_disk_batch(cells, k=2, threads=4)
# → uint64 array of shape (N, max_grid_disk_size(k))
```

## Why this exists

The Zig batch API can be **3.6-6× faster than libh3 scalar** on
multi-core systems through `std.Thread.Pool` parallelism (see
`zig-h3/BENCH.md`). This binding exposes that win to Python without
the per-call ctypes overhead — call it once with a NumPy array of
N points, get N cells back.

Production Python users with single-cell needs should still prefer
`h3-py` (Uber's official binding). This binding's value is the
batch+parallel API where ctypes-call overhead would dominate
per-cell work.

## Tests

```sh
LD_LIBRARY_PATH=/usr/lib:$(dirname $(find /nix/store -name 'libstdc++.so.6' -type f | head -1)) \
  python -m pytest tests/ -v
```

17 tests, including a 10 000-trial roundtrip property test that
walks float64 → uint64 → float64 → uint64 through the parallel path.
