const std = @import("std");
const s = @import("shared.zig");
const graph = @import("graph.zig");

pub const Coord = struct {
    lat: f64,
    lon: f64,
};

pub const PathState = struct {
    distance: i64,
    elevation: i32,
    path: []u32,
};

pub const EndCondition = union(enum) {
    max_distance: u32,
    max_elevation: u32,
};

// =============================

pub fn getCloseNodes(
    allocator: std.mem.Allocator,
    progress: std.Progress.Node,
    target: Coord,
    max_radius_m: f64,
    dyn: graph.DynamicGraph,
) ![]u32 {
    var close_nodes = try std.ArrayList(u32).initCapacity(allocator, 1000);
    const p = progress.start("searching for close-by nodes", dyn.nodes.items.len);
    defer p.end();

    for (dyn.nodes.items, 0..) |n, i| {
        const dist = haversineMeters(target, .{ .lat = n.lat, .lon = n.lon });
        if (dist <= max_radius_m) {
            try close_nodes.append(allocator, @intCast(i));
        }
        p.completeOne();
    }

    return try close_nodes.toOwnedSlice(allocator);
}

pub const Result = struct {
    idx: u32,
    elevation: i64,

    fn compareForResult(_: void, a: Result, b: Result) std.math.Order {
        return std.math.order(a.elevation, b.elevation);
    }
};

/// Finds the maximum elevations reachable from the given start indices, subject to the end condition.
/// Returns a slice of `Result` structs, each containing the start index and the maximum elevation found,
/// sorted in ascending order of elevation. The number of results returned is limited by `max_results`.
pub fn findBestStartingPoint(
    allocator: std.mem.Allocator,
    io: std.Io,
    progress: std.Progress.Node,
    start_indices: []u32,
    dyn: graph.DynamicGraph,
    end_condition: EndCondition,
    max_results: usize,
) ![]Result {
    const ResultMsg = union(enum) {
        done: anyerror!Result,
    };

    const TaskBatch = struct {
        fn run(
            p: std.Progress.Node,
            start_idx: u32,
            _allocator: std.mem.Allocator,
            _end_condition: EndCondition,
            _edges: []const s.Edge,
            _outgoing: []std.ArrayList(u32),
        ) !Result {
            const elevation = try dijkstraFindHighest(_allocator, start_idx, _end_condition, _edges, _outgoing);
            p.completeOne();
            return .{ .elevation = elevation, .idx = start_idx };
        }
    };

    var ordered = std.PriorityQueue(Result, void, Result.compareForResult).empty;
    defer ordered.deinit(allocator);

    // var buf: [start_indices.len]Result = undefined;
    const buf = try allocator.alloc(ResultMsg, start_indices.len);
    defer allocator.free(buf);
    var select = std.Io.Select(ResultMsg).init(io, buf);
    defer select.cancelDiscard();

    const p = progress.start("finding maximum elevations", start_indices.len);
    defer p.end();

    for (start_indices) |start_idx| {
        select.async(.done, TaskBatch.run, .{ p, start_idx, allocator, end_condition, dyn.edges.items, dyn.node_edges.items });
    }

    const accum_progress = progress.start("accumulating results", start_indices.len);
    defer accum_progress.end();

    for (start_indices) |_| {
        const res = try select.await();
        try ordered.push(allocator, try res.done);
        if (ordered.count() > max_results) {
            _ = ordered.pop();
        }
    }

    var results = try allocator.alloc(Result, ordered.count());
    for (ordered.items, 0..) |r, i| {
        results[i] = r;
    }
    return results;
}

/// Finds the highest elevation reachable from `start_idx` without exceeding the given `end` condition.
/// Does not return the path, only the highest elevation found. Use `dijkstraGetPath` to retrieve the path if needed.
fn dijkstraFindHighest(
    allocator: std.mem.Allocator,
    start_idx: u32,
    end_condition: EndCondition,
    edges: []const s.Edge,
    outgoing: []std.ArrayList(u32),
) !i64 {
    const VisitedNode = struct {
        distance: i64,
        elevation: i32,

        fn compareForDistance(visited: *const std.AutoHashMap(u32, @This()), u_idx: u32, v_idx: u32) std.math.Order {
            const u = visited.get(u_idx) orelse unreachable;
            const v = visited.get(v_idx) orelse unreachable;
            return std.math.order(u.distance, v.distance);
        }
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var visited = std.AutoHashMap(u32, VisitedNode).init(arena.allocator());
    try visited.put(start_idx, .{ .distance = 0, .elevation = 0 });

    var pq = std.PriorityQueue(u32, *const std.AutoHashMap(u32, VisitedNode), VisitedNode.compareForDistance).initContext(&visited);
    try pq.push(arena.allocator(), start_idx);

    var highest: i64 = 0;
    while (pq.pop()) |current_idx| {
        const u = visited.get(current_idx) orelse unreachable;
        if (end_condition == .max_elevation and u.elevation >= end_condition.max_elevation) {
            return u.elevation;
        }

        for (outgoing[current_idx].items) |outgoing_edge_idx| {
            const edge = edges[outgoing_edge_idx];
            const new_distance = u.distance + edge.distance;
            const new_elevation = u.elevation + edge.elev_gain - edge.elev_loss;

            if (end_condition == .max_distance and new_distance > end_condition.max_distance) {
                continue;
            }

            if (visited.get(edge.v_idx)) |v| {
                if (new_distance >= v.distance) continue;
            }

            try visited.put(edge.v_idx, .{ .distance = new_distance, .elevation = new_elevation });
            try pq.push(arena.allocator(), edge.v_idx);
            highest = @max(highest, new_elevation);
        }
    }
    return highest;
}

pub const PathDetails = struct {
    indices: []u32,
    distance: i64,
    elevation: i32,
};

/// Finds a path from `start_idx` to the highest elevation reachable without exceeding the given `end_condition`.
/// Returns a `PathDetails` struct containing the path indices, total distance, and total elevation gain. The path is returned in order from start to end.
/// Caller owns the returned slice.
pub fn dijkstraGetPath(
    allocator: std.mem.Allocator,
    start_idx: u32,
    end_condition: EndCondition,
    edges: []const s.Edge,
    outgoing: []std.ArrayList(u32),
) !PathDetails {
    const VisitedNode = struct {
        idx: u32,
        distance: i64,
        elevation: i32,
        prev: ?u32,

        fn compareForDistance(visited: *const std.AutoHashMap(u32, @This()), u_idx: u32, v_idx: u32) std.math.Order {
            const u = visited.get(u_idx) orelse unreachable;
            const v = visited.get(v_idx) orelse unreachable;
            return std.math.order(u.distance, v.distance);
        }
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var visited = std.AutoHashMap(u32, VisitedNode).init(arena.allocator());
    const initial = VisitedNode{ .idx = start_idx, .distance = 0, .elevation = 0, .prev = null };
    try visited.put(start_idx, initial);
    var highest: VisitedNode = initial;

    var pq = std.PriorityQueue(u32, *const std.AutoHashMap(u32, VisitedNode), VisitedNode.compareForDistance).initContext(&visited);
    try pq.push(arena.allocator(), start_idx);

    while (pq.pop()) |current_idx| {
        const u = visited.get(current_idx) orelse unreachable;
        if (end_condition == .max_elevation and u.elevation >= end_condition.max_elevation) {
            highest = u;
            break;
        }

        for (outgoing[current_idx].items) |outgoing_edge_idx| {
            const edge = edges[outgoing_edge_idx];
            const new_distance = u.distance + edge.distance;
            const new_elevation = u.elevation + edge.elev_gain - edge.elev_loss;

            if (end_condition == .max_distance and new_distance > end_condition.max_distance) {
                continue;
            }

            if (visited.get(edge.v_idx)) |v| {
                if (new_distance >= v.distance) continue;
            }

            const new_visited = VisitedNode{
                .idx = edge.v_idx,
                .distance = new_distance,
                .elevation = new_elevation,
                .prev = edge.u_idx,
            };
            try visited.put(edge.v_idx, new_visited);
            try pq.push(arena.allocator(), edge.v_idx);
            if (new_elevation > highest.elevation) {
                highest = new_visited;
            }
        }
    }

    // Non-arena allocator
    var path = std.ArrayList(u32).empty;
    try path.append(allocator, highest.idx);
    var current = highest;
    while (current.prev) |prev| {
        try path.append(allocator, prev);
        current = visited.get(prev) orelse unreachable;
    }

    const owned = try path.toOwnedSlice(allocator);
    std.mem.reverse(u32, owned);
    return .{ .indices = owned, .distance = highest.distance, .elevation = highest.elevation };
}

/// Computes great-circle distance between two coordinates in meters
pub fn haversineMeters(p1: Coord, p2: Coord) f64 {
    const r_earth = 6_371_000.0; // Mean Earth radius in meters

    const d_lat = std.math.degreesToRadians(p2.lat - p1.lat);
    const d_lon = std.math.degreesToRadians(p2.lon - p1.lon);

    const lat1_rad = std.math.degreesToRadians(p1.lat);
    const lat2_rad = std.math.degreesToRadians(p2.lat);

    const sin_dlat_2 = @sin(d_lat / 2.0);
    const sin_dlon_2 = @sin(d_lon / 2.0);

    const a = (sin_dlat_2 * sin_dlat_2) +
        (@cos(lat1_rad) * @cos(lat2_rad) * sin_dlon_2 * sin_dlon_2);

    const _c = 2.0 * std.math.atan2(@sqrt(a), @sqrt(1.0 - a));

    return r_earth * _c;
}

pub fn writeGpx(io: std.Io, file_path: []const u8, name: []const u8, nodes: []const s.Node, c: PathDetails) !void {
    var f = try std.Io.Dir.cwd().createFile(io, file_path, .{});
    defer f.close(io);

    var buffer: [1024]u8 = undefined;
    var w = f.writer(io, &buffer);
    const out = &w.interface;

    try out.print("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", .{});
    try out.print("<gpx version=\"1.1\" creator=\"zill\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n", .{});
    try out.print("<trk>\n<name>zill rank {s} | elev {d}m | dist {d}m | {d} pts</name>\n<trkseg>\n", .{
        name,
        c.elevation,
        c.distance,
        c.indices.len,
    });

    for (c.indices) |node_idx| {
        const n = nodes[node_idx];
        if (n.elev) |ele| {
            try out.print("<trkpt lat=\"{d:.7}\" lon=\"{d:.7}\"><ele>{d}</ele></trkpt>\n", .{ n.lat, n.lon, ele });
        } else {
            try out.print("<trkpt lat=\"{d:.7}\" lon=\"{d:.7}\"/>\n", .{ n.lat, n.lon });
        }
    }

    try out.print("</trkseg>\n</trk>\n</gpx>\n", .{});
    try out.flush();

    std.debug.print("wrote {s} with elev {d}m, dist {d}m, {d} pts\n", .{ file_path, c.elevation, c.distance, c.indices.len });
}

// ======================================== Benchmarks ========================================

const DijkstraType = enum {
    Highest,
    Path,
};

fn GenBenchDijkstra(comptime dtype: DijkstraType, comptime node_idx: u32, comptime g: *const graph.DynamicGraph) type {
    switch (dtype) {
        .Highest => {
            return struct {
                fn run(allocator: std.mem.Allocator) void {
                    _ = dijkstraFindHighest(
                        allocator,
                        node_idx,
                        .{ .max_distance = 1_000 },
                        g.edges.items,
                        g.node_edges.items,
                    ) catch @panic("dijkstra2 failed");
                }
            };
        },
        .Path => {
            return struct {
                fn run(allocator: std.mem.Allocator) void {
                    const result = dijkstraGetPath(
                        allocator,
                        node_idx,
                        .{ .max_distance = 1_000 },
                        g.edges.items,
                        g.node_edges.items,
                    ) catch @panic("dijkstra2 failed");
                    defer allocator.free(result.indices);
                }
            };
        },
    }
}

var bench_g: graph.DynamicGraph = undefined;

test "benchmark distance dijkstra" {
    const testing = std.testing;
    const zbench = @import("zbench");

    // One-time graph load: use a fast arena-backed allocator. The debug
    // `testing.allocator` makes loading the 199 MB graph take tens of seconds.
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var f = try std.Io.Dir.cwd().openFile(testing.io, "data/100m_graph.zl", .{ .mode = .read_only });
    defer f.close(testing.io);

    var buffer: [1024]u8 = undefined;
    var reader = f.reader(testing.io, &buffer);
    bench_g = try graph.DynamicGraph.fromReader(arena.allocator(), &reader.interface);

    var bench = zbench.Benchmark.init(testing.allocator, .{});
    defer bench.deinit();

    const target = comptime blk: {
        var prng = std.Random.DefaultPrng.init(0);
        const rand = prng.random();
        break :blk rand.intRangeAtMost(u32, 0, 10000);
    };

    // ======== Setup done ========

    const Bench1 = GenBenchDijkstra(.Highest, target, &bench_g);
    try bench.add("Benchmark peak finder Dijkstra", Bench1.run, .{ .track_allocations = true });

    const Bench2 = GenBenchDijkstra(.Path, target, &bench_g);
    try bench.add("Benchmark path determining Dijkstra", Bench2.run, .{ .track_allocations = true });

    try bench.run(testing.io, std.Io.File.stderr());
}
