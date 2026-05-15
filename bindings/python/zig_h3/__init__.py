"""zig_h3 — Python binding for the SMC17/zig-h3 Zig wrapper of libh3.

NOTE: This is a *thin client*. Production Python use of H3 should still
prefer the official `h3` package on PyPI (h3-py) — that one is the
bottleneck-owner binding maintained by Uber's H3 team. `zig_h3` exists
to make the Zig wrapper reachable from Python for cross-checking +
differential testing.
"""

from __future__ import annotations

import ctypes
import os
from pathlib import Path

__version__ = "0.1.0"


def _lib_path() -> Path:
    override = os.environ.get("ZIG_H3_LIB")
    if override:
        return Path(override)
    # Try the standard zig-out location relative to this binding.
    here = Path(__file__).resolve()
    for parent in here.parents[:5]:
        candidate = parent / "zig-out" / "lib" / "libh3.so"
        if candidate.exists():
            return candidate
        candidate2 = parent / "zig-out" / "lib" / "libh3.a"
        if candidate2.exists():
            return candidate2
    raise FileNotFoundError(
        "libh3 shared library not found. Set $ZIG_H3_LIB or build with "
        "`zig build` from the parent repo."
    )


# Conservative API: just expose the highest-value libh3 calls directly via
# ctypes. For everything else, use h3-py (Uber's official binding).
__all__ = ["__version__"]
