const std = @import("std");
const zill = @import("zill");
const solve = zill.solve;

fn usage() void {
    std.debug.print("usage: zill [-i <path>] [-d <max_distance>] [-r <max_radius>] [--lat <latitude>] [--lon <longitude>]\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var input_path: []const u8 = "data/graph.zl";
    var max_distance: i64 = 1000;
    var max_radius: f64 = 10_000;
    var lat: f64 = 47.38300076849868;
    var lon: f64 = 8.539661719099556;

    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            input_path = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--max-distance")) {
            const dist_str = args.next() orelse return error.InvalidArguments;
            max_distance = try std.fmt.parseInt(i64, dist_str, 10);
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--max-radius")) {
            const radius_str = args.next() orelse return error.InvalidArguments;
            max_radius = try std.fmt.parseFloat(f64, radius_str);
        } else if (std.mem.eql(u8, arg, "--lat")) {
            const lat_str = args.next() orelse return error.InvalidArguments;
            lat = try std.fmt.parseFloat(f64, lat_str);
        } else if (std.mem.eql(u8, arg, "--lon")) {
            const lon_str = args.next() orelse return error.InvalidArguments;
            lon = try std.fmt.parseFloat(f64, lon_str);
        } else {
            usage();
            return error.InvalidArguments;
        }
    }

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    var f = try std.Io.Dir.cwd().openFile(init.io, input_path, .{ .mode = .read_only });
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

    var results: [5]?solve.PathState = undefined;
    @memset(&results, null);
    defer for (results) |res_null| {
        if (res_null) |r| init.gpa.free(r.path);
    };

    const progress = std.Progress.start(init.io, .{ .root_name = "find max distance" });
    defer progress.end();
    const count = try solve.findMax(
        init.gpa,
        init.io,
        progress,
        .{ .lat = lat, .lon = lon },
        max_radius,
        max_distance,
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
