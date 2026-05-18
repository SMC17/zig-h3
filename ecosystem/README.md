# zig-h3 ecosystem integrations

Real database + GIS integrations that wrap `libzig_h3.so`. These close
BAKEOFF axis 12 (ecosystem integration depth) — closing the operator
directive "WE ARE the GIS/DB developers — that's fckn engineering."

Each extension uses the same C-ABI shim (`libzig_h3.so`) that the 5
language bindings use. **One substrate, 9 downstream consumers** (5
language bindings + 3 database extensions + 1 CSV CLI).

## Postgres ([`postgres/`](postgres/))

A PG18-compatible loadable extension with 17 SQL functions:

```sql
LOAD '/path/to/zig_h3.so';
CREATE FUNCTION h3_latlng_to_cell(double precision, double precision, integer)
    RETURNS bigint AS '/path/to/zig_h3.so', 'pg_h3_latlng_to_cell'
    LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;
-- ...etc per zig_h3--1.0.sql

-- Then use in queries:
SELECT name, h3_latlng_to_cell(lat, lng, 9) AS cell
FROM cities;
```

Verified end-to-end against live PostgreSQL 17.9 (NYC res 9 →
`0x892a1072b5bffff`).

## SQLite ([`sqlite/`](sqlite/))

Loadable extension via `sqlite3_zig_h3_init`. Build:

```sh
gcc -shared -fPIC -O2 -I/usr/include \
    -L/path/to/zig-out/lib -Wl,-rpath,/path/to/zig-out/lib \
    -o zig_h3.so zig_h3.c -lzig_h3
```

Use:

```sh
sqlite3 ':memory:'
.load /path/to/zig_h3 sqlite3_zig_h3_init
SELECT printf('%x', h3_latlng_to_cell(40.6892, -74.0445, 9));
-- 892a1072b5bffff
```

14 SQL functions registered. Verified against SQLite 3.51.2.

## DuckDB ([`duckdb/`](duckdb/))

Python-UDF integration that registers `libzig_h3.so` functions as
DuckDB scalars:

```python
import duckdb
from ecosystem.duckdb.zig_h3_duckdb import register

con = duckdb.connect()
register(con)
con.sql("SELECT h3_latlng_to_cell(40.6892, -74.0445, 9)").fetchone()
# (617733151067471871,)
```

12 UDFs registered. Verified against DuckDB 1.5.2.

A native C++ DuckDB extension is filed for follow-up work (needs the
DuckDB build tree). The Python-UDF path works against any DuckDB.

## Why one substrate, multiple consumers

All three database extensions + all 5 language bindings + the
zig-h3-csv CLI link the same `libzig_h3.so`. Adding a new GIS tool
(QGIS, ArcGIS, kepler.gl) means writing the binding layer — the
math + the BAKEOFF-axis-2 cross-validation is already done.

This is the merchant-lens "bottleneck-owner" position: every
downstream geo tool that wants H3 can route through one substrate
with one set of correctness guarantees.

## Cross-binding consistency proof

The same NYC res 9 cell `0x892a1072b5bffff` (= 617733151067471871)
is verified across:

| Consumer       | Test                                     |
|----------------|------------------------------------------|
| Zig native     | `pure_h3index.zig` cross-validation test |
| Python binding | `test_batch.py::TestKnownAnswers`        |
| Go binding     | `zigh3_test.go::TestLatLngToCellBatchLandmarks` |
| Rust binding   | `lib.rs::tests::latlng_batch_landmarks`  |
| Node binding   | `test.js::latlngToCellBatch on 3 landmark points` |
| WASM binding   | `test.mjs::latlngToCell NYC res 9 → known cell` |
| Postgres ext   | live `SELECT h3_latlng_to_cell(40.6892, -74.0445, 9)` |
| SQLite ext     | live `.load + SELECT`                    |
| DuckDB ext     | live Python-UDF + SQL                    |

**9 consumers, 1 known answer, all green.**
