const std = @import("std");
const s = @import("shared.zig");
const options = @import("options");

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
    /// Longest path whose total distance stays under this bound, maximizing gain.
    max_distance: u32,
    /// Minimum distance needed to climb this much.
    at_least_elevation: u32,
};

// =============================

/// Every node within `max_radius_m` of the target, in graph order. Linear scan:
/// the CLI's radius mode has no spatial index by design.
pub fn getCloseNodes(
    allocator: std.mem.Allocator,
    progress: std.Progress.Node,
    target: Coord,
    max_radius_m: f64,
    graph: anytype,
) ![]u32 {
    var close_nodes = try std.ArrayList(u32).initCapacity(allocator, 1000);
    errdefer close_nodes.deinit(allocator);
    const p = progress.start("searching for close-by nodes", graph.nodeCount());
    defer p.end();

    for (0..graph.nodeCount()) |i| {
        const n: u32 = @intCast(i);
        const dist = haversineMeters(target, .{ .lat = graph.nodeLat(n), .lon = graph.nodeLon(n) });
        if (dist <= max_radius_m) {
            try close_nodes.append(allocator, n);
        }
        p.completeOne();
    }

    return close_nodes.toOwnedSlice(allocator);
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
    graph: anytype,
    end_condition: EndCondition,
    max_results: usize,
) ![]Result {
    const G = @TypeOf(graph);
    const ResultMsg = union(enum) {
        done: anyerror!Result,
    };

    const TaskBatch = struct {
        fn run(
            p: std.Progress.Node,
            start_idx: u32,
            _allocator: std.mem.Allocator,
            _end_condition: EndCondition,
            _graph: G,
        ) !Result {
            const elevation = try Dijkstra(.Elevation).run(_allocator, _graph, start_idx, _end_condition);
            p.completeOne();
            return .{ .elevation = elevation, .idx = start_idx };
        }
    };

    var ordered = std.PriorityQueue(Result, void, Result.compareForResult).empty;
    defer ordered.deinit(allocator);

    const buf = try allocator.alloc(ResultMsg, start_indices.len);
    defer allocator.free(buf);
    var select = std.Io.Select(ResultMsg).init(io, buf);
    defer select.cancelDiscard();

    const p = progress.start("finding maximum elevations", start_indices.len);
    defer p.end();

    for (start_indices) |start_idx| {
        select.async(.done, TaskBatch.run, .{ p, start_idx, allocator, end_condition, graph });
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
    var i: usize = 0;
    while (ordered.pop()) |next| : (i += 1) {
        results[i] = next;
    }
    return results;
}

pub const DijkstraReturn = enum {
    Elevation,
    Path,
};

/// Finds a path from `start_idx` to the optimal elevation reachable without exceeding the given `end_condition`.
/// The return type is determined by `dtype`: `.Elevation` returns the optimal elevation as an `i64`,
/// while `.Path` returns a `PathDetails` struct containing the path indices (in order from start to end)
/// plus total distance and elevation. Caller owns any returned slices.
///
/// `graph` may be any type exposing `nodeCount`, `nodeLat`, `nodeLon`, `outDegree` and `halfEdge`
/// (both `DynamicGraph` and `PackedGraph` do), so the CLI and the browser run the same code.
pub fn Dijkstra(comptime dtype: DijkstraReturn) type {
    const ReturnType = switch (dtype) {
        .Elevation => i64,
        .Path => PathDetails,
    };

    return struct {
        pub fn run(
            allocator: std.mem.Allocator,
            graph: anytype,
            start_idx: u32,
            end_condition: EndCondition,
        ) !ReturnType {
            const G = @TypeOf(graph);
            const VisitedNode = struct {
                idx: u32,
                distance: i64,
                elevation: i32,
                prev: ?u32,
            };

            const Context = struct {
                visited: *const std.AutoHashMap(u32, VisitedNode),
                graph: G,
                start_idx: u32,

                fn compareForDistance(ctx: @This(), u_idx: u32, v_idx: u32) std.math.Order {
                    const u = ctx.visited.get(u_idx) orelse unreachable;
                    const v = ctx.visited.get(v_idx) orelse unreachable;

                    var u_h: i64 = 0;
                    var v_h: i64 = 0;
                    if (options.compute_a_star) {
                        const start = Coord{
                            .lat = ctx.graph.nodeLat(ctx.start_idx),
                            .lon = ctx.graph.nodeLon(ctx.start_idx),
                        };
                        u_h = @trunc(haversineMeters(start, .{
                            .lat = ctx.graph.nodeLat(u_idx),
                            .lon = ctx.graph.nodeLon(u_idx),
                        }));
                        v_h = @trunc(haversineMeters(start, .{
                            .lat = ctx.graph.nodeLat(v_idx),
                            .lon = ctx.graph.nodeLon(v_idx),
                        }));
                    }

                    return std.math.order(u.distance + u_h, v.distance + v_h);
                }
            };

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var visited = std.AutoHashMap(u32, VisitedNode).init(arena.allocator());
            const initial = VisitedNode{ .idx = start_idx, .distance = 0, .elevation = 0, .prev = null };
            try visited.put(start_idx, initial);
            var best: VisitedNode = initial;

            var pq = std.PriorityQueue(u32, Context, Context.compareForDistance).initContext(Context{
                .visited = &visited,
                .start_idx = start_idx,
                .graph = graph,
            });
            try pq.push(arena.allocator(), start_idx);

            while (pq.pop()) |current_idx| {
                const u = visited.get(current_idx) orelse unreachable;
                if (end_condition == .at_least_elevation and u.elevation >= end_condition.at_least_elevation) {
                    best = u;
                    break;
                }

                const degree = graph.outDegree(current_idx);
                for (0..degree) |k| {
                    const edge = graph.halfEdge(current_idx, @intCast(k));
                    const new_distance = u.distance + edge.distance;
                    const new_elevation = u.elevation + edge.gain - edge.loss;

                    if (end_condition == .max_distance and new_distance > end_condition.max_distance) {
                        continue;
                    }

                    if (visited.get(edge.to)) |v| {
                        if (new_distance >= v.distance) continue;
                    }

                    const new_visited = VisitedNode{
                        .idx = edge.to,
                        .distance = new_distance,
                        .elevation = new_elevation,
                        .prev = current_idx,
                    };
                    try visited.put(edge.to, new_visited);
                    try pq.push(arena.allocator(), edge.to);

                    if (new_elevation > best.elevation) {
                        best = new_visited;
                    }
                }
            }

            switch (dtype) {
                .Elevation => return best.elevation,
                .Path => {
                    // Non-arena allocator
                    var path = std.ArrayList(u32).empty;
                    try path.append(allocator, best.idx);
                    var current = best;
                    while (current.prev) |prev| {
                        try path.append(allocator, prev);
                        current = visited.get(prev) orelse unreachable;
                    }

                    const owned = try path.toOwnedSlice(allocator);
                    std.mem.reverse(u32, owned);
                    return .{ .indices = owned, .distance = best.distance, .elevation = best.elevation };
                },
            }
        }
    };
}

pub const PathDetails = struct {
    indices: []u32,
    distance: i64,
    elevation: i32,
};

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

pub fn writeGpx(io: std.Io, file_path: []const u8, name: []const u8, graph: anytype, c: PathDetails) !void {
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
        if (graph.nodeElev(node_idx)) |ele| {
            try out.print("<trkpt lat=\"{d:.7}\" lon=\"{d:.7}\"><ele>{d}</ele></trkpt>\n", .{
                graph.nodeLat(node_idx),
                graph.nodeLon(node_idx),
                ele,
            });
        } else {
            try out.print("<trkpt lat=\"{d:.7}\" lon=\"{d:.7}\"/>\n", .{ graph.nodeLat(node_idx), graph.nodeLon(node_idx) });
        }
    }

    try out.print("</trkseg>\n</trk>\n</gpx>\n", .{});
    try out.flush();

    std.debug.print("wrote {s} with elev {d}m, dist {d}m, {d} pts\n", .{ file_path, c.elevation, c.distance, c.indices.len });
}

// ======================================== Benchmarks ========================================

const DijkstraTestType = enum {
    HighestPath,
    HighestInt,
};

fn GenBenchDijkstra(comptime dtype: DijkstraTestType, comptime node_idx: u32, comptime g: *const @import("packed_graph.zig").PackedGraph) type {
    switch (dtype) {
        .HighestPath => {
            return struct {
                fn run(allocator: std.mem.Allocator) void {
                    const result = Dijkstra(.Path).run(
                        allocator,
                        g.*,
                        node_idx,
                        .{ .max_distance = 1_000 },
                    ) catch @panic("dijkstra2 failed");
                    defer allocator.free(result.indices);
                }
            };
        },
        .HighestInt => {
            return struct {
                fn run(allocator: std.mem.Allocator) void {
                    _ = Dijkstra(.Elevation).run(
                        allocator,
                        g.*,
                        node_idx,
                        .{ .max_distance = 1_000 },
                    ) catch @panic("dijkstra2 failed");
                }
            };
        },
    }
}

var bench_graph: @import("packed_graph.zig").PackedGraph = undefined;

test "benchmark distance dijkstra" {
    const testing = std.testing;
    const zbench = @import("zbench");
    const packed_graph = @import("packed_graph.zig");

    // Skipped when the generated graph is not present: `just generate` builds it.
    const file = std.Io.Dir.cwd().openFile(testing.io, "data/switzerland_walkable_100m.zl", .{ .mode = .read_only }) catch return error.SkipZigTest;
    defer file.close(testing.io);
    const stat = file.stat(testing.io) catch return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const bytes = arena.allocator().alloc(u8, @intCast(stat.size)) catch return error.SkipZigTest;
    var buffer: [1024]u8 = undefined;
    var reader = file.reader(testing.io, &buffer);
    reader.interface.readSliceAll(bytes) catch return error.SkipZigTest;

    bench_graph = packed_graph.PackedGraph.init(arena.allocator(), bytes) catch return error.SkipZigTest;
    defer bench_graph.deinit();
    bench_graph.index() catch return error.SkipZigTest;

    var bench = zbench.Benchmark.init(testing.allocator, .{});
    defer bench.deinit();

    const target = comptime blk: {
        var prng = std.Random.DefaultPrng.init(0);
        const rand = prng.random();
        break :blk rand.intRangeAtMost(u32, 0, 10000);
    };

    const Bench1 = GenBenchDijkstra(.HighestPath, target, &bench_graph);
    try bench.add("Benchmark path determining Dijkstra", Bench1.run, .{ .track_allocations = true });

    const Bench2 = GenBenchDijkstra(.HighestInt, target, &bench_graph);
    try bench.add("Benchmark peak finder Dijkstra (new impl)", Bench2.run, .{ .track_allocations = true });

    try bench.run(testing.io, std.Io.File.stderr());
}
