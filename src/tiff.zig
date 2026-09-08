const std = @import("std");
const c = @import("c.zig").c;

pub const GeoTiff = @This();

pub const ReadElevationFn = *const fn (
    self: GeoTiff,
    allocator: std.mem.Allocator,
    target_x: f64,
    target_y: f64,
) anyerror!?f32;

pub const LayoutData = union {
    tiled: struct {
        tile_width: u32,
        tile_height: u32,
    },
    striped: struct {},
};

tif: *c.TIFF,
gtif: *c.GTIF,

width: u32,
height: u32,
bits_per_sample: u16,
sample_format: u16,

pixel_scale_x: f64,
pixel_scale_y: f64,
origin_x: f64,
origin_y: f64,

layout: LayoutData,
read_elevation_fn: ReadElevationFn,

pub fn open(path: []const u8) !GeoTiff {
    const tif = c.XTIFFOpen(path.ptr, "r") orelse return error.FileOpenError;
    errdefer c.XTIFFClose(tif);
    const gtif = c.GTIFNew(tif) orelse return error.GeoTiffNewError;
    errdefer c.GTIFFree(gtif);

    var width: u32 = undefined;
    var height: u32 = undefined;
    var bits_per_sample: u16 = undefined;
    var sample_format: u16 = undefined;
    if (c.TIFFGetField(tif, c.TIFFTAG_IMAGEWIDTH, &width) != 1)
        return error.TIFFGetWidthError;
    if (c.TIFFGetField(tif, c.TIFFTAG_IMAGELENGTH, &height) != 1)
        return error.TIFFGetHeightError;
    if (c.TIFFGetField(tif, c.TIFFTAG_BITSPERSAMPLE, &bits_per_sample) != 1)
        return error.TIFFGetBitsPerSampleError;
    if (c.TIFFGetField(tif, c.TIFFTAG_SAMPLEFORMAT, &sample_format) != 1)
        return error.TIFFGetSampleFormatError;

    var scale_count: c_int = 0;
    var scale_ptr: [*c]f64 = null;
    var pixel_scale_x: f64 = undefined;
    var pixel_scale_y: f64 = undefined;
    if (c.TIFFGetField(tif, c.TIFFTAG_GEOPIXELSCALE, &scale_count, &scale_ptr) != 1 or scale_count < 2)
        return error.TIFFGetGeoPixelScaleError;
    pixel_scale_x = scale_ptr[0];
    pixel_scale_y = scale_ptr[1];

    var tie_count: c_int = 0;
    var tie_ptr: [*c]f64 = undefined;
    var origin_x: f64 = undefined;
    var origin_y: f64 = undefined;
    if (c.TIFFGetField(tif, c.TIFFTAG_GEOTIEPOINTS, &tie_count, &tie_ptr) != 1 or tie_count < 2)
        return error.TIFFGetGeoTiePointsError;
    origin_x = tie_ptr[3] - (tie_ptr[0] * pixel_scale_x);
    origin_y = tie_ptr[4] - (tie_ptr[1] * pixel_scale_y);

    var layout: LayoutData = undefined;
    var read_fn: ReadElevationFn = undefined;

    if (c.TIFFIsTiled(tif) == 0) {
        layout = .{ .striped = .{} };
    } else {
        var tile_w: u32 = 0;
        var tile_h: u32 = 0;
        if (c.TIFFGetField(tif, c.TIFFTAG_TILEWIDTH, &tile_w) != 1)
            return error.TIFFGetWidthError;
        if (c.TIFFGetField(tif, c.TIFFTAG_TILELENGTH, &tile_h) != 1)
            return error.TIFFGetHeightError;

        layout = .{ .tiled = .{ .tile_width = tile_w, .tile_height = tile_h } };
        read_fn = readTiledElevation;
    }

    return GeoTiff{
        .tif = tif,
        .gtif = gtif,
        .width = width,
        .height = height,
        .bits_per_sample = bits_per_sample,
        .sample_format = sample_format,
        .pixel_scale_x = pixel_scale_x,
        .pixel_scale_y = pixel_scale_y,
        .origin_x = origin_x,
        .origin_y = origin_y,
        .layout = layout,
        .read_elevation_fn = read_fn,
    };
}

pub fn close(self: GeoTiff) void {
    c.GTIFFree(self.gtif);
    c.XTIFFClose(self.tif);
}

pub inline fn readElevation(
    self: GeoTiff,
    allocator: std.mem.Allocator,
    target_x: f64,
    target_y: f64,
) !?f32 {
    return self.read_elevation_fn(self, allocator, target_x, target_y);
}

// pub fn run(self: GeoTiff, allocator: std.mem.Allocator) !void {
//     var defn: c.GTIFDefn = undefined;
//     if (c.GTIFGetDefn(self.gtif, &defn) != 1)
//         return error.GTIFGetDefnError;

//     std.debug.print("Model Type: {d} (1=Projected, 2=Geographic/LatLon)\n", .{defn.Model});
//     std.debug.print("PCS Code (EPSG): {d}\n", .{defn.PCS});
// }

pub const TiledLayout = struct {
    tile_width: u32,
    tile_height: u32,
};

fn readTiledElevation(
    self: GeoTiff,
    allocator: std.mem.Allocator,
    target_x: f64,
    target_y: f64,
) !?f32 {
    const col_f = (target_x - self.origin_x) / self.pixel_scale_x;
    const row_f = (target_y - self.origin_y) / self.pixel_scale_y;

    if (col_f < 0 or row_f < 0) return null;

    const col: u32 = @intFromFloat(col_f);
    const row: u32 = @intFromFloat(row_f);

    if (col >= self.width or row >= self.height) return null;

    const tile_buf = try allocator.alloc(u8, @as(usize, @intCast(c.TIFFTileSize(self.tif))));
    defer allocator.free(tile_buf);

    if (c.TIFFReadTile(self.tif, tile_buf.ptr, col, row, 0, 0) < 0) {
        return error.TIFFReadTileError;
    }

    const samples = std.mem.bytesAsSlice(f32, tile_buf);
    const tile = self.layout.tiled;
    const local_col = col % tile.tile_width;
    const local_row = row % tile.tile_height;
    const local_index = local_row * tile.tile_width + local_col;
    return samples[local_index];
}

fn readStripedElevation(
    self: *GeoTiff,
    allocator: std.mem.Allocator,
    target_x: f64,
    target_y: f64,
) !?f32 {
    _ = self;
    _ = allocator;
    _ = target_x;
    _ = target_y;
    @panic("readStripedElevation is not implemented yet");
}
