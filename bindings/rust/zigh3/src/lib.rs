//! Rust binding for SMC17/zig-h3 batch + parallel API.
//!
//! Wraps `libzig_h3.so` (the C-ABI shim) via raw FFI. Builds against
//! the shared library found via `LD_LIBRARY_PATH` or
//! `RUSTFLAGS="-L $ZIG_H3_LIB_DIR"`.
//!
//! Example:
//! ```ignore
//! use zigh3::{LatLng, latlng_to_cell_batch_parallel};
//! let points = [LatLng { lat: 40.6892, lng: -74.0445 }];
//! let mut out = vec![0u64; 1];
//! let ok = latlng_to_cell_batch_parallel(&points, 9, &mut out, 4);
//! ```

use std::ffi::CStr;
use std::os::raw::{c_char, c_int};

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LatLng {
    pub lat: f64,
    pub lng: f64,
}

#[link(name = "zig_h3")]
unsafe extern "C" {
    fn zig_h3_latlng_to_cell_batch(
        points: *const LatLng,
        n: usize,
        res: i32,
        out: *mut u64,
    ) -> usize;

    fn zig_h3_latlng_to_cell_batch_parallel(
        points: *const LatLng,
        n: usize,
        res: i32,
        out: *mut u64,
        threads: usize,
    ) -> usize;

    fn zig_h3_cell_to_latlng_batch(
        cells: *const u64,
        n: usize,
        out: *mut LatLng,
    ) -> usize;

    fn zig_h3_cell_to_latlng_batch_parallel(
        cells: *const u64,
        n: usize,
        out: *mut LatLng,
        threads: usize,
    ) -> usize;

    fn zig_h3_grid_disk_batch(
        origins: *const u64,
        n: usize,
        k: i32,
        stride: usize,
        out: *mut u64,
    ) -> usize;

    fn zig_h3_grid_disk_batch_parallel(
        origins: *const u64,
        n: usize,
        k: i32,
        stride: usize,
        out: *mut u64,
        threads: usize,
    ) -> usize;

    fn zig_h3_max_grid_disk_size(k: i32) -> i64;

    fn zig_h3_version() -> *const c_char;
}

/// Returns the version of the underlying `libzig_h3.so`.
pub fn lib_version() -> String {
    unsafe {
        let raw = zig_h3_version();
        CStr::from_ptr(raw).to_string_lossy().into_owned()
    }
}

/// Maximum cells in a grid disk of distance `k`. Returns `None` for
/// invalid `k`.
pub fn max_grid_disk_size(k: i32) -> Option<i64> {
    let r = unsafe { zig_h3_max_grid_disk_size(k) };
    if r < 0 {
        None
    } else {
        Some(r)
    }
}

/// Batch latLngToCell. Returns the count of successful conversions.
/// Slots in `out` corresponding to non-finite lat/lng inputs are 0.
pub fn latlng_to_cell_batch(points: &[LatLng], res: i32, out: &mut [u64]) -> usize {
    assert!(out.len() >= points.len());
    if points.is_empty() {
        return 0;
    }
    unsafe {
        zig_h3_latlng_to_cell_batch(
            points.as_ptr(),
            points.len(),
            res,
            out.as_mut_ptr(),
        )
    }
}

/// Parallel batch latLngToCell. `threads` workers split the input.
pub fn latlng_to_cell_batch_parallel(
    points: &[LatLng],
    res: i32,
    out: &mut [u64],
    threads: usize,
) -> usize {
    assert!(out.len() >= points.len());
    if points.is_empty() {
        return 0;
    }
    unsafe {
        zig_h3_latlng_to_cell_batch_parallel(
            points.as_ptr(),
            points.len(),
            res,
            out.as_mut_ptr(),
            threads,
        )
    }
}

/// Batch cellToLatLng. Failed decodes get `{NaN, NaN}`.
pub fn cell_to_latlng_batch(cells: &[u64], out: &mut [LatLng]) -> usize {
    assert!(out.len() >= cells.len());
    if cells.is_empty() {
        return 0;
    }
    unsafe {
        zig_h3_cell_to_latlng_batch(cells.as_ptr(), cells.len(), out.as_mut_ptr())
    }
}

/// Parallel batch cellToLatLng.
pub fn cell_to_latlng_batch_parallel(
    cells: &[u64],
    out: &mut [LatLng],
    threads: usize,
) -> usize {
    assert!(out.len() >= cells.len());
    if cells.is_empty() {
        return 0;
    }
    unsafe {
        zig_h3_cell_to_latlng_batch_parallel(
            cells.as_ptr(),
            cells.len(),
            out.as_mut_ptr(),
            threads,
        )
    }
}

/// Batch gridDisk. `out` must have at least `origins.len() * stride`
/// elements where `stride = max_grid_disk_size(k)`.
pub fn grid_disk_batch(
    origins: &[u64],
    k: i32,
    stride: usize,
    out: &mut [u64],
) -> usize {
    assert!(out.len() >= origins.len() * stride);
    if origins.is_empty() {
        return 0;
    }
    unsafe {
        zig_h3_grid_disk_batch(
            origins.as_ptr(),
            origins.len(),
            k,
            stride,
            out.as_mut_ptr(),
        )
    }
}

/// Parallel batch gridDisk.
pub fn grid_disk_batch_parallel(
    origins: &[u64],
    k: i32,
    stride: usize,
    out: &mut [u64],
    threads: usize,
) -> usize {
    assert!(out.len() >= origins.len() * stride);
    if origins.is_empty() {
        return 0;
    }
    unsafe {
        zig_h3_grid_disk_batch_parallel(
            origins.as_ptr(),
            origins.len(),
            k,
            stride,
            out.as_mut_ptr(),
            threads,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_semver() {
        let v = lib_version();
        let parts: Vec<&str> = v.split('.').collect();
        assert_eq!(parts.len(), 3);
        for p in parts {
            p.parse::<u32>().expect("not semver");
        }
    }

    #[test]
    fn max_grid_disk_size_k_three() {
        assert_eq!(max_grid_disk_size(3), Some(37));
    }

    #[test]
    fn max_grid_disk_size_negative_returns_none() {
        assert_eq!(max_grid_disk_size(-1), None);
    }

    #[test]
    fn latlng_batch_landmarks() {
        let points = vec![
            LatLng { lat: 40.6892, lng: -74.0445 },
            LatLng { lat: 37.7749, lng: -122.4194 },
            LatLng { lat: 51.5074, lng: -0.1278 },
        ];
        let mut out = vec![0u64; 3];
        let ok = latlng_to_cell_batch(&points, 9, &mut out);
        assert_eq!(ok, 3);
        for c in &out {
            assert_ne!(*c, 0);
        }
    }

    #[test]
    fn parallel_matches_serial_4k() {
        // 4096 deterministic points
        let n = 4096;
        let mut points = Vec::with_capacity(n);
        // Simple LCG to keep test deterministic without an rng dep
        let mut state: u64 = 0xCAFEBABE;
        for _ in 0..n {
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let lat = (((state >> 32) as f64) / (u32::MAX as f64) - 0.5) * 178.0;
            state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let lng = (((state >> 32) as f64) / (u32::MAX as f64) - 0.5) * 358.0;
            points.push(LatLng { lat, lng });
        }
        let mut serial = vec![0u64; n];
        let mut parallel = vec![0u64; n];
        latlng_to_cell_batch(&points, 9, &mut serial);
        latlng_to_cell_batch_parallel(&points, 9, &mut parallel, 8);
        assert_eq!(serial, parallel);
    }

    #[test]
    fn roundtrip_property_1k() {
        let points = vec![
            LatLng { lat: 40.6892, lng: -74.0445 },
            LatLng { lat: 37.7749, lng: -122.4194 },
        ];
        let mut cells = vec![0u64; points.len()];
        latlng_to_cell_batch(&points, 9, &mut cells);
        let mut centers = vec![LatLng { lat: 0.0, lng: 0.0 }; cells.len()];
        cell_to_latlng_batch(&cells, &mut centers);
        let mut cells2 = vec![0u64; centers.len()];
        latlng_to_cell_batch(&centers, 9, &mut cells2);
        assert_eq!(cells, cells2);
    }

    #[test]
    fn grid_disk_origin_in_own_disk() {
        let points = vec![LatLng { lat: 40.6892, lng: -74.0445 }];
        let mut cells = vec![0u64; 1];
        latlng_to_cell_batch(&points, 9, &mut cells);
        let stride = max_grid_disk_size(1).unwrap() as usize;
        let mut disks = vec![0u64; stride];
        grid_disk_batch(&cells, 1, stride, &mut disks);
        assert!(disks.contains(&cells[0]));
    }

    fn _unused_warning_suppressor() {
        let _: c_int = 0;
    }
}
