const std = @import("std");
const zill = @import("zill");
const solve = zill.solve;
const args_parser = @import("args");

const Options = struct {
    @"input-path": []const u8 = "data/graph.zl",
    @"max-distance": ?i64 = null,
    @"max-elevation": ?i64 = null,
    @"max-radius": f64 = 10_000,
    lat: f64 = 47.38300076849868,
    lon: f64 = 8.539661719099556,
    @"max-threads": u32 = 1,
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
            .@"max-threads" = "Maximum number of threads to use. Default: 1",
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

    // ========= START =========

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

    // ----------------------

    var results: [500]?solve.PathState = undefined;
    @memset(&results, null);
    defer for (results) |res_null| {
        if (res_null) |r| init.gpa.free(r.path);
    };

    var threaded: std.Io.Threaded = std.Io.Threaded.init(init.gpa, .{ .async_limit = std.Io.Limit.limited(opts.options.@"max-threads") });
    defer threaded.deinit();

    const progress = std.Progress.start(init.io, .{ .root_name = "find max distance" });
    defer progress.end();
    const count = try solve.findMax(
        init.gpa,
        init.io,
        progress,
        .{ .lat = opts.options.lat, .lon = opts.options.lon },
        opts.options.@"max-radius",
        opts.options.@"max-distance".?,
        g.nodes.items,
        g.edges.items,
        g.node_edges.items,
        &results,
    );

    for (results[0..count], 0..) |res_null, i| {
        if (res_null) |r| {
            const rank = count - i;
            var path_buf: [64]u8 = undefined;
            var name_buf: [64]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "data/route_{d}.gpx", .{rank});
            const name = try std.fmt.bufPrint(&name_buf, "Route #{d}", .{rank});
            try solve.writeGpx(init.io, path, name, g.nodes.items, r);
        }
    }
}
