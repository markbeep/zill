const std = @import("std");
const zill = @import("zill");
const solve = zill.solve;

fn usage() void {
    std.debug.print("usage: zill [-i <path>]\n", .{});
}

pub fn main(init: std.process.Init) !void {
    var input_path: []const u8 = "data/graph.zl";
    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage();
            return;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            input_path = args.next() orelse return error.InvalidArguments;
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

    const progress = std.Progress.start(init.io, .{ .root_name = "find max distance" });
    defer progress.end();
    try solve.findMax(
        init.gpa,
        progress,
        .{ .lat = 47.38300076849868, .lon = 8.539661719099556 },
        500.0,
        g.nodes.items,
        g.edges.items,
        g.node_edges.items,
    );
}
