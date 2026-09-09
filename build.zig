const std = @import("std");
const build_geotiff = @import("build/geotiff.zig");
const build_sqlite3 = @import("build/sqlite3.zig");
const build_zlib = @import("build/zlib.zig");
const build_readosm = @import("build/readosm.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const exe = b.addExecutable(.{
        .name = "zill",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "tiff",
                    .module = translate_tiff.createModule(),
                },
                .{
                    .name = "readosm",
                    .module = translate_osm.createModule(),
                },
            },
        }),
    });

    // llvm/ldd is a workaround for "too new glibc" causing "error: fatal linker error: unhandled relocation type R_X86_64_PC64 at offset 0x1c"
    // https://codeberg.org/ziglang/zig/issues/31272
    exe.use_llvm = true;

    const lib_geotiff = build_geotiff.create(b, target, optimize);
    exe.root_module.linkLibrary(lib_geotiff);

    const lib_sqlite = build_sqlite3.create(b, target, optimize);
    exe.root_module.linkLibrary(lib_sqlite);

    const lib_zlib = build_zlib.create(b, target, optimize);
    exe.root_module.linkLibrary(lib_zlib);

    const lib_readosm = build_readosm.create(b, target, optimize);
    exe.root_module.linkLibrary(lib_readosm);
    exe.root_module.linkSystemLibrary("expat", .{});

    b.installArtifact(exe);

    // run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // test step
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .use_llvm = true,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
