const std = @import("std");
const tiff = @import("tiff.zig");
const osm = @import("osm.zig");
const graph = @import("graph.zig");

pub fn main(init: std.process.Init) !void {
    var g = graph.DynamicGraph.init(init.gpa);
    defer g.deinit();
    const node_idx1 = try g.addNode(1, 10.0, 20.0, 100.0);
    const node_idx2 = try g.addNode(2, 11.0, 21.0, 200.0);
    try g.addEdge(node_idx1, node_idx2, 50, 30, 100);

    {
        var f = try std.Io.Dir.cwd().createFile(init.io, "graph.zill", .{});
        defer f.close(init.io);
        var buffer: [1024]u8 = undefined;
        var writer = f.writer(init.io, &buffer);
        try g.exportToWriter(&writer.interface);
    }

    std.debug.print("Graph exported to graph.zill\n", .{});

    var geo = try tiff.open(init.gpa, "data/switzerland_dhm25.tif");
    defer geo.close();
    std.debug.print("GeoTIFF opened successfully\n", .{});

    std.debug.print("Image Size: {d} x {d}\n", .{ geo.width, geo.height });
    std.debug.print("Format: {d} bits/sample (format code: {d})\n", .{ geo.bits_per_sample, geo.sample_format });
    std.debug.print("Pixel Scale (Granularity): dx = {d:.6}, dy = {d:.6}\n", .{ geo.pixel_scale_x, geo.pixel_scale_y });
    std.debug.print("Top-Left Coordinates: X = {d:.6}, Y = {d:.6}\n", .{ geo.origin_x, geo.origin_y });

    const lat = 47.29652834536444;
    const lon = 8.611765473990042;
    const coords = try tiff.transformCoordinates(lon, lat, geo.defn.PCS, geo.defn.Model);

    const elev = try geo.readElevation(init.gpa, coords.x, coords.y);
    if (elev) |e| {
        std.debug.print("Elevation at (x={d:.6}, y={d:.6}) is: {d:.2} meters\n", .{ coords.x, coords.y, e });
    } else {
        std.debug.print("No elevation data found at (x={d:.6}, y={d:.6})\n", .{ coords.x, coords.y });
    }

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    try osm.call(init.io, arena.allocator(), geo, "data/switzerland-260907.osm.pbf");
}
