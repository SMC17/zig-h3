// Tests for the Node zigh3 binding. Run with:
//   ZIG_H3_LIB=/path/to/libzig_h3.so node --test test.js

const { test } = require('node:test');
const assert = require('node:assert');
const zigh3 = require('./index.js');

test('lib_version returns semver-like string', () => {
    const v = zigh3.libVersion();
    assert.match(v, /^\d+\.\d+\.\d+$/);
});

test('maxGridDiskSize(3) === 37', () => {
    assert.strictEqual(zigh3.maxGridDiskSize(3), 37);
});

test('maxGridDiskSize(-1) throws', () => {
    assert.throws(() => zigh3.maxGridDiskSize(-1), RangeError);
});

test('latlngToCellBatch on 3 landmark points', () => {
    const points = [
        { lat: 40.6892, lng: -74.0445 },
        { lat: 37.7749, lng: -122.4194 },
        { lat: 51.5074, lng: -0.1278 },
    ];
    const cells = zigh3.latlngToCellBatch(points, 9);
    assert.strictEqual(cells.length, 3);
    for (let i = 0; i < 3; i++) {
        assert.notStrictEqual(cells[i], 0n);
    }
});

test('parallel matches serial on 2048 points', () => {
    const n = 2048;
    const points = [];
    // LCG for deterministic input without depending on a seeded rng package
    let s = 0xCAFEBABEn;
    for (let i = 0; i < n; i++) {
        s = (s * 6364136223846793005n + 1442695040888963407n) & 0xFFFFFFFFFFFFFFFFn;
        const lat = ((Number(s >> 32n)) / 4294967295 - 0.5) * 178;
        s = (s * 6364136223846793005n + 1442695040888963407n) & 0xFFFFFFFFFFFFFFFFn;
        const lng = ((Number(s >> 32n)) / 4294967295 - 0.5) * 358;
        points.push({ lat, lng });
    }
    const serial = zigh3.latlngToCellBatch(points, 9);
    const parallel = zigh3.latlngToCellBatch(points, 9, { threads: 8 });
    for (let i = 0; i < n; i++) {
        assert.strictEqual(serial[i], parallel[i], `mismatch at ${i}`);
    }
});

test('grid disk: origin in its own k=1 disk', () => {
    const points = [{ lat: 40.6892, lng: -74.0445 }];
    const cells = zigh3.latlngToCellBatch(points, 9);
    const disks = zigh3.gridDiskBatch(cells, 1);
    let found = false;
    for (let i = 0; i < disks.length; i++) {
        if (disks[i] === cells[0]) {
            found = true;
            break;
        }
    }
    assert.ok(found, 'origin not in its own disk');
});
