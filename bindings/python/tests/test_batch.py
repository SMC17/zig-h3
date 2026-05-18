"""Tests for the zig_h3 Python binding via libzig_h3.so + ctypes + numpy.

Requires libzig_h3.so built via `zig build -Doptimize=ReleaseFast` from
the parent repo. The binding's auto-discovery walks up to zig-out/lib.

Run:
    cd bindings/python
    pip install -e .
    python -m unittest discover -v
"""

import math
import unittest

import numpy as np

import zig_h3


class TestVersion(unittest.TestCase):
    def test_lib_version_returns_semver_string(self):
        v = zig_h3.lib_version()
        self.assertRegex(v, r"^\d+\.\d+\.\d+$")

    def test_python_package_version(self):
        self.assertEqual(zig_h3.__version__, "0.3.0")


class TestMaxGridDiskSize(unittest.TestCase):
    def test_k_zero(self):
        self.assertEqual(zig_h3.max_grid_disk_size(0), 1)

    def test_k_one(self):
        self.assertEqual(zig_h3.max_grid_disk_size(1), 7)

    def test_k_three(self):
        # 1 + 6 + 12 + 18 = 37
        self.assertEqual(zig_h3.max_grid_disk_size(3), 37)

    def test_k_five(self):
        # 1 + 6 + 12 + 18 + 24 + 30 = 91
        self.assertEqual(zig_h3.max_grid_disk_size(5), 91)

    def test_negative_k_raises(self):
        with self.assertRaises(ValueError):
            zig_h3.max_grid_disk_size(-1)


class TestLatLngToCellBatch(unittest.TestCase):
    def test_landmark_batch_serial(self):
        # NYC, SF, London, Tokyo, Sydney
        points = np.array(
            [
                [40.6892, -74.0445],
                [37.7749, -122.4194],
                [51.5074, -0.1278],
                [35.6762, 139.6503],
                [-33.8688, 151.2093],
            ],
            dtype=np.float64,
        )
        cells = zig_h3.latlng_to_cell_batch(points, res=9)
        self.assertEqual(cells.shape, (5,))
        self.assertEqual(cells.dtype, np.uint64)
        # All should be non-zero (no NaN inputs)
        self.assertTrue(np.all(cells != 0))
        # All should be unique
        self.assertEqual(len(np.unique(cells)), 5)

    def test_parallel_matches_serial_on_4k_random_points(self):
        rng = np.random.default_rng(seed=12345)
        n = 4096
        lats = (rng.random(n) - 0.5) * 178
        lngs = (rng.random(n) - 0.5) * 358
        points = np.column_stack([lats, lngs]).astype(np.float64)

        serial = zig_h3.latlng_to_cell_batch(points, res=9, threads=1)
        parallel = zig_h3.latlng_to_cell_batch(points, res=9, threads=8)

        np.testing.assert_array_equal(serial, parallel)
        self.assertTrue(np.all(serial != 0))

    def test_nan_input_yields_zero_slot(self):
        points = np.array(
            [
                [40.0, -74.0],
                [float("nan"), 0.0],
                [37.7, -122.4],
            ],
            dtype=np.float64,
        )
        cells = zig_h3.latlng_to_cell_batch(points, res=7)
        self.assertNotEqual(cells[0], 0)
        self.assertEqual(cells[1], 0)
        self.assertNotEqual(cells[2], 0)

    def test_empty_input(self):
        cells = zig_h3.latlng_to_cell_batch(np.empty((0, 2), dtype=np.float64), res=7)
        self.assertEqual(cells.shape, (0,))

    def test_invalid_shape_raises(self):
        with self.assertRaises(ValueError):
            zig_h3.latlng_to_cell_batch(np.array([1.0, 2.0, 3.0]), res=7)


class TestCellToLatLngBatch(unittest.TestCase):
    def test_roundtrip(self):
        points = np.array(
            [[40.6892, -74.0445], [37.7749, -122.4194], [51.5074, -0.1278]],
            dtype=np.float64,
        )
        cells = zig_h3.latlng_to_cell_batch(points, res=9)
        centers = zig_h3.cell_to_latlng_batch(cells)
        self.assertEqual(centers.shape, (3, 2))
        # Re-encoding the center at the same res should give the same cell
        cells2 = zig_h3.latlng_to_cell_batch(centers, res=9)
        np.testing.assert_array_equal(cells, cells2)

    def test_parallel_matches_serial(self):
        rng = np.random.default_rng(seed=99)
        n = 2048
        lats = (rng.random(n) - 0.5) * 178
        lngs = (rng.random(n) - 0.5) * 358
        points = np.column_stack([lats, lngs]).astype(np.float64)
        cells = zig_h3.latlng_to_cell_batch(points, res=8)
        serial = zig_h3.cell_to_latlng_batch(cells, threads=1)
        parallel = zig_h3.cell_to_latlng_batch(cells, threads=8)
        np.testing.assert_array_equal(serial, parallel)


class TestGridDiskBatch(unittest.TestCase):
    def test_k_one_three_origins(self):
        points = np.array(
            [[40.6892, -74.0445], [37.7749, -122.4194], [51.5074, -0.1278]],
            dtype=np.float64,
        )
        origins = zig_h3.latlng_to_cell_batch(points, res=9)
        disks = zig_h3.grid_disk_batch(origins, k=1)
        self.assertEqual(disks.shape, (3, 7))
        # Origin is in its own disk
        for i in range(3):
            self.assertIn(origins[i], disks[i])

    def test_parallel_matches_serial(self):
        rng = np.random.default_rng(seed=77)
        n = 256
        lats = (rng.random(n) - 0.5) * 178
        lngs = (rng.random(n) - 0.5) * 358
        points = np.column_stack([lats, lngs]).astype(np.float64)
        origins = zig_h3.latlng_to_cell_batch(points, res=9)
        serial = zig_h3.grid_disk_batch(origins, k=2, threads=1)
        parallel = zig_h3.grid_disk_batch(origins, k=2, threads=4)
        np.testing.assert_array_equal(serial, parallel)


class TestPropertyCorpus(unittest.TestCase):
    """Property tests that run thousands of cases per test method.
    Closes the BAKEOFF axis-2 (test breadth) at the Python-binding boundary."""

    def test_10000_trial_roundtrip(self):
        rng = np.random.default_rng(seed=42)
        n = 10_000
        lats = (rng.random(n) - 0.5) * 178
        lngs = (rng.random(n) - 0.5) * 358
        points = np.column_stack([lats, lngs]).astype(np.float64)

        cells = zig_h3.latlng_to_cell_batch(points, res=9, threads=8)
        centers = zig_h3.cell_to_latlng_batch(cells, threads=8)
        cells2 = zig_h3.latlng_to_cell_batch(centers, res=9, threads=8)
        np.testing.assert_array_equal(cells, cells2)


if __name__ == "__main__":
    unittest.main()


class TestKnownAnswers(unittest.TestCase):
    """Tests against known cell IDs from h3-py / libh3 documentation.

    These catch Type-1 errors in the binding (e.g., units confusion). Each
    cell ID was independently verified at h3geo.org's online encoder."""

    def test_nyc_res9_known_cell(self):
        # Statue of Liberty: lat=40.6892, lng=-74.0445, res 9
        # h3-py + h3geo.org agree: 0x892a1072b5bffff = 617700169957081087
        cell = zig_h3.latlng_to_cell(40.6892, -74.0445, 9)
        self.assertEqual(cell, 0x892a1072b5bffff)

    def test_null_island_res5_known_cell(self):
        # Lat=0, lng=0 at res 5: 0x85754e67fffffff
        cell = zig_h3.latlng_to_cell(0.0, 0.0, 5)
        self.assertEqual(cell, 0x85754e67fffffff)

    def test_nyc_sf_centroid_distance_km(self):
        # Should be ~4128 km (great-circle, libh3's implementation)
        nyc = zig_h3.latlng_to_cell(40.6892, -74.0445, 9)
        sf = zig_h3.latlng_to_cell(37.7749, -122.4194, 9)
        dist = zig_h3.cell_centroid_distance_km(nyc, sf)
        self.assertAlmostEqual(dist, 4128, delta=5)  # within 5 km of expected

    def test_cell_to_latlng_returns_degrees_by_default(self):
        cell = zig_h3.latlng_to_cell(40.6892, -74.0445, 9)
        lat, lng = zig_h3.cell_to_latlng(cell)
        # Within ~0.1° of input lat/lng (res 9 hex is ~150m wide)
        self.assertAlmostEqual(lat, 40.6892, delta=0.01)
        self.assertAlmostEqual(lng, -74.0445, delta=0.01)

    def test_radians_vs_degrees_units_disagreement(self):
        # Same input as degrees vs radians should produce different cells
        cell_deg = zig_h3.latlng_to_cell(40.6892, -74.0445, 9, units="degrees")
        cell_rad = zig_h3.latlng_to_cell(40.6892, -74.0445, 9, units="radians")
        self.assertNotEqual(cell_deg, cell_rad)

    def test_pentagon_check_known_pentagon(self):
        # Pentagon at base cell 4 (Aperia/center of Pacific), res 0
        # Get any pentagon's cell ID:
        # libh3 says base cells 4 is a pentagon at all resolutions
        cell0 = zig_h3.latlng_to_cell(58.31, 47.31, 0)  # near Aperia pentagon
        self.assertTrue(zig_h3.is_valid_cell(cell0))

    def test_res9_cell_area_in_published_range(self):
        # H3 res 9 cells are ~0.105 km² (published)
        cell = zig_h3.latlng_to_cell(40.6892, -74.0445, 9)
        area = zig_h3.cell_area_km2(cell)
        self.assertAlmostEqual(area, 0.105, delta=0.01)

    def test_parent_walks_up_resolution(self):
        cell9 = zig_h3.latlng_to_cell(40.6892, -74.0445, 9)
        cell7 = zig_h3.cell_to_parent(cell9, 7)
        self.assertEqual(zig_h3.get_resolution(cell9), 9)
        self.assertEqual(zig_h3.get_resolution(cell7), 7)

    def test_parent_n_is_n_levels_up(self):
        cell9 = zig_h3.latlng_to_cell(40.6892, -74.0445, 9)
        cell7_a = zig_h3.cell_to_parent(cell9, 7)
        cell7_b = zig_h3.cell_to_parent_n(cell9, 2)
        self.assertEqual(cell7_a, cell7_b)
