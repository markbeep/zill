const std = @import("std");
const zill = @import("zill");
const solve = zill.solve;
const args_parser = @import("args");

const Options = struct {
    @"input-path": []const u8 = "data/graph.zl",
    @"max-distance": ?u32 = null,
    @"max-elevation": ?u32 = null,
    @"max-radius": f64 = 100,
    area: ?[]const u8 = null,
    lat: f64 = 47.38300076849868,
    lon: f64 = 8.539661719099556,
    @"max-threads": ?u32 = null,
    results: u32 = 5,
    dedup: f64 = 0.5,
    help: bool = false,

    pub const shorthands = .{
        .i = "input-path",
        .r = "max-radius",
        .d = "max-distance",
        .e = "max-elevation",
        .a = "area",
        .t = "max-threads",
        .h = "help",
    };

    pub const meta = .{
        .option_docs = .{
            .@"input-path" = "Path to the input graph file. Default: data/graph.zl",
            .@"max-distance" = "Maximum total distance (in m) path to compute. Default: null",
            .@"max-elevation" = "Maximum total elevation path (in m) to compute. Default: null",
            .@"max-radius" = "Maximum radius (in m) to consider for starting nodes. Default: 100",
            .area = "Search area as \"lat,lon;lat,lon;...\" (concave allowed). Overrides --max-radius. Default: null",
            .lat = "Latitude of the starting point. Default: 47.38300076849868",
            .lon = "Longitude of the starting point. Default: 8.539661719099556",
            .@"max-threads" = "Maximum number of threads to use. Default: null (all)",
            .results = "Number of results to save. Default: 5",
            .dedup = "Overlap above which two routes count as the same climb (0..1, >= 1 disables). Default: 0.5",
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
    const end_condition: solve.EndCondition = if (opts.options.@"max-distance") |md| .{ .max_distance = md } else if (opts.options.@"max-elevation") |me| .{ .at_least_elevation = me } else unreachable;

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    // ========= READ GRAPH =========
    // The file is mapped into memory and read in place: no per-node copy, no
    // second set of reverse edges.

    const input_path = opts.options.@"input-path";
    const stat = std.Io.Dir.cwd().statFile(init.io, input_path, .{}) catch |e| {
        std.debug.print("Failed to open input file: {s}\n", .{input_path});
        return e;
    };
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    {
        var f = std.Io.Dir.cwd().openFile(init.io, input_path, .{ .mode = .read_only }) catch |e| {
            std.debug.print("Failed to open input file: {s}\n", .{input_path});
            return e;
        };
        defer f.close(init.io);
        var buffer: [1024]u8 = undefined;
        var reader = f.reader(init.io, &buffer);
        try reader.interface.readSliceAll(bytes);
    }

    var graph = zill.packed_graph.PackedGraph.init(allocator, bytes) catch |e| {
        std.debug.print("Not a usable graph file ({s}): {s}\n", .{ input_path, @errorName(e) });
        return e;
    };
    defer graph.deinit();

    std.debug.print("Graph loaded: {d} nodes, {d} edges, {d:.1} MB\n", .{
        graph.nodeCount(),
        graph.edgeCount(),
        @as(f64, @floatFromInt(bytes.len)) / (1024 * 1024),
    });

    // One global progress for the whole run; `start` asserts it is a singleton.
    const progress = std.Progress.start(init.io, .{ .root_name = "zill" });
    defer progress.end();
    {
        const p = progress.start("indexing graph", 0);
        defer p.end();
        try graph.index();
    }

    // ========= START NODES =========

    var start_indices: []u32 = undefined;
    if (opts.options.area) |spec| {
        var points = std.ArrayList(solve.Coord).empty;
        var it = std.mem.tokenizeAny(u8, spec, ";,\n\t ");
        while (it.next()) |lat_token| {
            const lon_token = it.next() orelse return error.InvalidArea;
            try points.append(allocator, .{
                .lat = try std.fmt.parseFloat(f64, lat_token),
                .lon = try std.fmt.parseFloat(f64, lon_token),
            });
        }
        if (points.items.len < 3) {
            std.debug.print("Error: an area needs at least 3 points (got {d})\n", .{points.items.len});
            return error.InvalidArea;
        }
        const polygon = zill.area.Polygon.init(try points.toOwnedSlice(allocator));
        std.debug.print("Area: {d} points, {d:.1} ha, {d:.0} m perimeter\n", .{
            polygon.points.len,
            polygon.areaM2() / 10_000.0,
            polygon.perimeterM(),
        });

        var grid = try graph.buildGrid(allocator, zill.area.NodeGrid.defaultCellMeters());
        defer grid.deinit(allocator);
        start_indices = try grid.query(allocator, polygon);
        std.debug.print("Starting nodes inside the area: {d}\n", .{start_indices.len});
    } else {
        const target = solve.Coord{ .lat = opts.options.lat, .lon = opts.options.lon };
        start_indices = try solve.getCloseNodes(allocator, progress, target, opts.options.@"max-radius", graph);
    }

    if (start_indices.len == 0) {
        std.debug.print("Error: no starting nodes in the selected area\n", .{});
        return error.NoStartingNodes;
    }

    // ========= EVALUATE =========
    // Ask for a wider pool than we print, so suppression has room to drop the
    // twins of a climb and still fill the list.
    const results: usize = opts.options.results;
    const pool: usize = if (opts.options.dedup >= 1.0) results else @max(results * 64, 256);

    const best_start_results = try solve.findBestStartingPoint(init.gpa, init.io, progress, start_indices, graph, end_condition, pool);
    defer init.gpa.free(best_start_results);
    std.mem.reverse(solve.Result, best_start_results);

    var candidates = std.ArrayList(zill.dedup.Candidate).empty;
    defer {
        for (candidates.items) |candidate| init.gpa.free(candidate.path);
        candidates.deinit(init.gpa);
    }
    for (best_start_results) |res| {
        if (res.elevation < zill.search.MIN_CLIMB_GAIN_M) continue; // not a climb
        const details = try solve.Dijkstra(.Path).run(init.gpa, graph, res.idx, end_condition);
        try candidates.append(init.gpa, .{
            .start_idx = res.idx,
            .elevation = details.elevation,
            .path = details.indices,
            .distance = details.distance,
        });
    }

    var scratch = zill.dedup.Scratch.init(init.gpa);
    defer scratch.deinit();
    const selection = try zill.dedup.selectDiverse(init.gpa, candidates.items, results, opts.options.dedup, graph, &scratch);
    defer init.gpa.free(selection.accepted);

    std.debug.print("Found {d} routes ({d} near-duplicates of {d} candidates suppressed)\n", .{
        selection.accepted.len,
        selection.suppressed,
        candidates.items.len,
    });
    for (selection.accepted, 0..) |res, i| {
        const gradient = if (res.distance > 0)
            @as(f64, @floatFromInt(res.elevation)) / @as(f64, @floatFromInt(res.distance)) * 100.0
        else
            0;
        std.debug.print("#{d}: node {d} | elevation={d} m | distance={d} m | {d:.1} %\n", .{
            i + 1,
            res.start_idx,
            res.elevation,
            res.distance,
            gradient,
        });

        var path_buf: [64]u8 = undefined;
        var name_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "data/route_{d}.gpx", .{i + 1});
        const name = try std.fmt.bufPrint(&name_buf, "Route #{d}", .{i + 1});
        try solve.writeGpx(init.io, path, name, graph, .{
            .indices = @constCast(res.path),
            .distance = res.distance,
            .elevation = @intCast(res.elevation),
        });
    }
}
