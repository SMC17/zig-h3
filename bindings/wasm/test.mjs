// Tests for the WASM binding. Run with:
//   node --test bindings/wasm/test.mjs

import { test } from 'node:test';
import assert from 'node:assert';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import * as zigh3 from './zigh3.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const WASM_PATH = resolve(__dirname, '../../zig-out/lib/zig_h3.wasm');

await zigh3.init(WASM_PATH);

test('libVersion is semver', () => {
    const v = zigh3.libVersion();
    assert.match(v, /^\d+\.\d+\.\d+$/);
});

test('maxGridDiskSize(3) === 37', () => {
    assert.strictEqual(zigh3.maxGridDiskSize(3), 37);
});

test('maxGridDiskSize(-1) throws', () => {
    assert.throws(() => zigh3.maxGridDiskSize(-1), RangeError);
});

test('latlngToCell NYC res 9 → known cell', () => {
    const cell = zigh3.latlngToCell(40.6892, -74.0445, 9);
    // 0x892a1072b5bffff — same known answer as Python binding's tests
    assert.strictEqual(cell, 0x892a1072b5bffffn);
});

test('latlngToCellBatch on 3 landmarks matches scalar', () => {
    const points = [
        { lat: 40.6892, lng: -74.0445 },
        { lat: 37.7749, lng: -122.4194 },
        { lat: 51.5074, lng: -0.1278 },
    ];
    const cells = zigh3.latlngToCellBatch(points, 9);
    for (let i = 0; i < 3; i++) {
        const scalar = zigh3.latlngToCell(points[i].lat, points[i].lng, 9);
        assert.strictEqual(cells[i], scalar, `mismatch at ${i}: batch=${cells[i]} scalar=${scalar}`);
    }
});

test('isPentagon: NYC cell is not a pentagon', () => {
    const cell = zigh3.latlngToCell(40.6892, -74.0445, 9);
    assert.strictEqual(zigh3.isPentagon(cell), false);
});

test('getResolution roundtrips', () => {
    const cell = zigh3.latlngToCell(40.6892, -74.0445, 9);
    assert.strictEqual(zigh3.getResolution(cell), 9);
});

test('cellToParent walks up', () => {
    const cell9 = zigh3.latlngToCell(40.6892, -74.0445, 9);
    const cell7 = zigh3.cellToParent(cell9, 7);
    assert.strictEqual(zigh3.getResolution(cell7), 7);
});

test('cellCentroidDistanceKm NYC ↔ SF ~ 4128', () => {
    const nyc = zigh3.latlngToCell(40.6892, -74.0445, 9);
    const sf = zigh3.latlngToCell(37.7749, -122.4194, 9);
    const dist = zigh3.cellCentroidDistanceKm(nyc, sf);
    assert.ok(Math.abs(dist - 4128) < 10, `distance ${dist} not near 4128`);
});

test('cellAreaKm2 at res 9 ~ 0.1', () => {
    const cell = zigh3.latlngToCell(40.6892, -74.0445, 9);
    const area = zigh3.cellAreaKm2(cell);
    assert.ok(Math.abs(area - 0.1) < 0.05, `area ${area} not near 0.1`);
});
