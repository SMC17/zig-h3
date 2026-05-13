//! Pure-Zig H3 polygon-to-cells — Phase 5c.
//!
//! Implements `maxPolygonToCellsSize` and `polygonToCells`. The algorithm:
//!
//! 1. Compute a bounding box from the polygon's outer loop.
//! 2. Seed a search set by mapping each polygon vertex to its containing cell.
//! 3. BFS flood-fill: pop a cell from the search frontier, check its k=1 ring
//!    via `gridDisk`, and for each new cell test `pointInsidePolygon` at its
//!    centroid. Cells that test positive go into the output set + frontier.
//! 4. Return the deduplicated output.
//!
//! Uses Zig's `std.AutoHashMap(H3Index, void)` for dedup, which is simpler
//! than libh3's open-addressed scheme but algorithmically equivalent.
//!
//! `cellsToLinkedMultiPolygon` (the inverse — cell set → polygon outline) is
//! deferred; it needs a linked-list multi-polygon data structure that's
//! mostly useful as a binding shim for higher-level languages.

const std = @import("std");
const root = @import("root.zig");
const pure = @import("pure.zig");
const h3idx = @import("pure_h3index.zig");
const h3dec = @import("pure_h3decode.zig");
const grid = @import("pure_grid.zig");
const bnd = @import("pure_boundary.zig");

pub const H3Index = root.H3Index;
pub const LatLng = root.LatLng;
pub const Error = root.Error;

pub const GeoLoop = struct {
    verts: []const LatLng,
};

pub const GeoPolygon = struct {
    geoloop: GeoLoop,
    holes: []const GeoLoop = &.{},
};

// =============================================================================
// Bounding box
// =============================================================================

pub const BBox = struct {
    north: f64, // max lat
    south: f64, // min lat
    east: f64, // max lng (may be < west if crosses antimeridian)
    west: f64, // min lng

    pub fn contains(self: BBox, p: LatLng) bool {
        if (p.lat < self.south or p.lat > self.north) return false;
        if (self.east >= self.west) {
            return p.lng >= self.west and p.lng <= self.east;
        } else {
            // crosses antimeridian
            return p.lng >= self.west or p.lng <= self.east;
        }
    }
};

pub fn bboxFromGeoLoop(loop: GeoLoop) BBox {
    if (loop.verts.len == 0) {
        return .{ .north = 0, .south = 0, .east = 0, .west = 0 };
    }
    var lat_min = loop.verts[0].lat;
    var lat_max = loop.verts[0].lat;
    var lng_min = loop.verts[0].lng;
    var lng_max = loop.verts[0].lng;
    var crosses_antimeridian = false;

    for (loop.verts[1..]) |v| {
        if (v.lat < lat_min) lat_min = v.lat;
        if (v.lat > lat_max) lat_max = v.lat;
        if (v.lng < lng_min) lng_min = v.lng;
        if (v.lng > lng_max) lng_max = v.lng;
    }

    // Detect antimeridian crossing: any edge spanning more than π radians.
    var i: usize = 0;
    while (i < loop.verts.len) : (i += 1) {
        const next = if (i == loop.verts.len - 1) 0 else i + 1;
        const dlng = @abs(loop.verts[next].lng - loop.verts[i].lng);
        if (dlng > std.math.pi) {
            crosses_antimeridian = true;
            break;
        }
    }
    if (crosses_antimeridian) {
        return .{ .north = lat_max, .south = lat_min, .east = lng_min, .west = lng_max };
    }
    return .{ .north = lat_max, .south = lat_min, .east = lng_max, .west = lng_min };
}

// =============================================================================
// Point-in-polygon (ray casting on a sphere with antimeridian handling)
// =============================================================================

pub fn pointInsideGeoLoop(loop: GeoLoop, bbox: BBox, p: LatLng) bool {
    if (!bbox.contains(p)) return false;

    var contains = false;
    var i: usize = 0;
    const n = loop.verts.len;
    if (n < 3) return false;

    var j: usize = n - 1;
    while (i < n) : ({
        j = i;
        i += 1;
    }) {
        const a = loop.verts[i];
        const b = loop.verts[j];

        // Handle antimeridian-crossing edges by un-wrapping.
        var a_lng = a.lng;
        var b_lng = b.lng;
        if (b_lng - a_lng > std.math.pi) b_lng -= 2.0 * std.math.pi;
        if (a_lng - b_lng > std.math.pi) a_lng -= 2.0 * std.math.pi;

        var p_lng = p.lng;
        if (a_lng < b_lng) {
            if (p_lng - a_lng > std.math.pi) p_lng -= 2.0 * std.math.pi;
            if (a_lng - p_lng > std.math.pi) p_lng += 2.0 * std.math.pi;
        }

        if ((a.lat > p.lat) != (b.lat > p.lat)) {
            const slope = (b_lng - a_lng) / (b.lat - a.lat);
            const intersect_lng = a_lng + (p.lat - a.lat) * slope;
            if (p_lng < intersect_lng) contains = !contains;
        }
    }
    return contains;
}

pub fn pointInsidePolygon(polygon: GeoPolygon, p: LatLng) bool {
    const outer_bbox = bboxFromGeoLoop(polygon.geoloop);
    if (!pointInsideGeoLoop(polygon.geoloop, outer_bbox, p)) return false;
    for (polygon.holes) |hole| {
        const hole_bbox = bboxFromGeoLoop(hole);
        if (pointInsideGeoLoop(hole, hole_bbox, p)) return false;
    }
    return true;
}

// =============================================================================
// maxPolygonToCellsSize — upper bound for output buffer sizing
// =============================================================================

pub fn maxPolygonToCellsSize(polygon: GeoPolygon, res: i32) Error!i64 {
    if (res < 0 or res > h3idx.MAX_RES) return Error.ResolutionDomain;
    const bbox = bboxFromGeoLoop(polygon.geoloop);

    // Estimate area in radians² (planar approximation, conservative).
    const lat_span = bbox.north - bbox.south;
    var lng_span = bbox.east - bbox.west;
    if (lng_span < 0) lng_span += 2.0 * std.math.pi;
    const mid_lat = (bbox.north + bbox.south) / 2.0;
    const area_rads2 = @abs(lat_span * lng_span * @cos(mid_lat));

    const hex_area_rads2: f64 = blk: {
        // Use closed-form: 4π / (2 + 120·7^r) for the average cell area.
        const num_cells_f: f64 = @floatFromInt(try pure.getNumCells(res));
        break :blk 4.0 * std.math.pi / num_cells_f;
    };
    if (hex_area_rads2 <= 0) return 0;

    var estimate: i64 = @intFromFloat(@ceil(area_rads2 / hex_area_rads2 * 2.0));

    // Per-vertex floor (libh3-style): at least one cell per vertex.
    var total_verts: i64 = @intCast(polygon.geoloop.verts.len);
    for (polygon.holes) |hole| total_verts += @intCast(hole.verts.len);
    if (estimate < total_verts) estimate = total_verts;

    // libh3 adds a fixed buffer for thin-polygon edge cases.
    const POLYGON_BUFFER: i64 = 12;
    estimate += POLYGON_BUFFER;
    return estimate;
}

// =============================================================================
// polygonToCells — edge-trace seed + BFS flood-fill via gridDisk
// =============================================================================

pub fn polygonToCells(
    allocator: std.mem.Allocator,
    polygon: GeoPolygon,
    res: i32,
    out: []H3Index,
) Error!usize {
    if (res < 0 or res > h3idx.MAX_RES) return Error.ResolutionDomain;
    if (polygon.geoloop.verts.len < 3) return 0;

    var visited = std.AutoHashMap(H3Index, void).init(allocator);
    defer visited.deinit();
    var inside = std.AutoHashMap(H3Index, void).init(allocator);
    defer inside.deinit();

    var frontier: std.ArrayList(H3Index) = .empty;
    defer frontier.deinit(allocator);

    // 1. Seed: every polygon vertex's containing cell goes in the frontier.
    for (polygon.geoloop.verts) |v| {
        const cell = try h3idx.latLngToCell(v, res);
        const prev = visited.fetchPut(cell, {}) catch return Error.MemoryAlloc;
        if (prev == null) {
            frontier.append(allocator, cell) catch return Error.MemoryAlloc;
            const center = try h3dec.cellToLatLng(cell);
            if (pointInsidePolygon(polygon, center)) {
                inside.put(cell, {}) catch return Error.MemoryAlloc;
            }
        }
    }
    for (polygon.holes) |hole| {
        for (hole.verts) |v| {
            const cell = try h3idx.latLngToCell(v, res);
            const prev = visited.fetchPut(cell, {}) catch return Error.MemoryAlloc;
            if (prev == null) {
                frontier.append(allocator, cell) catch return Error.MemoryAlloc;
            }
        }
    }

    // 2. BFS flood fill: pop, walk k=1 ring, classify each neighbor.
    while (frontier.items.len > 0) {
        const current = frontier.pop().?;
        var ring: [7]H3Index = .{ 0, 0, 0, 0, 0, 0, 0 };
        grid.gridDisk(current, 1, allocator, &ring) catch continue;
        for (ring) |neighbor| {
            if (neighbor == 0) continue;
            const prev = visited.fetchPut(neighbor, {}) catch return Error.MemoryAlloc;
            if (prev != null) continue;
            const center = h3dec.cellToLatLng(neighbor) catch continue;
            if (pointInsidePolygon(polygon, center)) {
                inside.put(neighbor, {}) catch return Error.MemoryAlloc;
                frontier.append(allocator, neighbor) catch return Error.MemoryAlloc;
            }
        }
    }

    // 3. Emit `inside` to `out`.
    var idx: usize = 0;
    var it = inside.keyIterator();
    while (it.next()) |k| {
        if (idx >= out.len) return Error.MemoryBounds;
        out[idx] = k.*;
        idx += 1;
    }
    return idx;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "bboxFromGeoLoop simple rectangle" {
    const verts = [_]LatLng{
        LatLng.fromDegrees(40.0, -75.0),
        LatLng.fromDegrees(41.0, -75.0),
        LatLng.fromDegrees(41.0, -74.0),
        LatLng.fromDegrees(40.0, -74.0),
    };
    const loop = GeoLoop{ .verts = &verts };
    const bbox = bboxFromGeoLoop(loop);
    try testing.expectApproxEqAbs(LatLng.fromDegrees(41.0, 0).lat, bbox.north, 1e-12);
    try testing.expectApproxEqAbs(LatLng.fromDegrees(40.0, 0).lat, bbox.south, 1e-12);
}

test "pointInsidePolygon simple square" {
    const verts = [_]LatLng{
        LatLng.fromDegrees(40.0, -75.0),
        LatLng.fromDegrees(41.0, -75.0),
        LatLng.fromDegrees(41.0, -74.0),
        LatLng.fromDegrees(40.0, -74.0),
    };
    const poly = GeoPolygon{ .geoloop = .{ .verts = &verts } };
    try testing.expect(pointInsidePolygon(poly, LatLng.fromDegrees(40.5, -74.5)));
    try testing.expect(!pointInsidePolygon(poly, LatLng.fromDegrees(42.0, -74.5)));
    try testing.expect(!pointInsidePolygon(poly, LatLng.fromDegrees(40.5, -73.0)));
}

test "polygonToCells on a 1° × 1° square at res 5 produces a reasonable count" {
    const verts = [_]LatLng{
        LatLng.fromDegrees(40.0, -75.0),
        LatLng.fromDegrees(41.0, -75.0),
        LatLng.fromDegrees(41.0, -74.0),
        LatLng.fromDegrees(40.0, -74.0),
    };
    const poly = GeoPolygon{ .geoloop = .{ .verts = &verts } };
    const max_size: usize = @intCast(try maxPolygonToCellsSize(poly, 5));
    const buf = try testing.allocator.alloc(H3Index, max_size);
    defer testing.allocator.free(buf);
    @memset(buf, 0);
    const count = try polygonToCells(testing.allocator, poly, 5, buf);

    // At res 5, average hex area is ~252 km². A 1° × 1° square ≈ 9,600 km²
    // → ~30–60 cells depending on alignment.
    try testing.expect(count > 20);
    try testing.expect(count < max_size);

    // Every emitted cell's centroid should be inside the polygon.
    for (buf[0..count]) |c| {
        const center = try h3dec.cellToLatLng(c);
        try testing.expect(pointInsidePolygon(poly, center));
    }
}

test "polygonToCells matches libh3 cell-count within tolerance on a small square" {
    const verts = [_]LatLng{
        LatLng.fromDegrees(40.0, -75.0),
        LatLng.fromDegrees(40.5, -75.0),
        LatLng.fromDegrees(40.5, -74.5),
        LatLng.fromDegrees(40.0, -74.5),
    };
    const poly = GeoPolygon{ .geoloop = .{ .verts = &verts } };

    var libh3_verts = [_]root.raw.LatLng{
        .{ .lat = verts[0].lat, .lng = verts[0].lng },
        .{ .lat = verts[1].lat, .lng = verts[1].lng },
        .{ .lat = verts[2].lat, .lng = verts[2].lng },
        .{ .lat = verts[3].lat, .lng = verts[3].lng },
    };
    const libh3_loop = root.raw.GeoLoop{ .numVerts = 4, .verts = &libh3_verts };
    const libh3_poly = root.raw.GeoPolygon{ .geoloop = libh3_loop, .numHoles = 0, .holes = null };

    var theirs_max: i64 = 0;
    _ = root.raw.maxPolygonToCellsSize(&libh3_poly, 6, 0, &theirs_max);
    const theirs_buf = try testing.allocator.alloc(H3Index, @intCast(theirs_max));
    defer testing.allocator.free(theirs_buf);
    @memset(theirs_buf, 0);
    _ = root.raw.polygonToCells(&libh3_poly, 6, 0, theirs_buf.ptr);
    var theirs_count: usize = 0;
    for (theirs_buf) |c| if (c != 0) {
        theirs_count += 1;
    };

    const max_size: usize = @intCast(try maxPolygonToCellsSize(poly, 6));
    const ours_buf = try testing.allocator.alloc(H3Index, max_size);
    defer testing.allocator.free(ours_buf);
    @memset(ours_buf, 0);
    const ours_count = try polygonToCells(testing.allocator, poly, 6, ours_buf);

    // The two algorithms (libh3's edge-trace + BFS, ours BFS-only) should
    // converge on the same cell set when both use the same "centroid inside
    // polygon" inclusion rule.
    try testing.expectEqual(theirs_count, ours_count);
}

// =============================================================================
// cellsToMultiPolygon — Phase 5d, the inverse of polygonToCells
//
// Translates libh3's `cellsToLinkedMultiPolygon` into an array-based result
// (replacing the linked-list representation with idiomatic Zig). The owning
// struct's `deinit(allocator)` plays the role of libh3's
// `destroyLinkedMultiPolygon`.
//
// Algorithm:
//   1. For each cell, walk its boundary edges. For each edge (from → to):
//      - If the reverse edge (to → from) already exists in the edge set,
//        remove it (a shared edge between two cells in the input set).
//      - Otherwise, add the forward edge.
//      After processing all cells, the remaining edges form the outline(s).
//   2. Walk the edge set to extract closed loops.
//   3. Classify each loop by signed-area winding order: CCW = outer, CW = hole.
//   4. Each outer loop becomes its own ResultPolygon; each hole is assigned
//      to the polygon whose outer loop contains it (via point-in-polygon).
// =============================================================================

pub const ResultLoop = struct {
    verts: []LatLng,
};

pub const ResultPolygon = struct {
    outer: ResultLoop,
    holes: []ResultLoop,
};

pub const MultiPolygon = struct {
    polygons: []ResultPolygon,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MultiPolygon) void {
        for (self.polygons) |p| {
            self.allocator.free(p.outer.verts);
            for (p.holes) |h| self.allocator.free(h.verts);
            self.allocator.free(p.holes);
        }
        self.allocator.free(self.polygons);
        self.polygons = &.{};
    }
};

const VERT_EPS: f64 = 1e-10;

inline fn latLngAlmostEqual(a: LatLng, b: LatLng) bool {
    return @abs(a.lat - b.lat) < VERT_EPS and @abs(a.lng - b.lng) < VERT_EPS;
}

const PolyEdge = struct { from: LatLng, to: LatLng };

fn loopSignedArea(verts: []const LatLng) f64 {
    var sum: f64 = 0.0;
    var i: usize = 0;
    while (i < verts.len) : (i += 1) {
        const a = verts[i];
        const b = verts[(i + 1) % verts.len];
        var alng = a.lng;
        var blng = b.lng;
        if (blng - alng > std.math.pi) blng -= 2.0 * std.math.pi;
        if (alng - blng > std.math.pi) alng -= 2.0 * std.math.pi;
        sum += (blng - alng) * (a.lat + b.lat);
    }
    return sum / 2.0;
}

inline fn isClockwiseLoop(verts: []const LatLng) bool {
    // Signed area via Σ (b.lng − a.lng)(a.lat + b.lat) / 2 is NEGATIVE for a
    // CCW polygon in (lng, lat) standard axes (verified on a unit square).
    // libh3 treats CCW as the outer-loop convention, so clockwise means
    // signed area > 0 with this formula.
    return loopSignedArea(verts) > 0;
}

fn loopBBox(verts: []const LatLng) BBox {
    return bboxFromGeoLoop(.{ .verts = verts });
}

pub fn cellsToMultiPolygon(allocator: std.mem.Allocator, cells: []const H3Index) Error!MultiPolygon {
    if (cells.len == 0) {
        return .{ .polygons = &.{}, .allocator = allocator };
    }

    // 1. Build the edge set with shared-edge cancellation.
    var edges: std.ArrayList(PolyEdge) = .empty;
    defer edges.deinit(allocator);

    for (cells) |cell| {
        const bd = try bnd.cellToBoundary(cell);
        const n: usize = @intCast(bd.num_verts);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            const from = bd.verts[j];
            const to = bd.verts[(j + 1) % n];
            // Search for reverse edge (to → from) — shared boundary
            var rev_idx: ?usize = null;
            for (edges.items, 0..) |e, i| {
                if (latLngAlmostEqual(e.from, to) and latLngAlmostEqual(e.to, from)) {
                    rev_idx = i;
                    break;
                }
            }
            if (rev_idx) |idx| {
                _ = edges.swapRemove(idx);
            } else {
                edges.append(allocator, .{ .from = from, .to = to }) catch return Error.MemoryAlloc;
            }
        }
    }

    // 2. Walk edges into closed loops.
    var loops: std.ArrayList(std.ArrayList(LatLng)) = .empty;
    defer {
        for (loops.items) |*l| l.deinit(allocator);
        loops.deinit(allocator);
    }

    while (edges.items.len > 0) {
        var loop: std.ArrayList(LatLng) = .empty;
        const first = edges.items[0];
        _ = edges.swapRemove(0);
        loop.append(allocator, first.from) catch {
            loop.deinit(allocator);
            return Error.MemoryAlloc;
        };
        var next_vtx = first.to;
        const loop_start = first.from;

        while (!latLngAlmostEqual(next_vtx, loop_start)) {
            var found: ?usize = null;
            for (edges.items, 0..) |e, i| {
                if (latLngAlmostEqual(e.from, next_vtx)) {
                    found = i;
                    break;
                }
            }
            if (found) |idx| {
                const e = edges.items[idx];
                _ = edges.swapRemove(idx);
                loop.append(allocator, e.from) catch {
                    loop.deinit(allocator);
                    return Error.MemoryAlloc;
                };
                next_vtx = e.to;
            } else {
                // Loop didn't close — input was malformed. Bail.
                loop.deinit(allocator);
                for (loops.items) |*l| l.deinit(allocator);
                loops.clearRetainingCapacity();
                return Error.Failed;
            }
        }
        loops.append(allocator, loop) catch {
            loop.deinit(allocator);
            return Error.MemoryAlloc;
        };
    }

    // 3. Classify loops by winding. CCW (positive signed area) = outer; CW = hole.
    var outer_indices: std.ArrayList(usize) = .empty;
    defer outer_indices.deinit(allocator);
    var hole_indices: std.ArrayList(usize) = .empty;
    defer hole_indices.deinit(allocator);

    for (loops.items, 0..) |loop, idx| {
        if (isClockwiseLoop(loop.items)) {
            hole_indices.append(allocator, idx) catch return Error.MemoryAlloc;
        } else {
            outer_indices.append(allocator, idx) catch return Error.MemoryAlloc;
        }
    }

    // 4. Assign holes to outer loops by point-in-polygon. For each hole, find
    //    the smallest-area outer containing the hole's first vertex (the
    //    "smallest containing" rule handles nested polygons cleanly).
    const outer_bboxes = allocator.alloc(BBox, outer_indices.items.len) catch return Error.MemoryAlloc;
    defer allocator.free(outer_bboxes);
    for (outer_indices.items, 0..) |loop_idx, oi| {
        outer_bboxes[oi] = loopBBox(loops.items[loop_idx].items);
    }

    const hole_assignments = allocator.alloc(?usize, hole_indices.items.len) catch return Error.MemoryAlloc;
    defer allocator.free(hole_assignments);
    for (hole_assignments) |*h| h.* = null;

    for (hole_indices.items, 0..) |hole_idx, hi| {
        const hole_loop = loops.items[hole_idx].items;
        if (hole_loop.len == 0) continue;
        const probe = hole_loop[0];

        var best_outer: ?usize = null;
        var best_area: f64 = std.math.inf(f64);
        for (outer_indices.items, 0..) |outer_idx, oi| {
            const outer_verts = loops.items[outer_idx].items;
            if (!pointInsideGeoLoop(.{ .verts = outer_verts }, outer_bboxes[oi], probe)) continue;
            const area = @abs(loopSignedArea(outer_verts));
            if (area < best_area) {
                best_area = area;
                best_outer = oi;
            }
        }
        hole_assignments[hi] = best_outer;
    }

    // 5. Materialize the result.
    var polygons = allocator.alloc(ResultPolygon, outer_indices.items.len) catch return Error.MemoryAlloc;

    for (outer_indices.items, 0..) |outer_loop_idx, oi| {
        const src = loops.items[outer_loop_idx].items;
        const verts_copy = allocator.dupe(LatLng, src) catch return Error.MemoryAlloc;
        polygons[oi] = .{ .outer = .{ .verts = verts_copy }, .holes = &.{} };
    }

    // Count holes per outer to allocate hole arrays.
    const holes_per_outer = allocator.alloc(usize, outer_indices.items.len) catch return Error.MemoryAlloc;
    defer allocator.free(holes_per_outer);
    @memset(holes_per_outer, 0);
    for (hole_assignments) |h| if (h) |idx| {
        holes_per_outer[idx] += 1;
    };

    for (polygons, 0..) |*poly, oi| {
        if (holes_per_outer[oi] == 0) continue;
        poly.holes = allocator.alloc(ResultLoop, holes_per_outer[oi]) catch return Error.MemoryAlloc;
    }

    const hole_cursors = allocator.alloc(usize, outer_indices.items.len) catch return Error.MemoryAlloc;
    defer allocator.free(hole_cursors);
    @memset(hole_cursors, 0);

    for (hole_indices.items, hole_assignments) |hole_loop_idx, assignment| {
        if (assignment) |oi| {
            const src = loops.items[hole_loop_idx].items;
            const copy = allocator.dupe(LatLng, src) catch return Error.MemoryAlloc;
            polygons[oi].holes[hole_cursors[oi]] = .{ .verts = copy };
            hole_cursors[oi] += 1;
        }
    }

    return .{ .polygons = polygons, .allocator = allocator };
}

test "cellsToMultiPolygon on a single hex cell produces one polygon with one outer loop" {
    const cell = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 7);
    if (pure.isPentagon(cell)) return;
    var mp = try cellsToMultiPolygon(testing.allocator, &[_]H3Index{cell});
    defer mp.deinit();
    try testing.expectEqual(@as(usize, 1), mp.polygons.len);
    try testing.expectEqual(@as(usize, 0), mp.polygons[0].holes.len);
    // A non-Class-III hex has 6 vertices; Class III has up to 10.
    try testing.expect(mp.polygons[0].outer.verts.len >= 6 and mp.polygons[0].outer.verts.len <= 10);
}

test "cellsToMultiPolygon on a 7-cell gridDisk produces one polygon" {
    const center = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 6);
    if (pure.isPentagon(center)) return;
    var ring: [7]H3Index = .{ 0, 0, 0, 0, 0, 0, 0 };
    try grid.gridDiskUnsafe(center, 1, &ring);
    // Skip if any cell on ring is a pentagon (test setup invariant).
    for (ring) |c| if (c == 0 or pure.isPentagon(c)) return;

    var mp = try cellsToMultiPolygon(testing.allocator, &ring);
    defer mp.deinit();
    try testing.expectEqual(@as(usize, 1), mp.polygons.len);
    try testing.expectEqual(@as(usize, 0), mp.polygons[0].holes.len);
    // A 7-cell disk has 6 outer vertices per neighbor × 6 + some pent adjustments
    // — empirically lands in [18, 36] vertices depending on Class III intersections.
    try testing.expect(mp.polygons[0].outer.verts.len >= 12);
}

test "cellsToMultiPolygon detects a hole when the input set has a gap" {
    // Disk-minus-center: 6 neighbors of a hex cell, with the center removed.
    const center = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 6);
    if (pure.isPentagon(center)) return;
    var ring: [7]H3Index = .{ 0, 0, 0, 0, 0, 0, 0 };
    try grid.gridDiskUnsafe(center, 1, &ring);
    var donut: [6]H3Index = undefined;
    var idx: usize = 0;
    for (ring) |c| {
        if (c == 0 or c == center) continue;
        if (pure.isPentagon(c)) return;
        donut[idx] = c;
        idx += 1;
    }
    if (idx != 6) return;

    var mp = try cellsToMultiPolygon(testing.allocator, &donut);
    defer mp.deinit();
    try testing.expectEqual(@as(usize, 1), mp.polygons.len);
    // The donut has one outer ring and one hole (the missing center cell).
    try testing.expectEqual(@as(usize, 1), mp.polygons[0].holes.len);
}

test "cellsToMultiPolygon on disjoint cell pairs produces two polygons" {
    const a = try root.latLngToCell(LatLng.fromDegrees(40.0, -74.0), 5);
    const b = try root.latLngToCell(LatLng.fromDegrees(40.0, 74.0), 5);
    if (pure.isPentagon(a) or pure.isPentagon(b)) return;
    var mp = try cellsToMultiPolygon(testing.allocator, &[_]H3Index{ a, b });
    defer mp.deinit();
    try testing.expectEqual(@as(usize, 2), mp.polygons.len);
    for (mp.polygons) |p| try testing.expectEqual(@as(usize, 0), p.holes.len);
}

test "cellsToMultiPolygon on empty input returns empty multi-polygon" {
    var mp = try cellsToMultiPolygon(testing.allocator, &[_]H3Index{});
    defer mp.deinit();
    try testing.expectEqual(@as(usize, 0), mp.polygons.len);
}
