"""zig_h3 — Python binding for SMC17/zig-h3.

Calls the Zig batch + parallel API through a C-ABI shared library
(`libzig_h3.so`). Designed for NumPy interop: pass float64 arrays in,
get uint64 arrays out, with the heavy lifting in Zig (thread-parallel
on multi-core systems).

Example:
    import numpy as np
    import zig_h3

    points = np.array([[40.6892, -74.0445], [37.7749, -122.4194]])
    cells = zig_h3.latlng_to_cell_batch(points, res=9)
    # cells is uint64[2]
"""

from __future__ import annotations

import ctypes
import os
from pathlib import Path
from typing import Optional

__version__ = "0.2.0"
__all__ = [
    "latlng_to_cell_batch",
    "cell_to_latlng_batch",
    "grid_disk_batch",
    "max_grid_disk_size",
    "lib_version",
]


class LatLng(ctypes.Structure):
    _fields_ = [("lat", ctypes.c_double), ("lng", ctypes.c_double)]


def _resolve_lib_path() -> Path:
    """Find libzig_h3.so via env override or zig-out/lib walk."""
    override = os.environ.get("ZIG_H3_LIB")
    if override:
        return Path(override)
    here = Path(__file__).resolve()
    for parent in here.parents[:6]:
        for suffix in ("so", "dylib", "dll"):
            candidate = parent / "zig-out" / "lib" / f"libzig_h3.{suffix}"
            if candidate.exists():
                return candidate
    raise FileNotFoundError(
        "libzig_h3 not found. Build with `zig build -Doptimize=ReleaseFast` "
        "from the parent repo, or set $ZIG_H3_LIB."
    )


_lib = ctypes.CDLL(str(_resolve_lib_path()))

# zig_h3_latlng_to_cell_batch(points*, n, res, out*) -> usize
_lib.zig_h3_latlng_to_cell_batch.argtypes = [
    ctypes.POINTER(LatLng),
    ctypes.c_size_t,
    ctypes.c_int32,
    ctypes.POINTER(ctypes.c_uint64),
]
_lib.zig_h3_latlng_to_cell_batch.restype = ctypes.c_size_t

# zig_h3_latlng_to_cell_batch_parallel(points*, n, res, out*, threads) -> usize
_lib.zig_h3_latlng_to_cell_batch_parallel.argtypes = [
    ctypes.POINTER(LatLng),
    ctypes.c_size_t,
    ctypes.c_int32,
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.c_size_t,
]
_lib.zig_h3_latlng_to_cell_batch_parallel.restype = ctypes.c_size_t

# zig_h3_cell_to_latlng_batch(cells*, n, out*) -> usize
_lib.zig_h3_cell_to_latlng_batch.argtypes = [
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.c_size_t,
    ctypes.POINTER(LatLng),
]
_lib.zig_h3_cell_to_latlng_batch.restype = ctypes.c_size_t

_lib.zig_h3_cell_to_latlng_batch_parallel.argtypes = [
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.c_size_t,
    ctypes.POINTER(LatLng),
    ctypes.c_size_t,
]
_lib.zig_h3_cell_to_latlng_batch_parallel.restype = ctypes.c_size_t

_lib.zig_h3_grid_disk_batch.argtypes = [
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.c_size_t,
    ctypes.c_int32,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_uint64),
]
_lib.zig_h3_grid_disk_batch.restype = ctypes.c_size_t

_lib.zig_h3_grid_disk_batch_parallel.argtypes = [
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.c_size_t,
    ctypes.c_int32,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_uint64),
    ctypes.c_size_t,
]
_lib.zig_h3_grid_disk_batch_parallel.restype = ctypes.c_size_t

_lib.zig_h3_max_grid_disk_size.argtypes = [ctypes.c_int32]
_lib.zig_h3_max_grid_disk_size.restype = ctypes.c_int64

_lib.zig_h3_version.argtypes = []
_lib.zig_h3_version.restype = ctypes.c_char_p


def lib_version() -> str:
    """Underlying libzig_h3 version string."""
    return _lib.zig_h3_version().decode("utf-8")


def max_grid_disk_size(k: int) -> int:
    """Maximum cells in a grid disk of distance k."""
    result = _lib.zig_h3_max_grid_disk_size(k)
    if result < 0:
        raise ValueError(f"invalid k={k}")
    return result


def latlng_to_cell_batch(points, res: int, threads: int = 1):
    """Batch lat/lng → H3 cell.

    `points` is either:
      - a NumPy float64 array of shape (N, 2), columns [lat, lng]
      - a sequence of (lat, lng) tuples (will be converted)

    Returns NumPy uint64 array of length N. Failed conversions are 0.

    `threads > 1` invokes the parallel path (each worker processes a
    slice). Below 1024 points the serial path is used regardless.
    """
    try:
        import numpy as np
    except ImportError as e:
        raise ImportError("numpy required for batch operations") from e

    arr = np.ascontiguousarray(points, dtype=np.float64)
    if arr.ndim != 2 or arr.shape[1] != 2:
        raise ValueError(f"points must be (N, 2); got {arr.shape}")
    n = arr.shape[0]
    if n == 0:
        return np.empty(0, dtype=np.uint64)

    # Interpret as LatLng[] via ctypes — the memory layout is two f64s,
    # matching our extern struct.
    points_ptr = arr.ctypes.data_as(ctypes.POINTER(LatLng))
    out = np.empty(n, dtype=np.uint64)
    out_ptr = out.ctypes.data_as(ctypes.POINTER(ctypes.c_uint64))

    if threads > 1:
        _lib.zig_h3_latlng_to_cell_batch_parallel(points_ptr, n, res, out_ptr, threads)
    else:
        _lib.zig_h3_latlng_to_cell_batch(points_ptr, n, res, out_ptr)
    return out


def cell_to_latlng_batch(cells, threads: int = 1):
    """Batch H3 cell → lat/lng centroids.

    `cells` is a NumPy uint64 array (or convertible sequence).
    Returns NumPy float64 array of shape (N, 2). Failed decodes are NaN.

    `threads > 1` uses the parallel path.
    """
    try:
        import numpy as np
    except ImportError as e:
        raise ImportError("numpy required for batch operations") from e

    cell_arr = np.ascontiguousarray(cells, dtype=np.uint64)
    n = cell_arr.shape[0]
    if n == 0:
        return np.empty((0, 2), dtype=np.float64)

    cells_ptr = cell_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint64))
    out = np.empty((n, 2), dtype=np.float64)
    out_ptr = out.ctypes.data_as(ctypes.POINTER(LatLng))

    if threads > 1:
        _lib.zig_h3_cell_to_latlng_batch_parallel(cells_ptr, n, out_ptr, threads)
    else:
        _lib.zig_h3_cell_to_latlng_batch(cells_ptr, n, out_ptr)
    return out


def grid_disk_batch(origins, k: int, threads: int = 1):
    """Batch gridDisk — for each origin, compute the disk of distance k.

    Returns NumPy uint64 array of shape (N, stride) where
    stride = max_grid_disk_size(k). Cells past the actual disk size for
    a particular origin (e.g., pentagon-adjacent) are 0.

    `threads > 1` uses the parallel path.
    """
    try:
        import numpy as np
    except ImportError as e:
        raise ImportError("numpy required for batch operations") from e

    origin_arr = np.ascontiguousarray(origins, dtype=np.uint64)
    n = origin_arr.shape[0]
    stride = max_grid_disk_size(k)
    if n == 0:
        return np.empty((0, stride), dtype=np.uint64)

    origins_ptr = origin_arr.ctypes.data_as(ctypes.POINTER(ctypes.c_uint64))
    out = np.zeros((n, stride), dtype=np.uint64)
    out_ptr = out.ctypes.data_as(ctypes.POINTER(ctypes.c_uint64))

    if threads > 1:
        _lib.zig_h3_grid_disk_batch_parallel(origins_ptr, n, k, stride, out_ptr, threads)
    else:
        _lib.zig_h3_grid_disk_batch(origins_ptr, n, k, stride, out_ptr)
    return out
