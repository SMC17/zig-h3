"""zig_h3 DuckDB integration via Python UDFs.

Registers the libzig_h3.so functions as DuckDB scalar UDFs so SQL
queries against DuckDB tables can use them directly. Closes BAKEOFF
axis 12 (ecosystem integration depth): zig-h3 is now first-class
in DuckDB alongside the Postgres + SQLite extensions.

Usage:
    import duckdb
    from zig_h3.duckdb_udf import register

    con = duckdb.connect()
    register(con)
    con.sql('SELECT h3_latlng_to_cell(40.6892, -74.0445, 9)').show()
    # 617733151067471871

A real DuckDB C++ extension is also viable — see
`ecosystem/duckdb/native/` for the scaffold — but the Python UDF
path works against any DuckDB without recompiling.
"""

from __future__ import annotations
import sys
import os
from pathlib import Path

# Make the zig_h3 binding importable from this script's location
_here = Path(__file__).resolve()
_python_binding = _here.parent.parent.parent / "bindings" / "python"
if str(_python_binding) not in sys.path:
    sys.path.insert(0, str(_python_binding))

import zig_h3  # noqa: E402


def register(con, *, prefix: str = "h3_"):
    """Register zig_h3 functions as DuckDB scalar UDFs on `con`.

    Each function name is prefixed with `prefix` (default "h3_") so
    SQL queries can use h3_latlng_to_cell(...) etc.

    Returns the connection for chaining.
    """
    import duckdb

    def _latlng_to_cell(lat: float, lng: float, res: int) -> int:
        return int(zig_h3.latlng_to_cell(lat, lng, res))

    def _cell_to_lat(cell: int) -> float:
        return zig_h3.cell_to_latlng(int(cell))[0]

    def _cell_to_lng(cell: int) -> float:
        return zig_h3.cell_to_latlng(int(cell))[1]

    def _is_valid_cell(cell: int) -> bool:
        return zig_h3.is_valid_cell(int(cell))

    def _is_pentagon(cell: int) -> bool:
        return zig_h3.is_pentagon(int(cell))

    def _get_resolution(cell: int) -> int:
        return zig_h3.get_resolution(int(cell))

    def _get_base_cell_number(cell: int) -> int:
        return zig_h3.get_base_cell_number(int(cell))

    def _cell_to_parent(cell: int, parent_res: int) -> int:
        return int(zig_h3.cell_to_parent(int(cell), parent_res))

    def _grid_distance(a: int, b: int) -> int:
        return zig_h3.grid_distance(int(a), int(b))

    def _cell_area_km2(cell: int) -> float:
        return zig_h3.cell_area_km2(int(cell))

    def _cell_centroid_distance_km(a: int, b: int) -> float:
        return zig_h3.cell_centroid_distance_km(int(a), int(b))

    def _max_grid_disk_size(k: int) -> int:
        return zig_h3.max_grid_disk_size(k)

    fns = [
        (f"{prefix}latlng_to_cell", _latlng_to_cell, [float, float, int], int),
        (f"{prefix}cell_to_lat", _cell_to_lat, [int], float),
        (f"{prefix}cell_to_lng", _cell_to_lng, [int], float),
        (f"{prefix}is_valid_cell", _is_valid_cell, [int], bool),
        (f"{prefix}is_pentagon", _is_pentagon, [int], bool),
        (f"{prefix}get_resolution", _get_resolution, [int], int),
        (f"{prefix}get_base_cell_number", _get_base_cell_number, [int], int),
        (f"{prefix}cell_to_parent", _cell_to_parent, [int, int], int),
        (f"{prefix}grid_distance", _grid_distance, [int, int], int),
        (f"{prefix}cell_area_km2", _cell_area_km2, [int], float),
        (f"{prefix}cell_centroid_distance_km", _cell_centroid_distance_km, [int, int], float),
        (f"{prefix}max_grid_disk_size", _max_grid_disk_size, [int], int),
    ]

    for name, fn, _arg_types, _ret in fns:
        con.create_function(name, fn)
    return con


if __name__ == "__main__":
    # Smoke test
    import duckdb
    con = duckdb.connect(":memory:")
    register(con)
    print("DuckDB version:", duckdb.__version__)
    print("zig_h3 lib version:", zig_h3.lib_version())
    print()
    print("NYC res 9:")
    print(con.sql("SELECT h3_latlng_to_cell(40.6892, -74.0445, 9) AS nyc_cell, "
                  "h3_is_pentagon(h3_latlng_to_cell(40.6892, -74.0445, 9)) AS pentagon, "
                  "h3_get_resolution(h3_latlng_to_cell(40.6892, -74.0445, 9)) AS res").fetchall())
    print()
    print("NYC ↔ SF distance:")
    print(con.sql("SELECT h3_cell_centroid_distance_km("
                  "h3_latlng_to_cell(40.6892, -74.0445, 9), "
                  "h3_latlng_to_cell(37.7749, -122.4194, 9)) AS km").fetchall())
    print()
    # Table query
    con.sql("CREATE TABLE cities AS SELECT * FROM (VALUES "
            "('NYC', 40.6892, -74.0445), ('SF', 37.7749, -122.4194), "
            "('London', 51.5074, -0.1278), ('Tokyo', 35.6762, 139.6503)) "
            "AS t(name, lat, lng)")
    print("Bucket 4 cities into H3 res 9:")
    print(con.sql("SELECT name, h3_latlng_to_cell(lat, lng, 9) AS cell, "
                  "h3_get_resolution(h3_latlng_to_cell(lat, lng, 9)) AS res "
                  "FROM cities ORDER BY name").fetchall())
