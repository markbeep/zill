const std = @import("std");
const zill = @import("zill");
const solve = zill.solve;
const args_parser = @import("args");

const Options = struct {
    @"input-path": []const u8 = "data/graph.zl",
    @"max-distance": ?u32 = null,
    @"max-elevation": ?u32 = null,
    @"max-radius": f64 = 100,
    lat: f64 = 47.38300076849868,
    lon: f64 = 8.539661719099556,
    @"max-threads": ?u32 = null,
    results: u32 = 5,
    help: bool = false,

    pub const shorthands = .{
        .i = "input-path",
        .r = "max-radius",
        .d = "max-distance",
        .e = "max-elevation",
        .t = "max-threads",
        .h = "help",
    };

    pub const meta = .{
        .option_docs = .{
            .@"input-path" = "Path to the input graph file. Default: data/graph.zl",
            .@"max-distance" = "Maximum total distance (in m) path to compute. Default: null",
            .@"max-elevation" = "Maximum total elevation path (in m) to compute. Default: null",
            .@"max-radius" = "Maximum radius (in m) to consider for starting nodes. Default: 10_000",
            .lat = "Latitude of the starting point. Default: 47.38300076849868",
            .lon = "Longitude of the starting point. Default: 8.539661719099556",
            .@"max-threads" = "Maximum number of threads to use. Default: null (all)",
            .results = "Number of results to save. Default: 5",
            .help = "Show this help message",
        },

        .usage_summary = "[options]",
    };
};

pub fn main(init: std.process.Init) !void {
    // ========= ARGS =========
    const opts = try args_parser.parseForCurrentProcess(Options, init, .print);
    defer opts.deinit();

    if (opts.options.help) {
        var buffer: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &buffer);
        try args_parser.printHelp(Options, "zill", &stderr.interface);
        try stderr.flush();
        return;
    }
    if (opts.options.@"max-threads" == 0) {
        std.debug.print("Error: max-threads must be greater than 0\n", .{});
        return error.InvalidArgument;
    }
    if (opts.options.@"max-radius" <= 0) {
        std.debug.print("Error: max-radius must be greater than 0\n", .{});
        return error.InvalidArgument;
    }
    if (opts.options.@"max-distance" == null and opts.options.@"max-elevation" == null) {
        std.debug.print("Error: at least one of max-distance or max-elevation must be specified\n", .{});
        return error.InvalidArgument;
    }
    const end_condition: solve.EndCondition = if (opts.options.@"max-distance") |md| .{ .max_distance = md } else if (opts.options.@"max-elevation") |me| .{ .max_elevation = me } else unreachable;

    // ========= READ GRAPH =========

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var f = std.Io.Dir.cwd().openFile(init.io, opts.options.@"input-path", .{ .mode = .read_only }) catch |e| {
        std.debug.print("Failed to open input file: {s}\n", .{opts.options.@"input-path"});
        return e;
    };
    defer f.close(init.io);

    var buffer: [1024]u8 = undefined;
    var reader = f.reader(init.io, &buffer);
    var g = try zill.DynamicGraph.fromReader(arena.allocator(), &reader.interface);
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

    // ========= EVALUATE =========
    const target = solve.Coord{ .lat = opts.options.lat, .lon = opts.options.lon };

    const progress = std.Progress.start(init.io, .{ .root_name = "find max distance" });
    defer progress.end();
    const close_indices = try solve.getCloseNodes(init.gpa, progress, target, opts.options.@"max-radius", g);
    defer init.gpa.free(close_indices);

    const best_start_results = try solve.findBestStartingPoint(init.gpa, init.io, progress, close_indices, g, end_condition, opts.options.results);
    defer init.gpa.free(best_start_results);
    std.mem.reverse(solve.Result, best_start_results);

    std.debug.print("Found {d} results\n", .{best_start_results.len});
    std.debug.print("Top results:\n", .{});
    for (best_start_results, 0..) |res, i| {
        std.debug.print("#{d}: elevation={d}\n", .{ i + 1, res.elevation });
        const path_indices = try solve.dijkstraGetPath(init.gpa, res.idx, end_condition, g.edges.items, g.node_edges.items);
        defer init.gpa.free(path_indices.indices);

        var path_buf: [64]u8 = undefined;
        var name_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "data/route_{d}.gpx", .{i + 1});
        const name = try std.fmt.bufPrint(&name_buf, "Route #{d}", .{i + 1});
        try solve.writeGpx(init.io, path, name, g.nodes.items, path_indices);
    }
}
