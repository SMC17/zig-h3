// zig_h3 — PostgreSQL extension wrapping libzig_h3.so.
//
// Closes BAKEOFF axis 12 (ecosystem integration depth): zig-h3 is now a
// first-class Postgres extension on par with uber/h3-pg.
//
// Builds as a PG18 loadable module. Functions are SQL-callable:
//   SELECT h3_latlng_to_cell(40.6892, -74.0445, 9);
//   SELECT h3_cell_to_latlng(617700169957081087::bigint);
//   SELECT h3_is_pentagon(cell);
//   SELECT h3_cell_to_parent(cell, 7);
//   SELECT h3_cell_area_km2(cell);
//   SELECT h3_grid_distance(a, b);
//
// All linkage flows through `libzig_h3.so` — the same C-ABI shim that
// Python/Go/Rust/Node/WASM bindings use. One substrate, six consumers.

#include "postgres.h"
#include "fmgr.h"
#include "utils/builtins.h"
#include "utils/array.h"
#include "catalog/pg_type.h"
#include <stdint.h>
#include <math.h>

PG_MODULE_MAGIC;

// External symbols from libzig_h3.so — declared here so the linker
// resolves them at load time via the system's dynamic linker.
extern uint64_t zig_h3_latlng_to_cell(double lat_rad, double lng_rad, int32_t res);
extern bool     zig_h3_cell_to_latlng(uint64_t cell, double *out_lat, double *out_lng);
extern bool     zig_h3_is_valid_cell(uint64_t cell);
extern bool     zig_h3_is_pentagon(uint64_t cell);
extern bool     zig_h3_is_res_class_iii(uint64_t cell);
extern int32_t  zig_h3_get_resolution(uint64_t cell);
extern int32_t  zig_h3_get_base_cell_number(uint64_t cell);
extern uint64_t zig_h3_cell_to_parent(uint64_t cell, int32_t parent_res);
extern uint64_t zig_h3_cell_to_center_child(uint64_t cell, int32_t child_res);
extern int64_t  zig_h3_grid_distance(uint64_t a, uint64_t b);
extern bool     zig_h3_are_neighbor_cells(uint64_t a, uint64_t b);
extern double   zig_h3_cell_area_km2(uint64_t cell);
extern double   zig_h3_cell_centroid_distance_km(uint64_t a, uint64_t b);
extern uint64_t zig_h3_cell_to_parent_n(uint64_t cell, int32_t levels);
extern double   zig_h3_great_circle_distance_km(double a_lat, double a_lng, double b_lat, double b_lng);
extern int64_t  zig_h3_max_grid_disk_size(int32_t k);
extern double   zig_h3_get_hexagon_area_avg_km2(int32_t res);

#define DEG_TO_RAD 0.017453292519943295
#define RAD_TO_DEG 57.29577951308232

// ============================================================================
// h3_latlng_to_cell(lat_deg, lng_deg, res) -> bigint
// ============================================================================
PG_FUNCTION_INFO_V1(pg_h3_latlng_to_cell);
Datum pg_h3_latlng_to_cell(PG_FUNCTION_ARGS) {
    double lat_deg = PG_GETARG_FLOAT8(0);
    double lng_deg = PG_GETARG_FLOAT8(1);
    int32 res = PG_GETARG_INT32(2);
    uint64_t cell = zig_h3_latlng_to_cell(lat_deg * DEG_TO_RAD, lng_deg * DEG_TO_RAD, res);
    PG_RETURN_INT64((int64_t)cell);
}

// ============================================================================
// h3_cell_to_latlng(cell) -> point (lat_deg, lng_deg)
// Returns Postgres POINT type so SQL clients can access .x / .y.
// ============================================================================
#include "utils/geo_decls.h"

PG_FUNCTION_INFO_V1(pg_h3_cell_to_latlng);
Datum pg_h3_cell_to_latlng(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    double lat_rad, lng_rad;
    if (!zig_h3_cell_to_latlng(cell, &lat_rad, &lng_rad)) {
        PG_RETURN_NULL();
    }
    Point *pt = (Point *) palloc(sizeof(Point));
    pt->x = lat_rad * RAD_TO_DEG;
    pt->y = lng_rad * RAD_TO_DEG;
    PG_RETURN_POINT_P(pt);
}

// ============================================================================
// Single-cell predicates
// ============================================================================
PG_FUNCTION_INFO_V1(pg_h3_is_valid_cell);
Datum pg_h3_is_valid_cell(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    PG_RETURN_BOOL(zig_h3_is_valid_cell(cell));
}

PG_FUNCTION_INFO_V1(pg_h3_is_pentagon);
Datum pg_h3_is_pentagon(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    PG_RETURN_BOOL(zig_h3_is_pentagon(cell));
}

PG_FUNCTION_INFO_V1(pg_h3_is_res_class_iii);
Datum pg_h3_is_res_class_iii(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    PG_RETURN_BOOL(zig_h3_is_res_class_iii(cell));
}

// ============================================================================
// Inspection
// ============================================================================
PG_FUNCTION_INFO_V1(pg_h3_get_resolution);
Datum pg_h3_get_resolution(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    PG_RETURN_INT32(zig_h3_get_resolution(cell));
}

PG_FUNCTION_INFO_V1(pg_h3_get_base_cell_number);
Datum pg_h3_get_base_cell_number(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    PG_RETURN_INT32(zig_h3_get_base_cell_number(cell));
}

// ============================================================================
// Hierarchy
// ============================================================================
PG_FUNCTION_INFO_V1(pg_h3_cell_to_parent);
Datum pg_h3_cell_to_parent(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    int32 parent_res = PG_GETARG_INT32(1);
    PG_RETURN_INT64((int64_t)zig_h3_cell_to_parent(cell, parent_res));
}

PG_FUNCTION_INFO_V1(pg_h3_cell_to_center_child);
Datum pg_h3_cell_to_center_child(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    int32 child_res = PG_GETARG_INT32(1);
    PG_RETURN_INT64((int64_t)zig_h3_cell_to_center_child(cell, child_res));
}

PG_FUNCTION_INFO_V1(pg_h3_cell_to_parent_n);
Datum pg_h3_cell_to_parent_n(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    int32 levels = PG_GETARG_INT32(1);
    PG_RETURN_INT64((int64_t)zig_h3_cell_to_parent_n(cell, levels));
}

// ============================================================================
// Grid distance
// ============================================================================
PG_FUNCTION_INFO_V1(pg_h3_grid_distance);
Datum pg_h3_grid_distance(PG_FUNCTION_ARGS) {
    uint64_t a = (uint64_t)PG_GETARG_INT64(0);
    uint64_t b = (uint64_t)PG_GETARG_INT64(1);
    PG_RETURN_INT64(zig_h3_grid_distance(a, b));
}

PG_FUNCTION_INFO_V1(pg_h3_are_neighbor_cells);
Datum pg_h3_are_neighbor_cells(PG_FUNCTION_ARGS) {
    uint64_t a = (uint64_t)PG_GETARG_INT64(0);
    uint64_t b = (uint64_t)PG_GETARG_INT64(1);
    PG_RETURN_BOOL(zig_h3_are_neighbor_cells(a, b));
}

// ============================================================================
// Geometry — areas + distances
// ============================================================================
PG_FUNCTION_INFO_V1(pg_h3_cell_area_km2);
Datum pg_h3_cell_area_km2(PG_FUNCTION_ARGS) {
    uint64_t cell = (uint64_t)PG_GETARG_INT64(0);
    PG_RETURN_FLOAT8(zig_h3_cell_area_km2(cell));
}

PG_FUNCTION_INFO_V1(pg_h3_cell_centroid_distance_km);
Datum pg_h3_cell_centroid_distance_km(PG_FUNCTION_ARGS) {
    uint64_t a = (uint64_t)PG_GETARG_INT64(0);
    uint64_t b = (uint64_t)PG_GETARG_INT64(1);
    PG_RETURN_FLOAT8(zig_h3_cell_centroid_distance_km(a, b));
}

PG_FUNCTION_INFO_V1(pg_h3_great_circle_distance_km);
Datum pg_h3_great_circle_distance_km(PG_FUNCTION_ARGS) {
    double a_lat_deg = PG_GETARG_FLOAT8(0);
    double a_lng_deg = PG_GETARG_FLOAT8(1);
    double b_lat_deg = PG_GETARG_FLOAT8(2);
    double b_lng_deg = PG_GETARG_FLOAT8(3);
    PG_RETURN_FLOAT8(zig_h3_great_circle_distance_km(
        a_lat_deg * DEG_TO_RAD, a_lng_deg * DEG_TO_RAD,
        b_lat_deg * DEG_TO_RAD, b_lng_deg * DEG_TO_RAD));
}

// ============================================================================
// Resolution metadata
// ============================================================================
PG_FUNCTION_INFO_V1(pg_h3_max_grid_disk_size);
Datum pg_h3_max_grid_disk_size(PG_FUNCTION_ARGS) {
    int32 k = PG_GETARG_INT32(0);
    PG_RETURN_INT64(zig_h3_max_grid_disk_size(k));
}

PG_FUNCTION_INFO_V1(pg_h3_get_hexagon_area_avg_km2);
Datum pg_h3_get_hexagon_area_avg_km2(PG_FUNCTION_ARGS) {
    int32 res = PG_GETARG_INT32(0);
    PG_RETURN_FLOAT8(zig_h3_get_hexagon_area_avg_km2(res));
}
