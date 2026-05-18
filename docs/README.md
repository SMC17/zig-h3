# zig-h3 documentation

The full documentation set for `zig-h3`, the idiomatic Zig wrapper +
pure-Zig reimplementation of [Uber's H3 v4][h3] hexagonal hierarchical
spatial index.

[h3]: https://h3geo.org/

## Audience

1. **Application developers** using zig-h3 in a Zig project. Start
   with [tutorials/01-zig-quickstart.md](tutorials/01-zig-quickstart.md).
2. **Python developers** needing the batch + parallel API. Start
   with [bindings/python.md](bindings/python.md).
3. **Go developers** using the cgo binding. Start with
   [bindings/go.md](bindings/go.md).
4. **Performance engineers** evaluating zig-h3 vs libh3. Read
   [`../BENCH.md`](../BENCH.md) for measured numbers and
   [internals/parallel-architecture.md](internals/parallel-architecture.md)
   for the design.

## Map

### Tutorials (start here)

- [01 — Zig quickstart](tutorials/01-zig-quickstart.md): install,
  compute a cell, walk a k-ring.
- [02 — Batch + parallel API](tutorials/02-batch-and-parallel.md):
  process millions of points with `latLngToCellBatch`.
- [03 — Cross-validation against libh3](tutorials/03-cross-validation.md):
  use the pure-Zig path to differential-test geo logic.

### Reference

- [Function reference](reference/functions.md): all 70 public H3 v4
  functions, with signatures + invariants.
- [Batch API reference](reference/batch-api.md): the 6 batch + parallel
  functions added in v1.4.0.
- [Error set](reference/errors.md): every variant of `h3.Error`.
- [LatLng / H3Index / CellBoundary structs](reference/types.md):
  field-level documentation of the ABI-stable extern structs.

### Bindings

- [Python](bindings/python.md): NumPy-aware, ctypes-based.
- [Go](bindings/go.md): cgo wrapping the C-ABI shim.
- [C-ABI](bindings/c-abi.md): the underlying `libzig_h3.so` surface
  that other languages can link to.

### Internals (for contributors)

- [Parallel architecture](internals/parallel-architecture.md): how
  the batch+parallel API works under the hood.
- [Pure-Zig vs libh3](internals/pure-zig-vs-libh3.md): why our pure
  port beats the C reference.
- [Cross-platform support matrix](internals/cross-platform.md):
  which targets we CI on and which we cross-compile-only.

## Other documents

- [`../README.md`](../README.md) — top-level project overview.
- [`../BENCH.md`](../BENCH.md) — measured perf numbers.
- [`../BAKEOFF.md`](../BAKEOFF.md) — honest comparison to uber/h3.
- [`../API_STABILITY.md`](../API_STABILITY.md) — semver commitment.
- [`../CHANGELOG.md`](../CHANGELOG.md) — version-by-version history.
