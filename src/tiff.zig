const std = @import("std");
const c = @import("c.zig").c;

pub const GeoTiff = @This();

pub const ReadElevationFn = *const fn (
    self: *GeoTiff,
    allocator: std.mem.Allocator,
    target_x: f64,
    target_y: f64,
) anyerror!?f32;

pub const LayoutData = union(enum) {
    tiled: struct {
        tile_width: u32,
        tile_height: u32,
        tile_buf: []u8,
        cached_tile_x: ?u32 = null,
        cached_tile_y: ?u32 = null,
    },
    striped: struct {},
};

allocator: std.mem.Allocator,
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

defn: c.GTIFDefn,

layout: LayoutData,
read_elevation_fn: ReadElevationFn,

pub fn open(allocator: std.mem.Allocator, path: []const u8) !GeoTiff {
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

    // Determine the raster's CRS from the GeoTIFF keys so we can reproject
    // WGS84 (EPSG:4326) input coordinates into it before sampling.
    var defn: c.GTIFDefn = undefined;
    if (c.GTIFGetDefn(gtif, &defn) != 1)
        return error.GTIFGetDefnError;

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

        layout = .{ .tiled = .{
            .tile_width = tile_w,
            .tile_height = tile_h,
            .tile_buf = try allocator.alloc(u8, @as(usize, @intCast(c.TIFFTileSize(tif)))),
        } };
        read_fn = readTiledElevation;
    }

    return GeoTiff{
        .allocator = allocator,
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
        .defn = defn,
        .layout = layout,
        .read_elevation_fn = read_fn,
    };
}

pub fn close(self: GeoTiff) void {
    c.GTIFFree(self.gtif);
    c.XTIFFClose(self.tif);

    switch (self.layout) {
        .tiled => |tiled| {
            self.allocator.free(tiled.tile_buf);
        },
        .striped => {},
    }
}

/// Reads the elevation value at the specified coordinates (target_x, target_y) GeoTIFF file.
/// Target coordinates need to be in the same coordinate system as the GeoTIFF file. Use the `transformCoordinates` function to convert from WGS84 (EPSG:4326) if necessary.
pub inline fn readElevation(self: *GeoTiff, allocator: std.mem.Allocator, target_x: f64, target_y: f64) !?f32 {
    return self.read_elevation_fn(self, allocator, target_x, target_y);
}

pub const TiledLayout = struct {
    tile_width: u32,
    tile_height: u32,
};

fn readTiledElevation(self: *GeoTiff, allocator: std.mem.Allocator, target_x: f64, target_y: f64) !?f32 {
    _ = allocator;

    const col_f = (target_x - self.origin_x) / self.pixel_scale_x;
    const row_f = (self.origin_y - target_y) / self.pixel_scale_y;

    if (col_f < 0 or row_f < 0) return null;

    const col: u32 = @intFromFloat(col_f);
    const row: u32 = @intFromFloat(row_f);

    if (col >= self.width or row >= self.height) return null;

    const tile = self.layout.tiled;
    const tile_col = col - (col % tile.tile_width);
    const tile_row = row - (row % tile.tile_height);

    if (tile.cached_tile_x != tile_col or tile.cached_tile_y != tile_row) {
        if (c.TIFFReadTile(self.tif, tile.tile_buf.ptr, col, row, 0, 0) < 0) {
            return error.TIFFReadTileError;
        }
        self.layout.tiled.cached_tile_x = tile_col;
        self.layout.tiled.cached_tile_y = tile_row;
    }

    const samples = std.mem.bytesAsSlice(f32, tile.tile_buf);
    const local_col = col % tile.tile_width;
    const local_row = row % tile.tile_height;
    const local_index = local_row * tile.tile_width + local_col;
    return samples[local_index];
}

fn readStripedElevation(self: *GeoTiff, allocator: std.mem.Allocator, target_x: f64, target_y: f64) !?f32 {
    _ = self;
    _ = allocator;
    _ = target_x;
    _ = target_y;
    @panic("readStripedElevation is not implemented yet");
}

pub const Coordinate = struct { x: f64, y: f64 };

pub const CoordinateTransformer = struct {
    pj: *c.PJ,

    pub fn init(target_epsg: c_short) !CoordinateTransformer {
        var buf: [64]u8 = undefined;
        const target_def = try std.fmt.bufPrintZ(&buf, "EPSG:{d}", .{target_epsg});

        const p = c.proj_create_crs_to_crs(null, "EPSG:4326", target_def.ptr, null) orelse return error.ProjCreateError;
        defer _ = c.proj_destroy(p);

        const normalized = c.proj_normalize_for_visualization(null, p) orelse return error.ProjNormalizeError;
        return .{ .pj = normalized };
    }

    pub fn deinit(self: CoordinateTransformer) void {
        _ = c.proj_destroy(self.pj);
    }

    pub fn transform(self: CoordinateTransformer, lon: f64, lat: f64) Coordinate {
        var coord: c.PJ_COORD = undefined;
        coord.xy.x = lon;
        coord.xy.y = lat;

        const res = c.proj_trans(self.pj, c.PJ_FWD, coord);
        return .{ .x = res.xy.x, .y = res.xy.y };
    }
};

pub fn transformCoordinates(lon: f64, lat: f64, target_epsg: c_short, target_model: c_short) !Coordinate {
    if (target_epsg == 4326 or target_model == 2) return .{ .x = lon, .y = lat };
    const transformer = try CoordinateTransformer.init(target_epsg);
    defer transformer.deinit();
    return transformer.transform(lon, lat);
}
