const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.16.0 rejects LLD for mach-o object files
    // ("using LLD to link macho files is unsupported"). The LLD pin below
    // exists to dodge a self-hosted x86_64 Linux R_X86_64_PC64 relocation
    // bug when linking libh3 + the pure-Zig constant tables; the bug does
    // not apply on macOS, where the system ld64 path works out of the box.
    // So: pin LLD everywhere EXCEPT macOS, where we let Zig default.
    const target_os = target.result.os.tag;
    // macOS: force `use_lld = false` because Zig 0.16's LLD rejects mach-o
    //        outright ("using LLD to link macho files is unsupported"). The
    //        default-null path triggers the same rejection on executable
    //        installs, so we have to be explicit.
    // Other: pin LLD true to dodge the R_X86_64_PC64 relocation bug in the
    //        non-LLD path on Linux.
    const pin_lld: ?bool = if (target_os == .macos) false else true;
    const pin_llvm: ?bool = if (target_os == .macos) null else true;

    const h3c = b.dependency("h3c", .{});

    // Substitute CMake-style placeholders in h3api.h.in to produce h3api.h.
    const h3api_h = b.addConfigHeader(.{
        .style = .{ .cmake = h3c.path("src/h3lib/include/h3api.h.in") },
        .include_path = "h3api.h",
    }, .{
        .H3_VERSION_MAJOR = 4,
        .H3_VERSION_MINOR = 1,
        .H3_VERSION_PATCH = 0,
    });

    // Compile libh3 v4.1.0 as a static library.
    const libh3 = buildLibH3(b, h3c, h3api_h, target, optimize);

    // Zig wrapper module: idiomatic API on top of libh3.
    const mod = b.addModule("h3", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addConfigHeader(h3api_h);
    mod.addIncludePath(h3c.path("src/h3lib/include"));
    mod.linkLibrary(libh3);

    const tests = b.addTest(.{
        .root_module = mod,
        // The self-hosted linker hits R_X86_64_PC64 relocation issues with
        // the now-substantial Debug-mode test binary that links libh3 plus
        // the Phase 3 pure-Zig constant tables. Pin to LLD on Linux; let
        // macOS use the default toolchain (Zig 0.16 rejects LLD on mach-o).
        .use_llvm = pin_llvm,
        .use_lld = pin_lld,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Example: NYC neighbors walk.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/nyc_neighbors.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addConfigHeader(h3api_h);
    example_mod.addIncludePath(h3c.path("src/h3lib/include"));
    example_mod.linkLibrary(libh3);
    example_mod.addImport("h3", mod);
    const example_exe = b.addExecutable(.{
        .name = "example-nyc-neighbors",
        .root_module = example_mod,
        // LLD pinned on Linux (R_X86_64_PC64 relocation bug); macOS uses
        // the default toolchain because Zig 0.16 rejects LLD on mach-o.
        .use_llvm = pin_llvm,
        .use_lld = pin_lld,
    });
    b.installArtifact(example_exe);
    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example-nyc-neighbors", "Run the NYC k=1 neighbors example");
    example_step.dependOn(&run_example.step);

    // README Quickstart example — vendored verbatim from README.md as the
    // executable form of the documentation. Backed by `tools/doctest.sh`
    // which diff-checks the README block against this file; drift between
    // README and code fails the doc-test.
    const quickstart_mod = b.createModule(.{
        .root_source_file = b.path("examples/quickstart.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    quickstart_mod.addConfigHeader(h3api_h);
    quickstart_mod.addIncludePath(h3c.path("src/h3lib/include"));
    quickstart_mod.linkLibrary(libh3);
    quickstart_mod.addImport("h3", mod);
    const quickstart_exe = b.addExecutable(.{
        .name = "example-quickstart",
        .root_module = quickstart_mod,
        .use_llvm = pin_llvm,
        .use_lld = pin_lld,
    });
    b.installArtifact(quickstart_exe);
    const run_quickstart = b.addRunArtifact(quickstart_exe);
    const quickstart_step = b.step("example-quickstart", "Run the README Quickstart example");
    quickstart_step.dependOn(&run_quickstart.step);

    // Doc-tests: extract the README's Quickstart block + diff against the
    // vendored examples/quickstart.zig + run the binary + check output +
    // verify documented build steps exist.
    const doctest = b.addSystemCommand(&.{ "bash", "tools/doctest.sh" });
    doctest.step.dependOn(b.getInstallStep());
    const doctest_step = b.step("doctest", "Verify README code examples match the executable source + run cleanly");
    doctest_step.dependOn(&doctest.step);

    // Benchmarks — separate step (`zig build bench`) so `zig build test`
    // stays fast. Always built in ReleaseFast so numbers reflect optimised
    // codegen regardless of the user's top-level optimize flag. The bench
    // gets its own ReleaseFast libh3 + h3 module instance because mixing
    // Debug libh3 (default top-level optimize) and ReleaseFast bench code
    // leaves ld.lld with unresolved `__ubsan_handle_*` symbols.
    const bench_optimize: std.builtin.OptimizeMode = .ReleaseFast;
    const bench_libh3 = buildLibH3(b, h3c, h3api_h, target, bench_optimize);
    const bench_h3_mod = b.addModule("h3-bench", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
        .link_libc = true,
    });
    bench_h3_mod.addConfigHeader(h3api_h);
    bench_h3_mod.addIncludePath(h3c.path("src/h3lib/include"));
    bench_h3_mod.linkLibrary(bench_libh3);

    const bench_step = b.step("bench", "Run latLngToCell / gridDisk / pure-vs-libh3 throughput benchmarks");
    const bench_sources = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "bench-latlng-to-cell", .path = "bench/bench_latlng_to_cell.zig" },
        .{ .name = "bench-grid-disk", .path = "bench/bench_grid_disk.zig" },
        .{ .name = "bench-pure-vs-libh3", .path = "bench/bench_pure_vs_libh3.zig" },
    };
    for (bench_sources) |bs| {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path(bs.path),
            .target = target,
            .optimize = bench_optimize,
            .link_libc = true,
        });
        bench_mod.addConfigHeader(h3api_h);
        bench_mod.addIncludePath(h3c.path("src/h3lib/include"));
        bench_mod.linkLibrary(bench_libh3);
        bench_mod.addImport("h3", bench_h3_mod);
        const bench_exe = b.addExecutable(.{
            .name = bs.name,
            .root_module = bench_mod,
            // Same linker pin as `tests` — self-hosted hits R_X86_64_PC64
            // relocation issues with the libh3 + pure-Zig table size.
            // macOS skips the pin because Zig 0.16 rejects LLD on mach-o.
            .use_llvm = pin_llvm,
            .use_lld = pin_lld,
        });
        const run_bench = b.addRunArtifact(bench_exe);
        run_bench.has_side_effects = true; // ensure rerun on `zig build bench`
        bench_step.dependOn(&run_bench.step);
    }
}

fn buildLibH3(
    b: *std.Build,
    h3c: *std.Build.Dependency,
    h3api_h: *std.Build.Step.ConfigHeader,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const libh3_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    libh3_mod.addConfigHeader(h3api_h);
    libh3_mod.addIncludePath(h3c.path("src/h3lib/include"));
    libh3_mod.addCSourceFiles(.{
        .root = h3c.path("."),
        .files = &.{
            "src/h3lib/lib/algos.c",
            "src/h3lib/lib/baseCells.c",
            "src/h3lib/lib/bbox.c",
            "src/h3lib/lib/coordijk.c",
            "src/h3lib/lib/directedEdge.c",
            "src/h3lib/lib/faceijk.c",
            "src/h3lib/lib/h3Assert.c",
            "src/h3lib/lib/h3Index.c",
            "src/h3lib/lib/iterators.c",
            "src/h3lib/lib/latLng.c",
            "src/h3lib/lib/linkedGeo.c",
            "src/h3lib/lib/localij.c",
            "src/h3lib/lib/mathExtensions.c",
            "src/h3lib/lib/polygon.c",
            "src/h3lib/lib/vec2d.c",
            "src/h3lib/lib/vec3d.c",
            "src/h3lib/lib/vertex.c",
            "src/h3lib/lib/vertexGraph.c",
        },
        .flags = &.{
            "-std=c99",
            "-Wno-deprecated-declarations",
        },
    });
    return b.addLibrary(.{
        .name = "h3",
        .linkage = .static,
        .root_module = libh3_mod,
    });
}
