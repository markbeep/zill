const std = @import("std");
const Build = @import("std").Build;
const Compile = @import("std").Build.Step.Compile;

fn generateTifConfig(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const is_64_bit = target.result.ptrBitWidth() == 64;
    const is_big_endian = target.result.cpu.arch.endian() == .big;
    const is_windows = target.result.os.tag == .windows;

    return std.fmt.allocPrint(b.allocator,
        \\#ifndef _TIF_CONFIG_
        \\#define _TIF_CONFIG_
        \\
        \\#include "tiffconf.h"
        \\
        \\#define CCITT_SUPPORT 1
        \\#define CHECK_JPEG_YCBCR_SUBSAMPLING 1
        \\#define CHUNKY_STRIP_READ_SUPPORT 1
        \\#define DEFER_STRILE_LOAD 1
        \\
        \\#define HAVE_ASSERT_H 1
        \\#define HAVE_FCNTL_H 1
        \\#define HAVE_STDINT_H 1
        \\#define HAVE_STDLIB_H 1
        \\#define HAVE_STRING_H 1
        \\#define HAVE_STRINGS_H 1
        \\#define HAVE_SYS_TYPES_H 1
        \\
        \\{[unistd]s}
        \\{[fseeko]s}
        \\{[mmap]s}
        \\{[getopt]s}
        \\{[win32]s}
        \\
        \\#define PACKAGE "tiff"
        \\#define PACKAGE_NAME "LibTIFF Software Distribution"
        \\#define PACKAGE_TARNAME "tiff"
        \\#define PACKAGE_VERSION "4.6.0"
        \\#define PACKAGE_URL ""
        \\#define PACKAGE_BUGREPORT "tiff@lists.osgeo.org"
        \\
        \\#define SIZEOF_SIZE_T {[size_t_bytes]d}
        \\#define STRIP_SIZE_DEFAULT 8192
        \\#define TIFF_MAX_DIR_COUNT 1048576
        \\
        \\#define WORDS_BIGENDIAN {[big_endian]d}
        \\
        \\#if !defined(__MINGW32__)
        \\#  define TIFF_SIZE_FORMAT "zu"
        \\#endif
        \\#if SIZEOF_SIZE_T == 8
        \\#  define TIFF_SSIZE_FORMAT PRId64
        \\#  if defined(__MINGW32__)
        \\#    define TIFF_SIZE_FORMAT PRIu64
        \\#  endif
        \\#elif SIZEOF_SIZE_T == 4
        \\#  define TIFF_SSIZE_FORMAT PRId32
        \\#  if defined(__MINGW32__)
        \\#    define TIFF_SIZE_FORMAT PRIu32
        \\#  endif
        \\#else
        \\#  error "Unsupported size_t size"
        \\#endif
        \\
        \\#endif
    , .{
        .size_t_bytes = if (is_64_bit) @as(usize, 8) else @as(usize, 4),
        .big_endian = if (is_big_endian) @as(u8, 1) else @as(u8, 0),
        .unistd = if (!is_windows) "#define HAVE_UNISTD_H 1" else "/* #undef HAVE_UNISTD_H */",
        .fseeko = if (!is_windows) "#define HAVE_FSEEKO 1" else "/* #undef HAVE_FSEEKO */",
        .mmap = if (!is_windows) "#define HAVE_MMAP 1" else "/* #undef HAVE_MMAP */",
        .getopt = if (!is_windows) "#define HAVE_GETOPT 1" else "/* #undef HAVE_GETOPT */",
        .win32 = if (is_windows) "#define USE_WIN32_FILEIO 1" else "/* #undef USE_WIN32_FILEIO */",
    }) catch @panic("OOM");
}

fn buildTiff(
    b: *std.Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tiff_dep: *Build.Dependency,
) *Compile {
    const lib = b.addLibrary(.{
        .name = "tiff",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addCSourceFiles(.{
        .root = tiff_dep.path("libtiff"),
        .files = &.{
            "tif_aux.c",
            "tif_close.c",
            "tif_codec.c",
            "tif_color.c",
            "tif_compress.c",
            "tif_dir.c",
            "tif_dirinfo.c",
            "tif_dirread.c",
            "tif_dirwrite.c",
            "tif_dumpmode.c",
            "tif_error.c",
            "tif_extension.c",
            "tif_fax3.c",
            "tif_fax3sm.c",
            "tif_flush.c",
            "tif_getimage.c",
            "tif_hash_set.c",
            "tif_jbig.c",
            "tif_jpeg.c",
            "tif_jpeg_12.c",
            "tif_lerc.c",
            "tif_luv.c",
            "tif_lzma.c",
            "tif_lzw.c",
            "tif_next.c",
            "tif_ojpeg.c",
            "tif_open.c",
            "tif_packbits.c",
            "tif_pixarlog.c",
            "tif_predict.c",
            "tif_print.c",
            "tif_read.c",
            "tif_strip.c",
            "tif_swab.c",
            "tif_thunder.c",
            "tif_tile.c",
            "tif_unix.c",
            "tif_version.c",
            "tif_warning.c",
            "tif_webp.c",
            // "tif_win32.c",
            "tif_write.c",
            "tif_zip.c",
            "tif_zstd.c",
        },
        .flags = &.{"-DTIFF_DISABLE_DEPRECATED"},
    });

    lib.root_module.addIncludePath(tiff_dep.path("libtiff"));

    // generate tif_config.h file
    const generated_files = b.addWriteFiles();
    const tif_config_content = generateTifConfig(b, target);
    _ = generated_files.add("tif_config.h", tif_config_content);
    lib.root_module.addIncludePath(generated_files.getDirectory());

    return lib;
}

fn buildGeoTiff(
    b: *std.Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    tiff_dep: *Build.Dependency,
    geotiff_dep: *Build.Dependency,
) *Compile {
    const lib = b.addLibrary(.{
        .name = "geotiff",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(tiff_dep.path("libtiff"));

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
        .HAVE_PROJ_H = 0,
        .HAVE_LIBPROJ = 0,
    });

    const geotiff_c_flags = &[_][]const u8{
        "-DHAVE_TIFF=1",
        "-DGEOTIFF_INDEX=1",
        "-DHAVE_LIBPROJ=0",
        "-DNO_PROJ=1",
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
    lib.root_module.addIncludePath(tiff_dep.path("libtiff"));
    lib.root_module.addIncludePath(geotiff_dep.path(""));
    lib.root_module.addIncludePath(geotiff_dep.path("libxtiff"));

    return lib;
}

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

    const tiff_dep = b.dependency("libtiff", .{});
    const geotiff_dep = b.dependency("libgeotiff", .{});

    exe.root_module.linkLibrary(buildTiff(b, target, optimize, tiff_dep));
    exe.root_module.linkLibrary(buildGeoTiff(b, target, optimize, tiff_dep, geotiff_dep));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
