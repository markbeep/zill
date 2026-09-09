const std = @import("std");
const tiff = @import("tiff.zig");
const osm = @import("osm.zig");
const graph = @import("zill");

pub const Options = struct {
    geotiff_path: []const u8 = "data/switzerland_dhm25.tif",
    osm_path: []const u8 = "data/switzerland-260907.osm.pbf",
    output_path: []const u8 = "data/graph.zl",
};

pub fn generate(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    var geo = try tiff.open(gpa, options.geotiff_path);
    defer geo.close();
    std.debug.print("GeoTIFF opened successfully\n", .{});

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    {
        const progress = std.Progress.start(io, .{ .root_name = "filter OSM routes", .estimated_total_items = 3 });
        defer progress.end();
        var node_counts = std.AutoHashMap(i64, u32).init(arena.allocator());
        var relevant_ways = std.AutoHashMap(i64, void).init(arena.allocator());
        try osm.findRelevantNodes(options.osm_path, progress, &node_counts, &relevant_ways);

        var nodes = std.AutoHashMap(i64, osm.Coordinate).init(arena.allocator());
        try osm.extractNodeElevations(options.osm_path, progress, geo, node_counts, &nodes);

        var dyn_graph = graph.DynamicGraph.init(arena.allocator());
        try osm.computeWayElevations(options.osm_path, progress, nodes, node_counts, relevant_ways, &dyn_graph);

        var f = try std.Io.Dir.cwd().createFile(io, options.output_path, .{});
        defer f.close(io);
        var buffer: [1024]u8 = undefined;
        var writer = f.writer(io, &buffer);
        try dyn_graph.exportToWriter(&writer.interface);
        std.debug.print("Graph exported to {s}\n", .{options.output_path});
    }
}
