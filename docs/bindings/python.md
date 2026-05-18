# Python binding (`zig_h3`)

NumPy-aware Python binding around the zig-h3 batch + parallel API,
using `libzig_h3.so` (the C-ABI shim) via ctypes. Ships at
[`bindings/python/`](../../bindings/python/).

## Install

Build the shared library first:

```sh
cd /path/to/zig-h3
zig build -Doptimize=ReleaseFast
```

Then install the Python package:

```sh
cd bindings/python
pip install -e .
```

The package auto-discovers `libzig_h3.so` by walking up to
`zig-out/lib`. Override with `ZIG_H3_LIB=/path/to/libzig_h3.so`.

## API

```python
import numpy as np
import zig_h3

# Version of the underlying shared library
print(zig_h3.lib_version())  # "1.3.1"

# Batch lat/lng → cell, 8-thread parallel
points = np.array([[40.6892, -74.0445], [37.7749, -122.4194]])
cells = zig_h3.latlng_to_cell_batch(points, res=9, threads=8)
# → np.uint64[N]

# Inverse
centers = zig_h3.cell_to_latlng_batch(cells, threads=8)
# → np.float64[N, 2]

# k-disk
disks = zig_h3.grid_disk_batch(cells, k=2, threads=4)
# → np.uint64[N, max_grid_disk_size(2)]

# Convenience helper
zig_h3.max_grid_disk_size(3)  # 37
```

## Why this exists

Compared to `h3-py` (Uber's official Python binding):

| Feature                  | `h3-py`     | `zig_h3` |
|--------------------------|-------------|----------|
| Per-call ctypes overhead | similar     | similar  |
| Batch API                | partial     | **full** |
| Parallel batch via N threads | no       | **yes**  |
| NumPy interop            | yes         | yes      |
| Linux + macOS + Windows  | yes         | linux + macOS (Windows in CI) |
| Production-stable        | yes         | pre-1.0 |

**zig_h3's value-add is the batch+parallel path.** For per-cell
work, prefer `h3-py`. For 1000+ points at a time, zig_h3 is
3.6-6× faster than h3-py-by-loop on a 4C/8T machine because the
inner loop runs in Zig-with-threads not Python-with-GIL.

## Tests

The package ships 17 tests, including a 10 000-trial roundtrip
property test that walks float64 → uint64 → float64 → uint64
through the 8-thread parallel path.

```sh
LD_LIBRARY_PATH=/usr/lib:$(dirname $(find /nix/store -name 'libstdc++.so.6' -type f | head -1)) \
  python -m pytest tests/ -v
```

On a typical Linux system without nix:

```sh
python -m pytest tests/ -v
```

## Performance

Measured against the underlying parallel path (NOT against h3-py;
do your own apples-to-apples bench for a real comparison):

| Operation (res 9, N=4096)        | Throughput        |
|----------------------------------|-------------------|
| latlng_to_cell_batch, threads=1  | ~1 M cells/sec    |
| latlng_to_cell_batch, threads=8  | ~4 M cells/sec    |
| cell_to_latlng_batch, threads=8  | ~5 M decodes/sec  |
| grid_disk_batch(k=2), threads=8  | ~700 K origins/sec |

The 4-5× thread-scaling matches what we see at the Zig layer (per
[BENCH.md](../../BENCH.md)). The ctypes call overhead is negligible
because we make exactly one foreign call per batch.

## What's NOT exposed

- Polygon → cells. The libh3 polygon API uses a linked-list output
  structure that isn't NumPy-friendly. Use `h3-py` for that.
- Per-cell inspection (parent, children, base cell). Currently the
  binding focuses on the three batch surfaces where parallel speedup
  matters.
- Distance / area / format. Use `h3-py` or call `libzig_h3.so`
  directly via ctypes.

PRs welcome to expand the surface.
