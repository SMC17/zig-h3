# Go binding (`zigh3`)

cgo-based Go binding around the zig-h3 batch + parallel API via the
`libzig_h3.so` C-ABI shim. Ships at
[`bindings/go/zigh3/`](../../bindings/go/zigh3/).

## Build

```sh
cd /path/to/zig-h3
zig build -Doptimize=ReleaseFast

export CGO_LDFLAGS="-L$PWD/zig-out/lib"
export LD_LIBRARY_PATH="$PWD/zig-out/lib:$LD_LIBRARY_PATH"

cd bindings/go/zigh3
go test -v ./...
```

## API

```go
package main

import (
    "fmt"
    "zigh3"
)

func main() {
    // 8-thread parallel batch lat/lng → cell
    points := []zigh3.LatLng{
        {Lat: 40.6892, Lng: -74.0445},
        {Lat: 37.7749, Lng: -122.4194},
    }
    cells, ok := zigh3.LatLngToCellBatchParallel(points, 9, 8)
    fmt.Printf("encoded %d of %d points: %v\n", ok, len(points), cells)

    // Inverse
    centers, _ := zigh3.CellToLatLngBatchParallel(cells, 8)
    fmt.Printf("centers: %v\n", centers)

    // k-disk
    disks, stride, _ := zigh3.GridDiskBatchParallel(cells, 2, 8)
    fmt.Printf("disks (stride=%d): %v\n", stride, disks)
}
```

## Why this exists

Compared to `h3-go` (Uber's official binding):

| Feature                  | `h3-go`     | `zigh3` |
|--------------------------|-------------|---------|
| Per-call cgo overhead    | similar     | similar |
| Batch API                | no          | **yes** |
| Parallel batch via N threads | no       | **yes** |
| Production-stable        | yes         | pre-1.0 |

The batch+parallel win matches the Python binding: 3.6-6× faster
than calling libh3 in a Go loop on a 4C/8T system. The Go scheduler
doesn't compete with the Zig std.Thread workers — they're real OS
threads.

## Tests

Eight unit tests + a 10 000-trial roundtrip property corpus.
Matches the Python binding's coverage shape so you can cross-check.

## What's NOT exposed

Same as Python: polygon-to-cells, per-cell inspection, distance/area.
For full coverage use `h3-go`.

## Production caveat

This binding requires `libzig_h3.so` at runtime. Embed it in your
Docker image alongside the Go binary, or static-link via
`libzig_h3_static.a` (the build also installs that target).
