const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const readosm_dep = b.dependency("readosm", .{
        .target = target,
        .optimize = optimize,
    });

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
        .root = readosm_dep.path("src"),
        .files = &.{
            "protobuf.c",
            "readosm.c",
            "osmxml.c",
            "osm_objects.c",
        },
    });

    const config_h = b.addConfigHeader(.{
        .style = .{ .autoconf_undef = readosm_dep.path("config.h.in") },
        .include_path = "config.h",
    }, .{
        .HAVE_DLFCN_H = 1,
        .HAVE_EXPAT_H = 1,
        .HAVE_INTTYPES_H = 1,
        .HAVE_LIBEXPAT = 1,
        .HAVE_LIBZ = 1,
        .HAVE_LSTAT_EMPTY_STRING_BUG = null,
        .HAVE_MEMORY_H = 1,
        .HAVE_SQRT = 1,
        .HAVE_STAT_EMPTY_STRING_BUG = null,
        .HAVE_STDINT_H = 1,
        .HAVE_STDIO_H = 1,
        .HAVE_STDLIB_H = 1,
        .HAVE_STRCASECMP = 1,
        .HAVE_STRERROR = 1,
        .HAVE_STRFTIME = 1,
        .HAVE_STRINGS_H = 1,
        .HAVE_STRING_H = 1,
        .HAVE_STRNCASECMP = 1,
        .HAVE_STRSTR = 1,
        .HAVE_SYS_STAT_H = 1,
        .HAVE_SYS_TYPES_H = 1,
        .HAVE_UNISTD_H = 1,
        .HAVE_ZLIB_H = 1,
        .LSTAT_FOLLOWS_SLASHED_SYMLINK = null,
        .LT_OBJDIR = ".libs/",
        .PACKAGE = "readosm",
        .PACKAGE_BUGREPORT = "a.furieri@lqt.it",
        .PACKAGE_NAME = "readosm",
        .PACKAGE_STRING = "readosm 1.1.0a",
        .PACKAGE_TARNAME = "readosm",
        .PACKAGE_URL = "",
        .PACKAGE_VERSION = "1.1.0a",
        .STDC_HEADERS = 1,
        .TIME_WITH_SYS_TIME = 1,
        .TM_IN_SYS_TIME = null,
        .VERSION = "1.1.0a",
        .@"const" = null,
        .off_t = null,
        .size_t = null,
        .@"volatile" = null,
    });
    lib.root_module.addConfigHeader(config_h);

    lib.root_module.addIncludePath(readosm_dep.path("headers"));
    lib.installHeadersDirectory(readosm_dep.path("headers"), "", .{
        .include_extensions = &.{".h"},
    });

    return lib;
}

pub fn addHeaders(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    translate_c: *std.Build.Step.TranslateC,
) void {
    const readosm_dep = b.dependency("readosm", .{ .target = target, .optimize = optimize });
    translate_c.addIncludePath(readosm_dep.path("headers"));
}
