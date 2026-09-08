const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const sqlite_dep = b.dependency("sqlite", .{});

    const lib = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addCSourceFiles(.{
        .root = sqlite_dep.path(""),
        .files = &.{"sqlite3.c"},
        .flags = &.{
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_ENABLE_COLUMN_METADATA=1",
        },
    });

    lib.installHeadersDirectory(sqlite_dep.path(""), "", .{
        .include_extensions = &.{".h"},
    });

    return lib;
}
