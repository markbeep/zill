const std = @import("std");
const tiff = @import("tiff.zig");

pub fn main() void {
    const gtiff = tiff.open("data/elevation.tif");
    std.debug.print("GeoTIFF opened successfully: {any}\n", .{gtiff});
}
