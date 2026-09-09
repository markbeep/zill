const std = @import("std");
const tiff = @import("tiff.zig");
const osm = @import("osm.zig");
const graph = @import("graph.zig");

pub fn main(init: std.process.Init) !void {
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

    // const progress = std.Progress.start(init.io, .{ .root_name = "filter OSM routes", .estimated_total_items = 4 });
    // try osm.generateGraph(init.io, arena.allocator(), geo, progress, "data/switzerland-260907.osm.pbf");

    var f = try std.Io.Dir.cwd().openFile(init.io, "data/graph.zill", .{ .mode = .read_only });
    defer f.close(init.io);

    var buffer: [1024]u8 = undefined;
    var reader = f.reader(init.io, &buffer);
    var g = try graph.DynamicGraph.fromReader(arena.allocator(), &reader.interface);
    defer g.deinit();

    std.debug.print("Graph loaded successfully with {d} nodes and {d} edges\n", .{ g.node_edges.items.len, g.edges.items.len });

    var from: usize, var to: usize, var mx: u16 = .{ 0, 0, 0 };

    for (g.edges.items) |e| {
        if (e.distance > mx) {
            mx = e.distance;
            from = e.from;
            to = e.to;
        }
    }

    const from_id = g.nodes.items[from].id;
    const to_id = g.nodes.items[to].id;
    std.debug.print("Longest edge is from node {d} to node {d} with distance {d} meters\n", .{ from_id, to_id, mx });
}
