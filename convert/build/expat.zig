const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const expat_dep = b.dependency("expat", .{ .target = target, .optimize = optimize });

    const lib = b.addLibrary(.{
        .name = "expat",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const write_files = b.addWriteFiles();
    _ = write_files.add("expat_config.h", generateConfig(b, target));

    lib.root_module.addCSourceFiles(.{
        .root = expat_dep.path("lib"),
        .files = &.{
            "xmlparse.c",
            "xmlrole.c",
            "xmltok.c",
        },
        .flags = &.{
            "-DXML_STATIC",
            "-DXML_BUILDING_EXPAT",
        },
    });

    lib.root_module.addIncludePath(write_files.getDirectory());
    lib.root_module.addIncludePath(expat_dep.path("lib"));

    lib.installHeadersDirectory(expat_dep.path("lib"), "", .{
        .include_extensions = &.{".h"},
    });

    return lib;
}

fn generateConfig(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const is_windows = target.result.os.tag == .windows;
    const is_big_endian = target.result.cpu.arch.endian() == .big;

    return std.fmt.allocPrint(b.allocator,
        \\#ifndef EXPAT_CONFIG_H
        \\#define EXPAT_CONFIG_H 1
        \\
        \\/* 1234 = LILENDIAN, 4321 = BIGENDIAN */
        \\#define BYTEORDER {[byteorder]d}
        \\
        \\#define HAVE_FCNTL_H 1
        \\#define HAVE_INTTYPES_H 1
        \\#define HAVE_MEMORY_H 1
        \\#define HAVE_STDINT_H 1
        \\#define HAVE_STDLIB_H 1
        \\#define HAVE_STRINGS_H 1
        \\#define HAVE_STRING_H 1
        \\#define HAVE_SYS_STAT_H 1
        \\#define HAVE_SYS_TYPES_H 1
        \\{[unistd]s}
        \\{[urandom]s}
        \\
        \\#define PACKAGE "expat"
        \\#define PACKAGE_BUGREPORT "expat-bugs@libexpat.org"
        \\#define PACKAGE_NAME "Expat"
        \\#define PACKAGE_STRING "Expat 2.6.4"
        \\#define PACKAGE_TARNAME "expat"
        \\#define PACKAGE_URL ""
        \\#define PACKAGE_VERSION "2.6.4"
        \\
        \\#define STDC_HEADERS 1
        \\
        \\/* Define to specify how much context to retain around the
        \\   current parse point, 0 to disable. */
        \\#define XML_CONTEXT_BYTES 1024
        \\/* Define to make parameter entity parsing functionality available. */
        \\#define XML_DTD 1
        \\/* Define as 1/0 to enable/disable support for general entities. */
        \\#define XML_GE 1
        \\/* Define to make XML Namespaces functionality available. */
        \\#define XML_NS 1
        \\
        \\#endif
    , .{
        .byteorder = if (is_big_endian) @as(u16, 4321) else @as(u16, 1234),
        .unistd = if (!is_windows) "#define HAVE_UNISTD_H 1" else "",
        .urandom = if (!is_windows) "#define XML_DEV_URANDOM 1" else "",
    }) catch @panic("OOM");
}
