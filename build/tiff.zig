const std = @import("std");

pub fn create(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const tiff_dep = b.dependency("libtiff", .{});

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
            "tif_luv.c",
            "tif_lzw.c",
            "tif_next.c",
            "tif_open.c",
            "tif_packbits.c",
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
            "tif_write.c",
            "tif_zip.c",
        },
        .flags = &.{"-DTIFF_DISABLE_DEPRECATED"},
    });

    const write_files = b.addWriteFiles();
    const tiffconf_content = generateTiffConf(b, target);
    const tif_config_content = generateTifConfig(b, target);

    lib.installHeader(write_files.add("tiffconf.h", tiffconf_content), "tiffconf.h");
    lib.installHeader(write_files.add("tif_config.h", tif_config_content), "tif_config.h");

    lib.root_module.addIncludePath(write_files.getDirectory());
    lib.root_module.addIncludePath(tiff_dep.path("libtiff"));

    return lib;
}

fn generateTiffConf(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const is_64_bit = target.result.ptrBitWidth() == 64;
    const is_big_endian = target.result.cpu.arch.endian() == .big;

    return std.fmt.allocPrint(b.allocator,
        \\#ifndef _TIFFCONF_
        \\#define _TIFFCONF_
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include <inttypes.h>
        \\
        \\#define TIFF_INT8_T int8_t
        \\#define TIFF_UINT8_T uint8_t
        \\#define TIFF_INT16_T int16_t
        \\#define TIFF_UINT16_T uint16_t
        \\#define TIFF_INT32_T int32_t
        \\#define TIFF_UINT32_T uint32_t
        \\#define TIFF_INT64_T int64_t
        \\#define TIFF_UINT64_T uint64_t
        \\
        \\{[ssize_t]s}
        \\
        \\#define HAVE_IEEEFP 1
        \\#define HOST_FILLORDER FILLORDER_LSB2MSB
        \\#define HOST_BIGENDIAN {[big_endian]d}
        \\
        \\#define CCITT_SUPPORT 1
        \\#define LOGLUV_SUPPORT 1
        \\#define LZW_SUPPORT 1
        \\#define NEXT_SUPPORT 1
        \\#define PACKBITS_SUPPORT 1
        \\#define THUNDER_SUPPORT 1
        \\
        \\#undef JPEG_SUPPORT
        \\#undef OJPEG_SUPPORT
        \\#undef JBIG_SUPPORT
        \\#undef LERC_SUPPORT
        \\#undef PIXARLOG_SUPPORT
        \\#define ZIP_SUPPORT
        \\#undef LIBDEFLATE_SUPPORT
        \\
        \\#define STRIPCHOP_DEFAULT 1
        \\#define SUBIFD_SUPPORT 1
        \\#define DEFAULT_EXTRASAMPLE_AS_ALPHA 1
        \\#define CHECK_JPEG_YCBCR_SUBSAMPLING 0
        \\#define MDI_SUPPORT 1
        \\
        \\#define COLORIMETRY_SUPPORT
        \\#define YCBCR_SUPPORT
        \\#define CMYK_SUPPORT
        \\#define ICC_SUPPORT
        \\#define PHOTOSHOP_SUPPORT
        \\#define IPTC_SUPPORT
        \\
        \\#endif
    , .{
        .ssize_t = if (is_64_bit) "#define TIFF_SSIZE_T int64_t" else "#define TIFF_SSIZE_T int32_t",
        .big_endian = if (is_big_endian) @as(u8, 1) else @as(u8, 0),
    }) catch @panic("OOM");
}

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
        \\#define CHECK_JPEG_YCBCR_SUBSAMPLING 0
        \\#define CHUNKY_STRIP_READ_SUPPORT 1
        \\#define DEFER_STRILE_LOAD 1
        \\
        \\#define HAVE_ASSERT_H 1
        \\#define HAVE_FCNTL_H 1
        \\#define HAVE_SNPRINTF 1
        \\#define HAVE_STRINGS_H 1
        \\#define HAVE_SYS_TYPES_H 1
        \\
        \\{[decl_optarg]s}
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
        .decl_optarg = if (!is_windows) "#define HAVE_DECL_OPTARG 1" else "#define HAVE_DECL_OPTARG 0",
        .unistd = if (!is_windows) "#define HAVE_UNISTD_H 1" else "",
        .fseeko = if (!is_windows) "#define HAVE_FSEEKO 1" else "",
        .mmap = if (!is_windows) "#define HAVE_MMAP 1" else "",
        .getopt = if (!is_windows) "#define HAVE_GETOPT 1" else "",
        .win32 = if (is_windows) "#define USE_WIN32_FILEIO 1" else "",
    }) catch @panic("OOM");
}
