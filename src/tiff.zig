const std = @import("std");
const c = @import("c.zig").c;

pub const GeoTiff = @This();

tif: *c.TIFF,
gtif: *c.GTIF,

pub fn open(path: []const u8) !GeoTiff {
    const tif = c.XTIFFOpen(path.ptr, "r") orelse return error.FileOpenError;
    errdefer c.XTIFFClose(tif);

    const gtif = c.GTIFNew(tif) orelse return error.GeoTiffNewError;

    return GeoTiff{
        .tif = tif,
        .gtif = gtif,
    };
}

pub fn close(self: GeoTiff) void {
    c.GTIFClose(self.gtif);
    c.XTIFFClose(self.tif);
}
