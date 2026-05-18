// zig_h3 — SQLite loadable extension wrapping libzig_h3.so.
//
// Closes BAKEOFF axis 12 (ecosystem integration depth): SQLite is now
// first-class alongside the Postgres extension.
//
// Usage:
//   sqlite3 ':memory:'
//   .load /path/to/zig_h3
//   SELECT h3_latlng_to_cell(40.6892, -74.0445, 9);
//   -- 617733151067471871 (NYC res 9, same answer as h3-py / h3-pg / etc.)
//
// Build with the SQLITE_EXTENSION_INIT API:
//   gcc -fPIC -shared -O2 \
//       -L/path/to/zig-out/lib -Wl,-rpath,/path/to/zig-out/lib \
//       -o zig_h3.so zig_h3.c -lzig_h3

#include <sqlite3ext.h>
SQLITE_EXTENSION_INIT1

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>

// External symbols from libzig_h3.so
extern uint64_t zig_h3_latlng_to_cell(double lat_rad, double lng_rad, int32_t res);
extern bool     zig_h3_cell_to_latlng(uint64_t cell, double *out_lat, double *out_lng);
extern bool     zig_h3_is_valid_cell(uint64_t cell);
extern bool     zig_h3_is_pentagon(uint64_t cell);
extern bool     zig_h3_is_res_class_iii(uint64_t cell);
extern int32_t  zig_h3_get_resolution(uint64_t cell);
extern int32_t  zig_h3_get_base_cell_number(uint64_t cell);
extern uint64_t zig_h3_cell_to_parent(uint64_t cell, int32_t parent_res);
extern int64_t  zig_h3_grid_distance(uint64_t a, uint64_t b);
extern double   zig_h3_cell_area_km2(uint64_t cell);
extern double   zig_h3_cell_centroid_distance_km(uint64_t a, uint64_t b);
extern double   zig_h3_great_circle_distance_km(double a_lat, double a_lng, double b_lat, double b_lng);
extern int64_t  zig_h3_max_grid_disk_size(int32_t k);

#define DEG_TO_RAD 0.017453292519943295
#define RAD_TO_DEG 57.29577951308232

// ============================================================================
// h3_latlng_to_cell(lat_deg, lng_deg, res) -> integer
// ============================================================================
static void fn_latlng_to_cell(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    double lat_deg = sqlite3_value_double(argv[0]);
    double lng_deg = sqlite3_value_double(argv[1]);
    int res = sqlite3_value_int(argv[2]);
    uint64_t cell = zig_h3_latlng_to_cell(lat_deg * DEG_TO_RAD, lng_deg * DEG_TO_RAD, res);
    sqlite3_result_int64(ctx, (sqlite3_int64)cell);
}

// ============================================================================
// h3_cell_to_latlng_lat(cell) / h3_cell_to_latlng_lng(cell) — two scalars
// since SQLite doesn't have a native struct/tuple. Returns degrees.
// ============================================================================
static void fn_cell_to_lat(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t cell = (uint64_t)sqlite3_value_int64(argv[0]);
    double lat_rad, lng_rad;
    if (!zig_h3_cell_to_latlng(cell, &lat_rad, &lng_rad)) {
        sqlite3_result_null(ctx);
        return;
    }
    sqlite3_result_double(ctx, lat_rad * RAD_TO_DEG);
}

static void fn_cell_to_lng(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t cell = (uint64_t)sqlite3_value_int64(argv[0]);
    double lat_rad, lng_rad;
    if (!zig_h3_cell_to_latlng(cell, &lat_rad, &lng_rad)) {
        sqlite3_result_null(ctx);
        return;
    }
    sqlite3_result_double(ctx, lng_rad * RAD_TO_DEG);
}

// ============================================================================
// Predicates + inspection
// ============================================================================
static void fn_is_valid_cell(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t cell = (uint64_t)sqlite3_value_int64(argv[0]);
    sqlite3_result_int(ctx, zig_h3_is_valid_cell(cell) ? 1 : 0);
}

static void fn_is_pentagon(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t cell = (uint64_t)sqlite3_value_int64(argv[0]);
    sqlite3_result_int(ctx, zig_h3_is_pentagon(cell) ? 1 : 0);
}

static void fn_is_res_class_iii(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t cell = (uint64_t)sqlite3_value_int64(argv[0]);
    sqlite3_result_int(ctx, zig_h3_is_res_class_iii(cell) ? 1 : 0);
}

static void fn_get_resolution(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t cell = (uint64_t)sqlite3_value_int64(argv[0]);
    sqlite3_result_int(ctx, zig_h3_get_resolution(cell));
}

static void fn_get_base_cell_number(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t cell = (uint64_t)sqlite3_value_int64(argv[0]);
    sqlite3_result_int(ctx, zig_h3_get_base_cell_number(cell));
}

// ============================================================================
// Hierarchy
// ============================================================================
static void fn_cell_to_parent(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t cell = (uint64_t)sqlite3_value_int64(argv[0]);
    int parent_res = sqlite3_value_int(argv[1]);
    sqlite3_result_int64(ctx, (sqlite3_int64)zig_h3_cell_to_parent(cell, parent_res));
}

// ============================================================================
// Distance + area
// ============================================================================
static void fn_grid_distance(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t a = (uint64_t)sqlite3_value_int64(argv[0]);
    uint64_t b = (uint64_t)sqlite3_value_int64(argv[1]);
    sqlite3_result_int64(ctx, zig_h3_grid_distance(a, b));
}

static void fn_cell_area_km2(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t cell = (uint64_t)sqlite3_value_int64(argv[0]);
    sqlite3_result_double(ctx, zig_h3_cell_area_km2(cell));
}

static void fn_cell_centroid_distance_km(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    uint64_t a = (uint64_t)sqlite3_value_int64(argv[0]);
    uint64_t b = (uint64_t)sqlite3_value_int64(argv[1]);
    sqlite3_result_double(ctx, zig_h3_cell_centroid_distance_km(a, b));
}

static void fn_great_circle_distance_km(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    double a_lat = sqlite3_value_double(argv[0]);
    double a_lng = sqlite3_value_double(argv[1]);
    double b_lat = sqlite3_value_double(argv[2]);
    double b_lng = sqlite3_value_double(argv[3]);
    sqlite3_result_double(ctx, zig_h3_great_circle_distance_km(
        a_lat * DEG_TO_RAD, a_lng * DEG_TO_RAD,
        b_lat * DEG_TO_RAD, b_lng * DEG_TO_RAD));
}

static void fn_max_grid_disk_size(sqlite3_context *ctx, int argc, sqlite3_value **argv) {
    (void)argc;
    int k = sqlite3_value_int(argv[0]);
    sqlite3_result_int64(ctx, zig_h3_max_grid_disk_size(k));
}

// ============================================================================
// Loadable-extension entry point.
// SQLite invokes sqlite3_<libname>_init when the extension is loaded.
// libname here is "zig_h3" (from the .so filename), so the entry point
// is sqlite3_zig_h3_init.
// ============================================================================
#ifdef _WIN32
__declspec(dllexport)
#endif
int sqlite3_zig_h3_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi) {
    SQLITE_EXTENSION_INIT2(pApi);
    (void)pzErrMsg;
    int rc;

    #define R(name, nargs, fn) do { \
        rc = sqlite3_create_function( \
            db, name, nargs, SQLITE_UTF8 | SQLITE_DETERMINISTIC | SQLITE_INNOCUOUS, \
            NULL, fn, NULL, NULL); \
        if (rc != SQLITE_OK) return rc; \
    } while (0)

    R("h3_latlng_to_cell",            3, fn_latlng_to_cell);
    R("h3_cell_to_lat",                1, fn_cell_to_lat);
    R("h3_cell_to_lng",                1, fn_cell_to_lng);
    R("h3_is_valid_cell",              1, fn_is_valid_cell);
    R("h3_is_pentagon",                1, fn_is_pentagon);
    R("h3_is_res_class_iii",           1, fn_is_res_class_iii);
    R("h3_get_resolution",             1, fn_get_resolution);
    R("h3_get_base_cell_number",       1, fn_get_base_cell_number);
    R("h3_cell_to_parent",             2, fn_cell_to_parent);
    R("h3_grid_distance",              2, fn_grid_distance);
    R("h3_cell_area_km2",              1, fn_cell_area_km2);
    R("h3_cell_centroid_distance_km",  2, fn_cell_centroid_distance_km);
    R("h3_great_circle_distance_km",   4, fn_great_circle_distance_km);
    R("h3_max_grid_disk_size",         1, fn_max_grid_disk_size);

    return SQLITE_OK;
    #undef R
}
