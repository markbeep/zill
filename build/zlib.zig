const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const zlib_dep = b.dependency("zlib", .{ .target = target, .optimize = optimize });

    const lib = b.addLibrary(.{
        .name = "z",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const flags = &.{
        "-std=c99",
        "-DHAVE_UNISTD_H",
        "-DZ_HAVE_UNISTD_H",
        "-D_POSIX_C_SOURCE=200809L",
    };

    lib.root_module.addCSourceFiles(.{
        .root = zlib_dep.path(""),
        .files = &.{
            "adler32.c",
            "compress.c",
            "crc32.c",
            "deflate.c",
            "gzclose.c",
            "gzlib.c",
            "gzread.c",
            "gzwrite.c",
            "infback.c",
            "inffast.c",
            "inflate.c",
            "inftrees.c",
            "trees.c",
            "uncompr.c",
            "zutil.c",
        },
        .flags = flags,
    });

    lib.installHeadersDirectory(zlib_dep.path(""), "", .{
        .include_extensions = &.{".h"},
    });

    return lib;
}
