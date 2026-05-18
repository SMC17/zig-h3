// zigh3.mjs — WebAssembly binding for SMC17/zig-h3.
//
// Loads zig_h3.wasm (built via `zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseFast`)
// and exposes a JS-friendly surface. Works in:
//   - Browser (via fetch + WebAssembly.instantiateStreaming)
//   - Bun (via import)
//   - Node (via fs + WebAssembly.instantiate)
// because we use the standard WebAssembly host interface — no koffi
// or N-API dependency. The same .wasm runs everywhere.
//
// Closes BAKEOFF axis 3 (cross-platform reach — WASM verified) and adds
// a 5th binding language target.

const DEG_TO_RAD = Math.PI / 180;
const RAD_TO_DEG = 180 / Math.PI;

let wasmModule = null;
let wasmMemory = null;
let wasmExports = null;

/**
 * Initialize the binding with a path to zig_h3.wasm.
 *
 * In Node / Bun:
 *   await zigh3.init('/path/to/zig_h3.wasm');
 *
 * In browser:
 *   await zigh3.init(fetch('/static/zig_h3.wasm'));
 */
export async function init(sourceOrPath) {
    let bytes;
    if (typeof sourceOrPath === 'string') {
        // Node / Bun path
        const fs = await import('fs/promises');
        bytes = await fs.readFile(sourceOrPath);
    } else if (sourceOrPath instanceof Promise) {
        // fetch() Response
        const resp = await sourceOrPath;
        bytes = await resp.arrayBuffer();
    } else if (sourceOrPath instanceof Response) {
        bytes = await sourceOrPath.arrayBuffer();
    } else if (sourceOrPath instanceof Uint8Array || sourceOrPath instanceof ArrayBuffer) {
        bytes = sourceOrPath;
    } else {
        throw new TypeError('init() expects a path string, Promise<Response>, Response, or bytes');
    }

    // The zig-h3 wasm (built for wasm32-wasi as a shared library) is
    // relocatable and imports its own memory + stack pointer from `env`.
    // We provide those alongside a minimal WASI shim.
    const memory = new WebAssembly.Memory({ initial: 256, maximum: 1024 });
    const table = new WebAssembly.Table({ initial: 16, element: 'anyfunc' });
    wasmMemory = memory;

    const imports = {
        env: {
            memory,
            __indirect_function_table: table,
            __stack_pointer: new WebAssembly.Global({ value: 'i32', mutable: true }, 65536 * 256 - 16),
            __memory_base: new WebAssembly.Global({ value: 'i32', mutable: false }, 0),
            __table_base: new WebAssembly.Global({ value: 'i32', mutable: false }, 0),
            // wasi-libc's startup expects this; we never call it because
            // the binding only invokes the exported zig_h3_* functions.
            __main_argc_argv: () => 0,
        },
        wasi_snapshot_preview1: {
            proc_exit: (code) => { throw new Error(`proc_exit(${code})`); },
            fd_write: () => 0,
            fd_close: () => 0,
            fd_seek: () => 0,
            fd_read: () => 0,
            fd_fdstat_get: () => 0,
            environ_sizes_get: () => 0,
            environ_get: () => 0,
            args_sizes_get: () => 0,
            args_get: () => 0,
            random_get: (ptr, len) => {
                const view = new Uint8Array(memory.buffer, ptr, len);
                crypto.getRandomValues(view);
                return 0;
            },
            clock_time_get: () => 0,
        },
    };

    const result = await WebAssembly.instantiate(bytes, imports);
    wasmModule = result.module;
    wasmExports = result.instance.exports;
    return zigh3;
}

function ensureInit() {
    if (!wasmExports) throw new Error('zigh3 not initialized — call init() first');
}

/** Library version string. */
export function libVersion() {
    ensureInit();
    const ptr = wasmExports.zig_h3_version();
    const view = new Uint8Array(wasmMemory.buffer);
    let end = ptr;
    while (view[end] !== 0) end++;
    return new TextDecoder().decode(view.subarray(ptr, end));
}

/** Max cells in a grid disk of distance k. Throws on invalid k. */
export function maxGridDiskSize(k) {
    ensureInit();
    const r = Number(wasmExports.zig_h3_max_grid_disk_size(k));
    if (r < 0) throw new RangeError(`invalid k=${k}`);
    return r;
}

/**
 * Scalar latLngToCell. Input in degrees by default.
 * Returns BigInt H3 cell or 0n on error.
 */
export function latlngToCell(lat, lng, res, { units = 'degrees' } = {}) {
    ensureInit();
    let r_lat = lat, r_lng = lng;
    if (units === 'degrees') {
        r_lat *= DEG_TO_RAD;
        r_lng *= DEG_TO_RAD;
    } else if (units !== 'radians') {
        throw new TypeError(`units must be 'degrees' or 'radians'; got ${units}`);
    }
    return wasmExports.zig_h3_latlng_to_cell(r_lat, r_lng, res);
}

/**
 * Batch latLngToCell. `points` is an array of {lat, lng} (degrees).
 * Returns BigUint64Array of cell IDs.
 *
 * Allocates linear-memory scratch space inside the wasm heap, runs the
 * native batch function, and reads results back. Even with the copy
 * overhead this is faster than calling latlngToCell N times for N>~100.
 */
export function latlngToCellBatch(points, res, { units = 'degrees' } = {}) {
    ensureInit();
    const n = points.length;
    if (n === 0) return new BigUint64Array(0);

    // Allocate input/output scratch in wasm memory at the end of the
    // current memory region. We use `__heap_base` if exported, otherwise
    // bump from memory.buffer.byteLength. The wasm doesn't have a real
    // malloc — we treat the trailing region as scratch.
    const inputBytes = n * 16; // 2× f64 per point
    const outputBytes = n * 8; // u64 per result
    const totalNeeded = inputBytes + outputBytes;

    // Ensure room
    const currentSize = wasmMemory.buffer.byteLength;
    const heapBase = wasmExports.__heap_base ? wasmExports.__heap_base.value : 65536;
    const scratchStart = (heapBase + 15) & ~15; // 16-byte aligned
    const scratchEnd = scratchStart + totalNeeded;
    if (scratchEnd > currentSize) {
        const pagesNeeded = Math.ceil((scratchEnd - currentSize) / 65536);
        wasmMemory.grow(pagesNeeded);
    }

    const inputPtr = scratchStart;
    const outputPtr = scratchStart + inputBytes;

    // Write points as packed f64 lat/lng pairs
    const f64view = new Float64Array(wasmMemory.buffer, inputPtr, n * 2);
    if (units === 'degrees') {
        for (let i = 0; i < n; i++) {
            f64view[i * 2] = points[i].lat * DEG_TO_RAD;
            f64view[i * 2 + 1] = points[i].lng * DEG_TO_RAD;
        }
    } else if (units === 'radians') {
        for (let i = 0; i < n; i++) {
            f64view[i * 2] = points[i].lat;
            f64view[i * 2 + 1] = points[i].lng;
        }
    } else {
        throw new TypeError(`units must be 'degrees' or 'radians'; got ${units}`);
    }

    // Call
    wasmExports.zig_h3_latlng_to_cell_batch(inputPtr, n, res, outputPtr);

    // Read results
    const cells = new BigUint64Array(n);
    const u64view = new BigUint64Array(wasmMemory.buffer, outputPtr, n);
    cells.set(u64view);
    return cells;
}

export function isValidCell(cell) {
    ensureInit();
    return wasmExports.zig_h3_is_valid_cell(BigInt(cell)) !== 0;
}

export function isPentagon(cell) {
    ensureInit();
    return wasmExports.zig_h3_is_pentagon(BigInt(cell)) !== 0;
}

export function getResolution(cell) {
    ensureInit();
    return wasmExports.zig_h3_get_resolution(BigInt(cell));
}

export function getBaseCellNumber(cell) {
    ensureInit();
    return wasmExports.zig_h3_get_base_cell_number(BigInt(cell));
}

export function cellToParent(cell, parentRes) {
    ensureInit();
    return wasmExports.zig_h3_cell_to_parent(BigInt(cell), parentRes);
}

export function cellAreaKm2(cell) {
    ensureInit();
    return wasmExports.zig_h3_cell_area_km2(BigInt(cell));
}

export function cellCentroidDistanceKm(a, b) {
    ensureInit();
    return wasmExports.zig_h3_cell_centroid_distance_km(BigInt(a), BigInt(b));
}

const zigh3 = {
    init,
    libVersion,
    maxGridDiskSize,
    latlngToCell,
    latlngToCellBatch,
    isValidCell,
    isPentagon,
    getResolution,
    getBaseCellNumber,
    cellToParent,
    cellAreaKm2,
    cellCentroidDistanceKm,
};
export default zigh3;
