# Postgres extension Makefile. Builds zig_h3.so and links against libzig_h3.so.
#
# Build the parent project first:
#   cd ../../ && zig build -Doptimize=ReleaseFast
# Then:
#   cd ecosystem/postgres
#   make
#   sudo make install
#   psql -c 'CREATE EXTENSION zig_h3;'

EXTENSION = zig_h3
DATA = zig_h3--1.0.sql
MODULES = zig_h3

# Link against libzig_h3.so. Caller can override by setting ZIG_H3_LIB_DIR.
ZIG_H3_LIB_DIR ?= $(realpath ../../zig-out/lib)
SHLIB_LINK = -L$(ZIG_H3_LIB_DIR) -lzig_h3 -Wl,-rpath,$(ZIG_H3_LIB_DIR)

# PGXS standard build
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
