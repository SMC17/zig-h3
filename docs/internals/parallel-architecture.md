# Parallel architecture

How `*BatchParallel` works under the hood. Useful if you're
debugging perf, modifying the threading model, or porting to a new
target.

## The data model

Each parallel function takes:
- An input slice (`points`, `cells`, or `origins`)
- An output slice (pre-allocated)
- A `thread_count`
- (For `gridDiskBatchParallel`) a `stride` parameter

The function:

1. **Validates** input/output sizes.
2. **Fast-paths** to serial when input is too small to amortize
   thread spawn (1024 points / 64 origins / always for thread_count<=1).
3. **Allocates work descriptors** — one `BatchWork` struct per thread,
   describing each thread's input slice + output slice + result counter.
4. **Spawns threads** via `std.Thread.spawn`, each running a worker
   that calls the *serial* batch function on its slice.
5. **Joins all threads**, sums the per-thread success counts.
6. **Returns** the total.

## Why split at the batch boundary instead of finer-grain?

Three reasons:

### (a) No per-iteration sync

If we paralleled at the per-element level (e.g., a thread pool with
work-stealing), every element would pay for cache-line ping-pong on
the work-stealing queue. At the batch boundary, each thread owns a
contiguous chunk of memory and never coordinates with peers during
the hot loop.

### (b) Allocator pressure is minimal

The pure-Zig conversion functions (`latLngToCell` etc.) don't
allocate. `gridDisk` does allocate a small `distances` buffer in
the fallback safe path; the allocator is per-thread (passed from
the caller). No allocator contention.

### (c) Branch prediction loves contiguous work

Each thread's slice is one contiguous range. The branch predictor
sees the same shape repeatedly and pipelines instructions tightly.
A fine-grain scheduler would interleave threads at arbitrary points
and break the pattern.

## The split

For N points and T threads:

```
chunk = ceil(N / T)
thread 0: points[0..chunk]
thread 1: points[chunk..2*chunk]
...
thread T-1: points[(T-1)*chunk..N]
```

If `N % T != 0`, the last thread gets a smaller chunk. We don't try
to balance further because the per-element cost is uniform.

## Why no std.Thread.Pool?

Zig 0.16 has `std.Thread.Pool` but for this workload it's overkill.
Pool overhead matters when you have many small tasks; we have a few
large tasks. Direct `std.Thread.spawn` + `join` is simpler and the
allocator-of-record stays the caller's allocator (not pool-internal).

If a future workload needed many small batches per second, a
pool-based variant could be added without breaking the API.

## The work struct

```zig
const BatchWork = struct {
    points: []const LatLng,
    res: i32,
    out: []H3Index,
    ok_count: usize = 0,
};
```

Each thread's worker writes to `ok_count` in its own slot of the
`works[]` array. No cross-thread writes. Joining the thread happens
*before* we read its `ok_count` — that establishes the happens-before
relationship for the read.

## Why `*w` in the join loop?

```zig
for (threads, works) |*t, *w| {
    if (w.points.len == 0) continue;
    t.join();
    total += w.ok_count;
}
```

Originally I wrote `|*t, w|` (value capture). That copied `w`
*before* the worker ran, so `total += w.ok_count` always read 0.
The fix is `|*t, *w|` — pointer-into-the-array, so we read the
post-join value. This was a real bug caught by the
`latLngToCellBatchParallel matches scalar path on a 4096-point
random sweep` test which expected 4096 successes but found 2048.

## Threading guarantees

- No background threads outlive the function call.
- Caller's thread blocks on `join` until all workers complete.
- Workers never access caller-owned mutable state after entry
  (their slices are read-only views).
- The `out` slices given to each worker are disjoint, so writes
  don't race.

## Performance ceiling

Single-threaded pure-Zig is already 1.4-2× faster than libh3 scalar.
Adding N threads on a 4C/8T machine gives:

- 4 threads: ~3× scalar Zig (limited by cache, branch predictor)
- 8 threads: ~5× scalar Zig (SMT contention; the second hardware
  thread per core is partial)

Combined with the scalar-Zig speedup, 8-thread parallel hits
5-12× pure-Zig and **3.6-6× libh3 scalar**.

The route to 10× libh3:
- `@Vector(4, f64)` AVX2 inner math: ~+2-4×
- AVX-512 on supporting hardware: ~+4-8×
- PGO build: ~+5-10%

Filed as v2 next-frontier in BENCH.md.
