# Node binding (`zigh3`)

Node binding around the zig-h3 batch + parallel API via the
`libzig_h3.so` C-ABI shim. Uses `koffi` (modern FFI). Ships at
[`bindings/node/zigh3/`](../../bindings/node/zigh3/).

## Build + test

```sh
cd /path/to/zig-h3
zig build -Doptimize=ReleaseFast

cd bindings/node/zigh3
npm install
ZIG_H3_LIB="$HOME/zig-h3/zig-out/lib/libzig_h3.so" node --test test.js
```

## API

```js
const zigh3 = require('zigh3');

console.log('lib version:', zigh3.libVersion());

const points = [
    { lat: 40.6892, lng: -74.0445 },
    { lat: 37.7749, lng: -122.4194 },
];

// Serial batch
const cells = zigh3.latlngToCellBatch(points, 9);
console.log('cells:', cells);  // BigUint64Array

// Parallel batch
const cellsPar = zigh3.latlngToCellBatch(points, 9, { threads: 8 });

// k-disk
const disks = zigh3.gridDiskBatch(cells, 1);
```

## Why this exists

Compared to `h3-js` (Uber's official Node binding):

| Feature                  | `h3-js`     | `zigh3` |
|--------------------------|-------------|---------|
| Per-call FFI overhead    | none (WASM) | koffi FFI (~µs) |
| Batch + parallel API     | partial     | **yes** |
| Native code (vs WASM)    | WASM        | native via .so |
| Production-stable        | yes         | pre-1.0 |

The batch+parallel API gives zigh3 a win on bulk workloads
(`latlngToCellBatch` on 4096 points + 8 threads vs calling
h3-js's `latLngToCell` in a JS loop), at the cost of needing a
native `.so` alongside the Node binary (h3-js ships WASM, so it's
self-contained).

## Tests

6 tests, including a 2048-point parallel-vs-serial cross-check.

## What's NOT exposed

Same as the other bindings: polygon-to-cells, per-cell inspection,
distance/area.
