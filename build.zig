const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const libh3 = b.addLibrary(.{
        .name = "h3",
        .linkage = .static,
        .root_module = libh3_mod,
    });

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
        // the Phase 3 pure-Zig constant tables. Pin to LLD until upstream
        // self-hosted catches up.
        .use_llvm = true,
        .use_lld = true,
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
        .use_llvm = true,
        .use_lld = true,
    });
    b.installArtifact(example_exe);
    const run_example = b.addRunArtifact(example_exe);
    const example_step = b.step("example-nyc-neighbors", "Run the NYC k=1 neighbors example");
    example_step.dependOn(&run_example.step);
}
