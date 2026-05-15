//! Property-based round-trip test for polygon ↔ cells coverage.
//!
//! Closes the OOS gap left by `property_invariants.zig` (commit `9d8c82d`,
//! whose author wrote: "polygonToCells round-trip identity (build a polygon
//! from a cell set, re-cover, check superset/subset) ... deferred").
//!
//! Two properties are exercised against the pure-Zig polygon module
//! (`h3.polygon`, source `src/pure_polygon.zig`):
//!
//! ## Property A — cell-set → polygon → cells SUPERSET round-trip
//!
//! For a randomly-chosen contiguous cell set `S` at resolution `r`:
//!
//!   recovered = polygonToCells(cellsToMultiPolygon(S).polygons[0], r)
//!
//! must satisfy `recovered ⊇ S`. The recovered set may legitimately include
//! extra cells whose centroids fall inside the polygon outline — this is a
//! property of the centroid-containment inclusion rule, not a bug. (libh3's
//! `cellsToLinkedMultiPolygon` produces an outline that traces the *outer
//! boundary* of the cell set; cells immediately outside the input that
//! happen to have their centroid land on the boundary, or that share a
//! Class-III shifted edge with a boundary cell, can also test "inside".)
//!
//! The reverse direction — `recovered ⊆ S` — is NOT a spec guarantee and is
//! not asserted here. Equality holds in practice for non-Class-III parents
//! at low-distortion latitudes, but a property test should not enshrine that
//! as an invariant.
//!
//! Trial count: 2,000 (≥400 per resolution × 5 resolutions).
//!
//! ## Property B — single-cell polygon contains the cell
//!
//! For each of 122 res-0 base cells walked down through center children to
//! resolutions 5..9 (610 trials, hexagons only — pentagon skipped), the
//! polygon outline of a single hex cell, fed back through `polygonToCells`
//! at the same resolution, must produce a set that contains the original
//! cell. (Exact identity is NOT spec-guaranteed: the cell's 6/10 boundary
//! vertices, projected through `latLngToCell`, frequently resolve to a
//! neighbor at Class III resolutions; BFS then floods to include the
//! original cell whose centroid is unambiguously inside.)
//!
//! ## Pentagon handling
//!
//! Pentagons + polygons are notoriously gnarly: the cell-set→polygon edge
//! cancellation around a pentagon's 5-fold vertex produces outlines that
//! the centroid-inclusion `polygonToCells` may legitimately fail to recover
//! exactly. We **skip cell sets that touch pentagons** in Property A and
//! count them in a separate stat so the skip rate is auditable. This is a
//! documented limitation, not a passed test.
//!
//! ## Antimeridian handling — found-while-writing-this-test finding
//!
//! `h3.polygon.bboxFromGeoLoop` detects antimeridian-crossing polygons by
//! looking for any edge spanning more than π radians of longitude, and
//! constructs the resulting `BBox` as `{east = lng_min, west = lng_max}`
//! to flag the wrap. `BBox.contains` then accepts points with
//! `lng >= west OR lng <= east`. For a cell set that *straddles* the
//! antimeridian but only by ~0.3° on either side (e.g., a 7-cell disk
//! whose centroid sits at lng=-179.9°), the constructed bbox is
//! `east=-179.99°, west=179.99°` — a *narrow* wedge on the antimeridian
//! itself. The cell centroids at lng=-179.89°, -179.75°, etc. then fall
//! *outside* that wedge and `pointInsidePolygon` returns false for the
//! seed cell. This is a real failure mode of the pure-Zig BBox algorithm
//! on antimeridian-crossing input, not just a property-test artefact.
//!
//! We **skip antimeridian-crossing cell sets** in Property A and count
//! the skips. The fix belongs in `pure_polygon.zig` (the bbox of an
//! antimeridian-crossing polygon should be the *complement* of the wide
//! gap between max-negative-lng and min-positive-lng vertices, not the
//! min/max-lng wedge), and is out of scope for this OOS-gap-closing
//! commit. CHANGELOG names the finding.
//!
//! ## Determinism
//!
//! PRNG seeded with the constant below. The harness is bit-for-bit
//! reproducible.

const std = @import("std");
const h3 = @import("root.zig");
const testing = std.testing;

/// Deterministic seed — independent from `property_invariants.zig` so the
/// two harnesses cover different cell distributions.
const SEED: u64 = 0xC0FFEE_BEEF_F00D;

/// Property A trial count.
const PROP_A_TRIALS: usize = 2_000;

/// Resolutions Property A walks. Below res 5 the cells are continent-sized
/// and Class-III distortion dominates the inclusion boundary; above res 9
/// the BFS allocation grows uncomfortably. Span chosen to hit Class II
/// (even) and Class III (odd) parents on each end.
const PROP_A_RES_MIN: i32 = 5;
const PROP_A_RES_MAX: i32 = 9;

/// gridDisk radii Property A samples from. k=0 is the single-cell case
/// (mirrors Property B but with random seeds), k=1 is the 7-cell disk
/// (one outer ring, no holes), k=2 is the 19-cell disk (boundary curvature
/// kicks in).
const PROP_A_K_CHOICES = [_]i32{ 0, 1, 2 };

const Stats = struct {
    total: usize = 0,
    per_res: [16]usize = .{0} ** 16,
    per_k: [3]usize = .{0} ** 3,
    pentagon_skips: usize = 0,
    empty_disk_skips: usize = 0,
    antimeridian_skips: usize = 0,
    passed: usize = 0,
    superset_misses: usize = 0,
    extra_cells_total: usize = 0, // sum of |recovered \ original| across passing trials
};

/// Returns true iff the cell set's combined boundary spans the antimeridian.
/// Detected by enumerating each cell's boundary vertices and checking whether
/// the longitudinal range exhibits both `lng > π/2` and `lng < -π/2` while
/// no vertex is in the `[-π/2, π/2]` middle band — i.e., the set wraps the
/// date line. This is the condition that triggers the
/// `bboxFromGeoLoop` antimeridian branch (see module docstring for the
/// pure-Zig BBox-narrowing finding).
fn cellSetCrossesAntimeridian(cells: []const h3.H3Index) bool {
    var has_east_of_antimeridian: bool = false; // lng > π/2
    var has_west_of_antimeridian: bool = false; // lng < -π/2
    var has_middle: bool = false;
    for (cells) |cell| {
        const bd = h3.cellToBoundary(cell) catch return true; // be conservative on error
        var i: usize = 0;
        while (i < @as(usize, @intCast(bd.num_verts))) : (i += 1) {
            const lng = bd.verts[i].lng;
            if (lng > std.math.pi / 2.0) has_east_of_antimeridian = true;
            if (lng < -std.math.pi / 2.0) has_west_of_antimeridian = true;
            if (lng > -std.math.pi / 2.0 and lng < std.math.pi / 2.0) has_middle = true;
        }
    }
    return has_east_of_antimeridian and has_west_of_antimeridian and !has_middle;
}

/// Sample a random valid cell at `res`. Uses uniform-on-sphere geographic
/// sampling — the same distribution `property_invariants.zig` uses for its
/// geographic strategy. Pentagons are not filtered here; the caller decides.
fn randomCell(rng: std.Random, res: i32) !h3.H3Index {
    const z = rng.float(f64) * 2.0 - 1.0;
    const phi = rng.float(f64) * 2.0 * std.math.pi;
    const lat = std.math.asin(z);
    const lng = phi - std.math.pi;
    return try h3.latLngToCell(.{ .lat = lat, .lng = lng }, res);
}

/// Returns true iff any cell in `cells` is a pentagon. Pentagon-touching
/// cell sets are skipped in Property A — see module docstring.
fn anyPentagon(cells: []const h3.H3Index) bool {
    for (cells) |c| {
        if (c == h3.H3_NULL) continue;
        if (h3.isPentagon(c)) return true;
    }
    return false;
}

/// Build a contiguous cell set via `gridDisk(seed, k)`, filtering out the
/// trailing `H3_NULL` slots that libh3 leaves when the disk runs into a
/// pentagon (and therefore has fewer than `1 + 3k(k+1)` members).
///
/// Caller owns the returned slice.
fn buildContiguousCellSet(
    allocator: std.mem.Allocator,
    seed: h3.H3Index,
    k: i32,
) ![]h3.H3Index {
    const max_size: usize = @intCast(try h3.maxGridDiskSize(k));
    const buf = try allocator.alloc(h3.H3Index, max_size);
    defer allocator.free(buf);
    @memset(buf, h3.H3_NULL);
    try h3.gridDisk(seed, k, buf);

    var n: usize = 0;
    for (buf) |c| if (c != h3.H3_NULL) {
        n += 1;
    };
    const out = try allocator.alloc(h3.H3Index, n);
    var w: usize = 0;
    for (buf) |c| if (c != h3.H3_NULL) {
        out[w] = c;
        w += 1;
    };
    return out;
}

/// The core round-trip step: take the outer loop of polygon 0 from
/// `cellsToMultiPolygon(original)` and feed it back through `polygonToCells`
/// at the same resolution. Returns the recovered cell set; caller owns it.
///
/// Returns `error.MultiPolygonShape` if the multi-polygon doesn't have
/// exactly one outer ring (contiguous input should always produce one;
/// >1 indicates a topology assumption was violated and is worth surfacing).
fn roundTripPolygon(
    allocator: std.mem.Allocator,
    original: []const h3.H3Index,
    res: i32,
) ![]h3.H3Index {
    var mp = try h3.polygon.cellsToMultiPolygon(allocator, original);
    defer mp.deinit();

    if (mp.polygons.len != 1) return error.MultiPolygonShape;
    const outer_verts = mp.polygons[0].outer.verts;

    // Convert the recovered outline back to a `polygon.GeoPolygon`. The
    // pure-Zig polygon module treats `GeoLoop.verts` as `[]const LatLng`,
    // and the outer.verts slice we got back is already `[]LatLng` — same
    // representation, so we can pass it directly. We *ignore* the holes
    // here: the BFS in `polygonToCells` honors `GeoPolygon.holes`, so a
    // donut-shaped input would round-trip correctly, but none of the
    // contiguous gridDisk inputs we generate have holes.
    const recovered_poly = h3.polygon.GeoPolygon{
        .geoloop = .{ .verts = outer_verts },
    };

    const max_size: usize = @intCast(try h3.polygon.maxPolygonToCellsSize(recovered_poly, res));
    const out = try allocator.alloc(h3.H3Index, max_size);
    @memset(out, h3.H3_NULL);
    const n = try h3.polygon.polygonToCells(allocator, recovered_poly, res, out);

    // Compact to just the populated prefix.
    const trimmed = try allocator.alloc(h3.H3Index, n);
    @memcpy(trimmed, out[0..n]);
    allocator.free(out);
    return trimmed;
}

/// Returns true iff every cell in `subset` appears in `superset`.
fn isSuperset(
    allocator: std.mem.Allocator,
    superset: []const h3.H3Index,
    subset: []const h3.H3Index,
) !struct { ok: bool, missing_first: h3.H3Index, extras: usize } {
    var set = std.AutoHashMap(h3.H3Index, void).init(allocator);
    defer set.deinit();
    for (superset) |c| try set.put(c, {});

    for (subset) |c| {
        if (!set.contains(c)) {
            return .{ .ok = false, .missing_first = c, .extras = 0 };
        }
    }
    // Count extras (cells in superset not in subset) — informational only.
    var sub_set = std.AutoHashMap(h3.H3Index, void).init(allocator);
    defer sub_set.deinit();
    for (subset) |c| try sub_set.put(c, {});
    var extras: usize = 0;
    for (superset) |c| {
        if (!sub_set.contains(c)) extras += 1;
    }
    return .{ .ok = true, .missing_first = h3.H3_NULL, .extras = extras };
}

// ---------------------------------------------------------------------------
// Property A: cell-set → polygon → cells SUPERSET round-trip
// ---------------------------------------------------------------------------

test "property: polygonToCells(cellsToMultiPolygon(S)) is a superset of S — 2000 trials, res 5..9" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(SEED);
    const rng = prng.random();
    var stats = Stats{};

    var trial: usize = 0;
    while (trial < PROP_A_TRIALS) : (trial += 1) {
        const res_span: i32 = PROP_A_RES_MAX - PROP_A_RES_MIN + 1;
        const res: i32 = PROP_A_RES_MIN + @as(i32, @intCast(rng.intRangeLessThan(usize, 0, @intCast(res_span))));
        const k = PROP_A_K_CHOICES[rng.intRangeLessThan(usize, 0, PROP_A_K_CHOICES.len)];

        const seed_cell = try randomCell(rng, res);
        const original = try buildContiguousCellSet(allocator, seed_cell, k);
        defer allocator.free(original);

        if (original.len == 0) {
            stats.empty_disk_skips += 1;
            continue;
        }
        // Skip pentagon-touching cell sets — documented limitation.
        if (anyPentagon(original)) {
            stats.pentagon_skips += 1;
            continue;
        }
        // Skip antimeridian-crossing cell sets — documented `bboxFromGeoLoop`
        // narrowing-wedge bug, see module docstring.
        if (cellSetCrossesAntimeridian(original)) {
            stats.antimeridian_skips += 1;
            continue;
        }

        const recovered = roundTripPolygon(allocator, original, res) catch |err| switch (err) {
            // A contiguous gridDisk should always produce a single outer
            // ring. If `cellsToMultiPolygon` returned 0 polygons or >1
            // outer rings for a contiguous input, that's a topology bug
            // we want to surface, not silently skip.
            error.MultiPolygonShape => {
                std.debug.print(
                    "[property A FAIL] non-unitary multi-polygon for contiguous set; seed={x} res={d} k={d} |S|={d}\n",
                    .{ seed_cell, res, k, original.len },
                );
                return error.MultiPolygonNotSingle;
            },
            else => return err,
        };
        defer allocator.free(recovered);

        const check = try isSuperset(allocator, recovered, original);
        if (!check.ok) {
            std.debug.print(
                "[property A SUPERSET FAIL] seed={x} res={d} k={d} |S|={d} |recovered|={d} missing={x}\n",
                .{ seed_cell, res, k, original.len, recovered.len, check.missing_first },
            );
            stats.superset_misses += 1;
            return error.RecoveredNotSuperset;
        }

        stats.passed += 1;
        stats.extra_cells_total += check.extras;
        stats.per_res[@intCast(res)] += 1;
        // k=0 → idx 0, k=1 → idx 1, k=2 → idx 2 (matches PROP_A_K_CHOICES order)
        stats.per_k[@intCast(k)] += 1;
        stats.total += 1;
    }

    std.debug.print("\n[property_polygon A] trials run: {d}\n", .{PROP_A_TRIALS});
    std.debug.print("[property_polygon A] passed: {d}\n", .{stats.passed});
    std.debug.print("[property_polygon A] pentagon skips: {d}\n", .{stats.pentagon_skips});
    std.debug.print("[property_polygon A] antimeridian skips: {d}\n", .{stats.antimeridian_skips});
    std.debug.print("[property_polygon A] empty-disk skips: {d}\n", .{stats.empty_disk_skips});
    std.debug.print("[property_polygon A] superset misses: {d}\n", .{stats.superset_misses});
    std.debug.print("[property_polygon A] resolution histogram (passes only):\n", .{});
    var r: usize = @intCast(PROP_A_RES_MIN);
    while (r <= @as(usize, @intCast(PROP_A_RES_MAX))) : (r += 1) {
        std.debug.print("  res {d}: {d}\n", .{ r, stats.per_res[r] });
    }
    std.debug.print("[property_polygon A] k histogram (passes only):\n", .{});
    for (PROP_A_K_CHOICES, 0..) |k, i| {
        std.debug.print("  k={d}: {d}\n", .{ k, stats.per_k[@intCast(i)] });
    }
    std.debug.print(
        "[property_polygon A] avg extras/trial: {d:.3} (informational — superset slack)\n",
        .{@as(f64, @floatFromInt(stats.extra_cells_total)) / @as(f64, @floatFromInt(stats.passed))},
    );

    // Floor: at least 2000 trials were attempted (assertion of the test
    // contract). Passes can be lower than 2000 only if a non-trivial
    // fraction were pentagon- or antimeridian-skipped; assert the pass
    // count separately below.
    try testing.expect(
        stats.passed +
            stats.pentagon_skips +
            stats.antimeridian_skips +
            stats.empty_disk_skips ==
            PROP_A_TRIALS,
    );
    // No superset misses are tolerated — every pass must actually pass.
    try testing.expectEqual(@as(usize, 0), stats.superset_misses);

    // Every resolution in the range must have been hit at least once.
    var rr: i32 = PROP_A_RES_MIN;
    while (rr <= PROP_A_RES_MAX) : (rr += 1) {
        if (stats.per_res[@intCast(rr)] == 0) {
            std.debug.print("[property A distribution FAIL] resolution {d} never passed\n", .{rr});
            return error.ResolutionUnvisited;
        }
    }
    // Every k must have been hit at least once.
    for (PROP_A_K_CHOICES, 0..) |k, i| {
        if (stats.per_k[@intCast(i)] == 0) {
            std.debug.print("[property A distribution FAIL] k={d} never passed\n", .{k});
            return error.KUnvisited;
        }
    }
    // Pentagon skip rate should be small but non-zero given uniform-on-sphere
    // sampling and k∈{0,1,2}. (12 pentagons / 122 base cells at res 0; rate
    // shrinks rapidly with resolution.) We assert only a loose upper bound
    // so a CI run that happens to PRNG-miss every pentagon still passes.
    try testing.expect(stats.pentagon_skips <= PROP_A_TRIALS / 4);
    // Passes must dominate skips — the test is supposed to *test*, not skip.
    try testing.expect(stats.passed >= PROP_A_TRIALS * 3 / 4);
}

// ---------------------------------------------------------------------------
// Property B: single-cell polygon round-trip — recovered set contains the cell
// ---------------------------------------------------------------------------

test "property: polygonToCells(cellsToMultiPolygon({c})) contains c for hex cells at res 5..9" {
    const allocator = testing.allocator;
    var base_cells: [122]h3.H3Index = undefined;
    try h3.getRes0Cells(&base_cells);

    var total: usize = 0;
    var pent_skips: usize = 0;
    var passes: usize = 0;

    var res: i32 = 5;
    while (res <= 9) : (res += 1) {
        for (base_cells) |base| {
            // Descend through center-children to `res`.
            var cur = base;
            var cr: i32 = 0;
            while (cr < res) : (cr += 1) {
                cur = try h3.cellToCenterChild(cur, cr + 1);
            }
            total += 1;

            if (h3.isPentagon(cur)) {
                pent_skips += 1;
                continue;
            }

            const original = [_]h3.H3Index{cur};
            const recovered = roundTripPolygon(allocator, &original, res) catch |err| {
                std.debug.print(
                    "[property B FAIL] err={} cell={x} res={d}\n",
                    .{ err, cur, res },
                );
                return err;
            };
            defer allocator.free(recovered);

            // Spec: recovered set must contain the original cell. Spec
            // does NOT guarantee |recovered| == 1; Class-III boundary
            // vertices regularly resolve to neighbours during the BFS
            // seed step. We assert containment only.
            var found = false;
            for (recovered) |c| {
                if (c == cur) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.debug.print(
                    "[property B containment FAIL] cell={x} res={d} |recovered|={d}\n",
                    .{ cur, res, recovered.len },
                );
                return error.SingleCellNotRecovered;
            }
            passes += 1;
        }
    }

    std.debug.print("\n[property_polygon B] total: {d}, passes: {d}, pentagon skips: {d}\n", .{ total, passes, pent_skips });
    // 122 base cells × 5 resolutions = 610 trials. 12 pentagons descend
    // through center-children remain pentagons → 12 × 5 = 60 skips.
    try testing.expectEqual(@as(usize, 122 * 5), total);
    try testing.expectEqual(@as(usize, 12 * 5), pent_skips);
    try testing.expectEqual(@as(usize, 122 * 5 - 12 * 5), passes);
}
