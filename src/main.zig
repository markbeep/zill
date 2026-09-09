const std = @import("std");
const tiff = @import("tiff.zig");
const osm = @import("osm.zig");
const graph = @import("graph.zig");

pub fn main(init: std.process.Init) !void {
    var geo = try tiff.open(init.gpa, "data/switzerland_dhm25.tif");
    defer geo.close();
    std.debug.print("GeoTIFF opened successfully\n", .{});

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    {
        const pbf_path = "data/switzerland-260907.osm.pbf";
        const progress = std.Progress.start(init.io, .{ .root_name = "filter OSM routes", .estimated_total_items = 3 });
        defer progress.end();
        var node_counts = std.AutoHashMap(i64, u32).init(arena.allocator());
        var relevant_ways = std.AutoHashMap(i64, void).init(arena.allocator());
        try osm.findRelevantNodes(pbf_path, progress, &node_counts, &relevant_ways);

        var nodes = std.AutoHashMap(i64, osm.Coordinate).init(arena.allocator());
        try osm.extractNodeElevations(pbf_path, progress, geo, node_counts, &nodes);

        var dyn_graph = graph.DynamicGraph.init(arena.allocator());
        try osm.computeWayElevations(pbf_path, progress, nodes, node_counts, relevant_ways, &dyn_graph);

        var f = try std.Io.Dir.cwd().createFile(init.io, "data/graph.zl", .{});
        defer f.close(init.io);
        var buffer: [1024]u8 = undefined;
        var writer = f.writer(init.io, &buffer);
        try dyn_graph.exportToWriter(&writer.interface);
        std.debug.print("Graph exported to graph.zl\n", .{});
    }

    var f = try std.Io.Dir.cwd().openFile(init.io, "data/graph.zl", .{ .mode = .read_only });
    defer f.close(init.io);

    var buffer: [1024]u8 = undefined;
    var reader = f.reader(init.io, &buffer);
    var g = try graph.DynamicGraph.fromReader(arena.allocator(), &reader.interface);
    defer g.deinit();

    std.debug.print("Graph loaded successfully with {d} nodes and {d} edges\n", .{ g.node_edges.items.len, g.edges.items.len });

    var from: usize, var to: usize, var mx: u32 = .{ 0, 0, 0 };

    for (g.edges.items) |e| {
        if (e.distance > mx) {
            mx = e.distance;
            from = e.u_idx;
            to = e.v_idx;
        }
    }

    const from_id = g.nodes.items[from].id;
    const to_id = g.nodes.items[to].id;
    std.debug.print("Longest edge is from node {d} to node {d} with distance {d} meters\n", .{ from_id, to_id, mx });
}
