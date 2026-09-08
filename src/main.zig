const std = @import("std");
const tiff = @import("tiff.zig");

pub fn main(init: std.process.Init) !void {
    const geo = try tiff.open("data/elevation.tif");
    defer geo.close();
    std.debug.print("GeoTIFF opened successfully: {any}\n", .{geo});

    std.debug.print("Image Size: {d} x {d}\n", .{ geo.width, geo.height });
    std.debug.print("Format: {d} bits/sample (format code: {d})\n", .{ geo.bits_per_sample, geo.sample_format });
    std.debug.print("Pixel Scale (Granularity): dx = {d:.6}, dy = {d:.6}\n", .{ geo.pixel_scale_x, geo.pixel_scale_y });
    std.debug.print("Top-Left Coordinates: X = {d:.6}, Y = {d:.6}\n", .{ geo.origin_x, geo.origin_y });

    const elev = try geo.readElevation(init.gpa, 8.359862, 47.613195);
    std.debug.print("Elevation at (8.359861, 47.613194): {any}\n", .{elev});
}
