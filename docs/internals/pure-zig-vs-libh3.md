# Pure-Zig vs libh3 — design notes

zig-h3 ships **two parallel implementations** of every load-bearing
H3 function. This document explains why, how the cross-validation
works, and why the pure-Zig path is faster than libh3 on the same
hardware.

## The two implementations

| Path                 | Files                                | Calls into |
|----------------------|--------------------------------------|------------|
| Wrapper layer        | `src/root.zig`                       | libh3 (via cImport) |
| Pure-Zig             | `src/pure_h3index.zig`, `pure_h3decode.zig`, `pure_grid.zig`, `pure_hierarchy.zig`, etc. | nothing (no C deps) |

Both produce **bit-identical outputs** on every tested input. Every
test in the `pure_*.zig` files compares its result against the
corresponding `root.*` call and asserts H3Index equality.

## Why two?

1. **Differential testing** — if pure-Zig agrees with libh3 on 27 000+
   inputs, both are probably correct. If they diverge, one of them
   has a bug, and we have a regression-finding signal.
2. **Compilation-target reach** — the pure path doesn't link libh3,
   so it can target environments where the C library is unavailable
   (e.g., a hypothetical no-libc embedded target).
3. **Performance** — see below; the pure-Zig path is faster.
4. **Spec audit** — by reimplementing the math from the H3 paper +
   the libh3 source, we discover any place where the C code's
   structure obscures intent.

## Why is pure-Zig faster?

This is not a property of "Zig vs C" in general. It's specific port
choices that happen to produce better codegen:

### Inline-by-default

Small helpers in the geo-conversion path (face-IJK math, base-cell
rotations) are `inline` in the Zig port but `static` (a hint, not a
requirement) in libh3. The compiler makes different decisions, and
on the hot path inlining wins because:
- No call frame setup/teardown.
- Constant propagation across the inlined boundary.
- Better instruction scheduling.

### Tighter struct layout

Zig's `extern struct` lets us match libh3's ABI exactly where we
need to, and pack more aggressively where we don't. The H3-index
integer manipulations don't allocate, and the FaceIJK / CoordIJK
intermediates stay in registers across most of the conversion chain.

### No C ABI noise

libh3's public functions use C int widths (`int`, `bool`-as-int)
that the Zig compiler can't see across. Our pure-Zig path uses
`i32` / `u64` / `f64` directly, and the compiler inlines through
the whole call chain in a single visibility scope.

### Single-binary visibility

libh3 compiles each `.c` file independently and exposes every
public function across a C-ABI boundary. The pure-Zig path compiles
in one module-level visibility scope; LLVM sees the entire call
graph and optimizes accordingly. This is the load-bearing reason
— the others are consequences of this.

## The measured win

From [`../../BENCH.md`](../../BENCH.md), Intel i7-1065G7,
ReleaseFast, MONOTONIC ns:

| Operation                | libh3 ns/op | pure-Zig ns/op | Ratio  |
|--------------------------|------------:|---------------:|-------:|
| latLngToCell (res 7)     | 1068        | 761            | 0.71×  |
| latLngToCell (res 11)    | 1314        | 959            | 0.73×  |
| cellToLatLng (res 9)     | 526         | 435            | 0.83×  |
| gridDisk (k=3, res 9)    | 1026        | 902            | 0.88×  |

12-29% faster across the board. Adding 8-thread parallelism on top
gives 3.6-6× over libh3 scalar.

## What this is NOT a claim of

- **Zig is faster than C in general.** It is not. This is one
  specific port with one specific set of compiler decisions.
- **The pure-Zig path is more correct than libh3.** They are
  *bit-identical* on 27 000+ tested cases. Either could have a bug
  on an untested case.
- **Future libh3 won't get faster.** The C library can adopt the
  same inlining strategy any time. This is a snapshot.

## The cross-validation infrastructure

Every test in `pure_*.zig` compares against `root.*`:

```zig
test "pure latLngToCell matches libh3 on hand-picked landmark points" {
    for (landmarks) |point| {
        var res: i32 = 0;
        while (res <= MAX_RES) : (res += 1) {
            const theirs = try root.latLngToCell(point, res);  // libh3
            const ours = try latLngToCell(point, res);         // pure-Zig
            try testing.expectEqual(theirs, ours);
        }
    }
}
```

Eight named exhaustive corpora (see `pure_h3index.zig` +
`pure_h3decode.zig`) run 27 000+ cases per `zig build test`. Any
divergence between the two paths fails the test loudly with the
expected vs actual cell IDs.

This is the closest thing zig-h3 has to a property-based correctness
proof. We *can't* prove the algorithm is right; we *can* prove that
two independent implementations agree on a very large input set.

## When the pure-Zig path falls behind

The pure-Zig coverage isn't 100% of libh3. Specifically:
- `LinkedMultiPolygon` (output of `cellsToMultiPolygon`) is wrapper-only.
- Cell area in km² / m² is wrapper-only.
- Edge length in km / m is wrapper-only.

For these, the C path is the only path. If you need differential
coverage on them, contribute a pure-Zig port — the cross-validation
infrastructure is ready to assert correctness on any new pure-Zig
function you add.

## When to call which path

| You want...                              | Use         |
|------------------------------------------|-------------|
| Maximum compatibility / spec adherence   | `h3.*` (wrapper layer) |
| Maximum throughput on batch workloads    | `h3.latLngToCellBatchParallel` etc. (uses pure-Zig) |
| Direct access to pure-Zig path           | `h3.h3index.*`, `h3.h3decode.*`, `h3.grid.*` |
| Differential test against libh3          | Call both and `expectEqual` |
| `LinkedMultiPolygon` or km² / m² outputs | `h3.*` (only path) |
