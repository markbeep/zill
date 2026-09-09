const std = @import("std");
const build_geotiff = @import("build/geotiff.zig");
const build_sqlite3 = @import("build/sqlite3.zig");
const build_zlib = @import("build/zlib.zig");
const build_readosm = @import("build/readosm.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============= zill =============

    const zill_mod = b.createModule(.{
        .root_source_file = b.path("src/graph.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ============= zillconv =============

    const translate_tiff = b.addTranslateC(.{
        .root_source_file = b.path("src/tiff.h"),
        .target = target,
        .optimize = optimize,
    });
    build_geotiff.addHeaders(b, target, optimize, translate_tiff);

    const translate_osm = b.addTranslateC(.{
        .root_source_file = b.path("src/osm.h"),
        .target = target,
        .optimize = optimize,
    });
    build_readosm.addHeaders(b, target, optimize, translate_osm);

    const tiff_c_mod = translate_tiff.createModule();
    const readosm_c_mod = translate_osm.createModule();

    const zillconv_mod = b.createModule(.{
        .root_source_file = b.path("src/zillconv.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tiff", .module = tiff_c_mod },
            .{ .name = "readosm", .module = readosm_c_mod },
            .{ .name = "zill", .module = zill_mod },
        },
    });

    const lib_geotiff = build_geotiff.create(b, target, optimize);
    const lib_sqlite = build_sqlite3.create(b, target, optimize);
    const lib_zlib = build_zlib.create(b, target, optimize);
    const lib_readosm = build_readosm.create(b, target, optimize);

    // ============= zillconv executable =============

    const zillconv_exe = b.addExecutable(.{
        .name = "zillconv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/conv.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zillconv", .module = zillconv_mod },
            },
        }),
    });
    // llvm/ldd is a workaround for "too new glibc" causing "error: fatal linker error: unhandled relocation type R_X86_64_PC64 at offset 0x1c"
    // https://codeberg.org/ziglang/zig/issues/31272
    zillconv_exe.use_llvm = true;
    zillconv_exe.root_module.linkLibrary(lib_geotiff);
    zillconv_exe.root_module.linkLibrary(lib_sqlite);
    zillconv_exe.root_module.linkLibrary(lib_zlib);
    zillconv_exe.root_module.linkLibrary(lib_readosm);
    zillconv_exe.root_module.linkSystemLibrary("expat", .{});
    b.installArtifact(zillconv_exe);

    // ============= zill executable =============

    const zill_exe = b.addExecutable(.{
        .name = "zill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zill", .module = zill_mod },
            },
        }),
    });
    b.installArtifact(zill_exe);

    // Run steps
    const zillconv_step = b.step("zillconv", "Build OSM/TIFF parser and generate data/graph.zl");
    const zillconv_cmd = b.addRunArtifact(zillconv_exe);
    zillconv_step.dependOn(&zillconv_cmd.step);

    const zill_step = b.step("zill", "Read data/graph.zl and compute");
    const zill_cmd = b.addRunArtifact(zill_exe);
    zill_step.dependOn(&zill_cmd.step);

    const run_step = b.step("run", "Alias for `zill` (read data/graph.zl)");
    run_step.dependOn(&zill_cmd.step);

    if (b.args) |args| {
        zillconv_cmd.addArgs(args);
        zill_cmd.addArgs(args);
    }

    // Tests
    const zill_tests = b.addTest(.{ .root_module = zill_mod });
    const run_zill_tests = b.addRunArtifact(zill_tests);

    const zillconv_tests = b.addTest(.{
        .root_module = zillconv_mod,
        .use_llvm = true,
    });
    zillconv_tests.root_module.linkLibrary(lib_geotiff);
    zillconv_tests.root_module.linkLibrary(lib_sqlite);
    zillconv_tests.root_module.linkLibrary(lib_zlib);
    zillconv_tests.root_module.linkLibrary(lib_readosm);
    zillconv_tests.root_module.linkSystemLibrary("expat", .{});
    const run_zillconv_tests = b.addRunArtifact(zillconv_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_zill_tests.step);
    test_step.dependOn(&run_zillconv_tests.step);
}
