const std = @import("std");
const build_geotiff = @import("build/geotiff.zig");
const build_sqlite3 = @import("build/sqlite3.zig");
const build_zlib = @import("build/zlib.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "fm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // llvm/ldd is a workaround for "too new glibc" causing "error: fatal linker error: unhandled relocation type R_X86_64_PC64 at offset 0x1c"
    // https://codeberg.org/ziglang/zig/issues/31272
    exe.use_llvm = true;

    const lib_geotiff = build_geotiff.create(b, target, optimize);
    exe.root_module.linkLibrary(lib_geotiff);

    // proj.h lives in the proj source tree; expose it so src/c.zig can use the
    // PROJ C API directly for CRS reprojection.
    const proj_dep = b.dependency("proj", .{});
    exe.root_module.addIncludePath(proj_dep.path("src"));

    const lib_sqlite = build_sqlite3.create(b, target, optimize);
    exe.root_module.linkLibrary(lib_sqlite);

    const lib_zlib = build_zlib.create(b, target, optimize);
    exe.root_module.linkLibrary(lib_zlib);

    // // proj (dep of geotiff) requires sqlite3
    // exe.root_module.linkSystemLibrary("sqlite3", .{});
    // exe.root_module.linkSystemLibrary("z", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
