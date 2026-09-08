const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const zlib_dep = b.dependency("zlib", .{});

    const lib = b.addLibrary(.{
        .name = "z",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addCSourceFiles(.{
        .root = zlib_dep.path(""),
        .files = &.{
            "adler32.c",
            "compress.c",
            "crc32.c",
            "deflate.c",
            "infback.c",
            "inftrees.c",
            "inffast.c",
            "inflate.c",
            "trees.c",
            "uncompr.c",
            "zutil.c",
        },
    });

    lib.installHeadersDirectory(zlib_dep.path(""), "", .{
        .include_extensions = &.{".h"},
    });

    return lib;
}
