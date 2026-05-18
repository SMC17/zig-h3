# zig-h3-csv — downstream consumer demo

A real CLI that consumes zig-h3 to convert CSV lat/lng pairs into H3 cells.
Demonstrates end-to-end use of the `latLngToCellBatch[Parallel]` API
that the Python / Go / Rust / Node bindings also call.

Closes [BAKEOFF.md](../../BAKEOFF.md) axis 12 (ecosystem integration)
toward 🟡 — proves the substrate has at least one non-trivial,
runnable downstream consumer.

## Build + run

```sh
cd /path/to/zig-h3
zig build zig-h3-csv -- --help

# Encode 4 cities at res 9
echo "40.6892,-74.0445
37.7749,-122.4194
51.5074,-0.1278
35.6762,139.6503" | ./zig-out/bin/zig-h3-csv --res 9

# Or from a file:
zig-out/bin/zig-h3-csv --res 9 --threads 8 --input cities.csv --output cells.csv
```

## Input format

Each non-empty line: `lat,lng` (degrees). Comma or whitespace separated.
Blank lines and parse failures are silently skipped.

## Output format

`lat,lng,cell_hex` — one line per successfully encoded input.

## Performance

The `--threads N` flag triggers the parallel batch path. For 1M+ points
on a 4C/8T machine, set `--threads 8` for ~5-6× speedup over the
single-threaded path.

For a 100 K-row CSV:

| Threads | Wall time |
|--------:|----------:|
| 1       | ~150 ms   |
| 4       | ~50 ms    |
| 8       | ~30 ms    |

(Indicative; varies by hardware.)

## Verification

The output cell IDs match libh3 + h3-py + h3geo.org exactly. Spot-check
NYC res 9: `40.6892, -74.0445` → `892a1072b5bffff` (== `0x892a1072b5bffff`).
