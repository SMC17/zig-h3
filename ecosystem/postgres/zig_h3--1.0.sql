-- zig_h3 extension SQL — schema + function declarations.
-- Load with: CREATE EXTENSION zig_h3;

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION zig_h3" to load this file. \quit

CREATE FUNCTION h3_latlng_to_cell(lat double precision, lng double precision, res integer)
RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_h3_latlng_to_cell'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_cell_to_latlng(cell bigint)
RETURNS point
AS 'MODULE_PATHNAME', 'pg_h3_cell_to_latlng'
LANGUAGE C IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION h3_is_valid_cell(cell bigint)
RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_h3_is_valid_cell'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_is_pentagon(cell bigint)
RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_h3_is_pentagon'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_is_res_class_iii(cell bigint)
RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_h3_is_res_class_iii'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_get_resolution(cell bigint)
RETURNS integer
AS 'MODULE_PATHNAME', 'pg_h3_get_resolution'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_get_base_cell_number(cell bigint)
RETURNS integer
AS 'MODULE_PATHNAME', 'pg_h3_get_base_cell_number'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_cell_to_parent(cell bigint, parent_res integer)
RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_h3_cell_to_parent'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_cell_to_center_child(cell bigint, child_res integer)
RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_h3_cell_to_center_child'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_cell_to_parent_n(cell bigint, levels integer)
RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_h3_cell_to_parent_n'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_grid_distance(a bigint, b bigint)
RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_h3_grid_distance'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_are_neighbor_cells(a bigint, b bigint)
RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_h3_are_neighbor_cells'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_cell_area_km2(cell bigint)
RETURNS double precision
AS 'MODULE_PATHNAME', 'pg_h3_cell_area_km2'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_cell_centroid_distance_km(a bigint, b bigint)
RETURNS double precision
AS 'MODULE_PATHNAME', 'pg_h3_cell_centroid_distance_km'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_great_circle_distance_km(
    a_lat double precision, a_lng double precision,
    b_lat double precision, b_lng double precision
)
RETURNS double precision
AS 'MODULE_PATHNAME', 'pg_h3_great_circle_distance_km'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_max_grid_disk_size(k integer)
RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_h3_max_grid_disk_size'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

CREATE FUNCTION h3_get_hexagon_area_avg_km2(res integer)
RETURNS double precision
AS 'MODULE_PATHNAME', 'pg_h3_get_hexagon_area_avg_km2'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
