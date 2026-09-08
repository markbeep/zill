const std = @import("std");
const build_tiff = @import("tiff.zig");
const build_proj = @import("proj.zig");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const geotiff_dep = b.dependency("libgeotiff", .{ .target = target, .optimize = optimize });
    const proj_dep = b.dependency("proj", .{ .target = target, .optimize = optimize });
    const tiff_dep = b.dependency("libtiff", .{ .target = target, .optimize = optimize });

    const lib = b.addLibrary(.{
        .name = "geotiff",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const lib_tiff = build_tiff.create(b, target, optimize);
    lib.root_module.linkLibrary(lib_tiff);
    lib.root_module.addIncludePath(tiff_dep.path("libtiff"));

    const proj = build_proj.create(b, target, optimize);
    lib.root_module.linkLibrary(proj);
    lib.root_module.addIncludePath(proj_dep.path("include"));

    const gtiff_h = b.addConfigHeader(.{
        .style = .{ .cmake = geotiff_dep.path("geotiff.h.in") },
        .include_path = "geotiff.h",
    }, .{
        .LIBGEOTIFF_MAJOR_VERSION = 1,
        .LIBGEOTIFF_MINOR_VERSION = 7,
        .LIBGEOTIFF_PATCH_VERSION = 4,
        .LIBGEOTIFF_REV_VERSION = 0,
        .LIBGEOTIFF_VERSION = 1740,
        .LIBGEOTIFF_STRING_VERSION = "1.7.4",
    });

    const geo_config_h = b.addConfigHeader(.{
        .style = .{ .cmake = geotiff_dep.path("cmake/geo_config.h.in") },
        .include_path = "geo_config.h",
    }, .{
        .GEOTIFF_HAVE_STRINGS_H = 1,
        .GEO_NORMALIZE_DISABLE_TOWGS84 = null,
        .HAVE_PROJECTS_H = 0,
        .HAVE_PROJ_H = 1,
        .HAVE_LIBPROJ = 1,
    });

    const geotiff_c_flags = &[_][]const u8{
        "-DHAVE_TIFF=1",
        "-DGEOTIFF_INDEX=1",
        "-DHAVE_LIBPROJ=1",
        "-DHAVE_PROJ_H=1",
    };

    lib.root_module.addCSourceFiles(.{
        .root = geotiff_dep.path(""),
        .files = &.{
            "cpl_serv.c",
            "geo_extra.c",
            "geo_free.c",
            "geo_get.c",
            "geo_names.c",
            "geo_new.c",
            "geo_normalize.c",
            "geo_print.c",
            "geo_set.c",
            "geo_simpletags.c",
            "geo_strtod.c",
            "geo_tiffp.c",
            "geo_trans.c",
            "geo_write.c",
            "geotiff_proj4.c",
            "libxtiff/xtiff.c",
        },
        .flags = geotiff_c_flags,
    });

    lib.root_module.addConfigHeader(gtiff_h);
    lib.root_module.addConfigHeader(geo_config_h);
    lib.root_module.addIncludePath(geotiff_dep.path(""));

    lib.installHeadersDirectory(geotiff_dep.path(""), "", .{
        .include_extensions = &.{ ".h", ".inc" },
    });

    return lib;
}
