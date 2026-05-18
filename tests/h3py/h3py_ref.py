#!/usr/bin/env python3
"""h3-py reference oracle. Reads (op, lat_rad, lng_rad, res) from stdin, prints
the H3Index in hex. Used by zig-h3's differential harness."""
import sys, json, h3

for line in sys.stdin:
    line = line.strip()
    if not line: continue
    parts = line.split()
    op = parts[0]
    if op == "latlng_to_cell":
        # Args: lat_rad lng_rad res
        lat_rad, lng_rad, res = float(parts[1]), float(parts[2]), int(parts[3])
        lat_deg = lat_rad * 180.0 / 3.141592653589793
        lng_deg = lng_rad * 180.0 / 3.141592653589793
        cell = h3.latlng_to_cell(lat_deg, lng_deg, res)
        print(f"cell={int(cell, 16):x}")
    elif op == "cell_to_latlng":
        cell_hex = parts[1]
        lat, lng = h3.cell_to_latlng(cell_hex)
        lat_rad = lat * 3.141592653589793 / 180.0
        lng_rad = lng * 3.141592653589793 / 180.0
        print(f"latlng={lat_rad:.15g} {lng_rad:.15g}")
    elif op == "get_resolution":
        cell_hex = parts[1]
        print(f"resolution={h3.get_resolution(cell_hex)}")
    elif op == "grid_disk_size":
        k = int(parts[1])
        # max_grid_disk_size
        print(f"size={3 * k * (k + 1) + 1}")
    elif op == "is_pentagon":
        cell_hex = parts[1]
        print(f"pentagon={int(h3.is_pentagon(cell_hex))}")
    else:
        print(f"unknown op: {op}")
