// Node binding for SMC17/zig-h3 batch+parallel API via koffi FFI.
//
// Wraps libzig_h3.so (the C-ABI shim). The same .so that Python ctypes
// + Go cgo + Rust libc bindings link against.
//
// Usage:
//   npm install
//   ZIG_H3_LIB=/path/to/libzig_h3.so node test.js

const koffi = require('koffi');
const path = require('path');
const fs = require('fs');

function resolveLibPath() {
    if (process.env.ZIG_H3_LIB) return process.env.ZIG_H3_LIB;
    let here = __dirname;
    for (let i = 0; i < 6; i++) {
        const candidate = path.join(here, 'zig-out', 'lib', 'libzig_h3.so');
        if (fs.existsSync(candidate)) return candidate;
        here = path.dirname(here);
    }
    throw new Error('libzig_h3.so not found; set $ZIG_H3_LIB');
}

const lib = koffi.load(resolveLibPath());

// struct LatLng { double lat; double lng; }
const LatLng = koffi.struct('LatLng', {
    lat: 'double',
    lng: 'double',
});

const fns = {
    zig_h3_latlng_to_cell_batch: lib.func(
        'size_t zig_h3_latlng_to_cell_batch(LatLng *points, size_t n, int32_t res, _Out_ uint64_t *out)'
    ),
    zig_h3_latlng_to_cell_batch_parallel: lib.func(
        'size_t zig_h3_latlng_to_cell_batch_parallel(LatLng *points, size_t n, int32_t res, _Out_ uint64_t *out, size_t threads)'
    ),
    zig_h3_cell_to_latlng_batch: lib.func(
        'size_t zig_h3_cell_to_latlng_batch(uint64_t *cells, size_t n, _Out_ LatLng *out)'
    ),
    zig_h3_cell_to_latlng_batch_parallel: lib.func(
        'size_t zig_h3_cell_to_latlng_batch_parallel(uint64_t *cells, size_t n, _Out_ LatLng *out, size_t threads)'
    ),
    zig_h3_grid_disk_batch: lib.func(
        'size_t zig_h3_grid_disk_batch(uint64_t *origins, size_t n, int32_t k, size_t stride, _Out_ uint64_t *out)'
    ),
    zig_h3_grid_disk_batch_parallel: lib.func(
        'size_t zig_h3_grid_disk_batch_parallel(uint64_t *origins, size_t n, int32_t k, size_t stride, _Out_ uint64_t *out, size_t threads)'
    ),
    zig_h3_max_grid_disk_size: lib.func('int64_t zig_h3_max_grid_disk_size(int32_t k)'),
    zig_h3_version: lib.func('const char *zig_h3_version()'),
};

function libVersion() {
    return fns.zig_h3_version();
}

function maxGridDiskSize(k) {
    const r = fns.zig_h3_max_grid_disk_size(k);
    if (r < 0) throw new RangeError(`invalid k=${k}`);
    return Number(r);
}

const DEG_TO_RAD = Math.PI / 180;
const RAD_TO_DEG = 180 / Math.PI;

function latlngToCellBatch(points, res, { threads = 1, units = 'degrees' } = {}) {
    const n = points.length;
    if (n === 0) return new BigUint64Array(0);
    // Convert to radians (libh3 internal) before the FFI call.
    let working = points;
    if (units === 'degrees') {
        working = points.map(p => ({ lat: p.lat * DEG_TO_RAD, lng: p.lng * DEG_TO_RAD }));
    } else if (units !== 'radians') {
        throw new TypeError(`units must be 'degrees' or 'radians'; got ${units}`);
    }
    const out = new BigUint64Array(n);
    if (threads > 1) {
        fns.zig_h3_latlng_to_cell_batch_parallel(working, n, res, out, threads);
    } else {
        fns.zig_h3_latlng_to_cell_batch(working, n, res, out);
    }
    return out;
}

function cellToLatlngBatch(cells, { threads = 1, units = 'degrees' } = {}) {
    const n = cells.length;
    if (n === 0) return [];
    const out = new Array(n).fill({ lat: 0, lng: 0 });
    if (threads > 1) {
        fns.zig_h3_cell_to_latlng_batch_parallel(cells, n, out, threads);
    } else {
        fns.zig_h3_cell_to_latlng_batch(cells, n, out);
    }
    if (units === 'degrees') {
        return out.map(p => ({ lat: p.lat * RAD_TO_DEG, lng: p.lng * RAD_TO_DEG }));
    } else if (units !== 'radians') {
        throw new TypeError(`units must be 'degrees' or 'radians'; got ${units}`);
    }
    return out;
}

function gridDiskBatch(origins, k, { threads = 1 } = {}) {
    const n = origins.length;
    const stride = maxGridDiskSize(k);
    if (n === 0) return new BigUint64Array(0);
    const out = new BigUint64Array(n * stride);
    if (threads > 1) {
        fns.zig_h3_grid_disk_batch_parallel(origins, n, k, stride, out, threads);
    } else {
        fns.zig_h3_grid_disk_batch(origins, n, k, stride, out);
    }
    return out;
}

module.exports = {
    libVersion,
    maxGridDiskSize,
    latlngToCellBatch,
    cellToLatlngBatch,
    gridDiskBatch,
};
