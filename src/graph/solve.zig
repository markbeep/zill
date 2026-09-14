const std = @import("std");
const builtin = @import("builtin");
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
    at_least_elevation: u32,
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
            const elevation = try Dijkstra(.Elevation).run(_allocator, start_idx, _end_condition, _edges, _outgoing);
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
/// The optimization target is determined by `optimize`: `.Maximize` targets the highest elevation while
/// `.Minimize` targets elevations with the least total change.
/// The return type is determined by `dtype`: `.Elevation` returns the optimal elevation as an `i64`,
/// while `.Path` returns a `PathDetails` struct containing the path indices (in order from start to end),
/// total distance, and total elevation. Caller owns any returned slices.
pub fn Dijkstra(comptime dtype: DijkstraReturn) type {
    const ReturnType = switch (dtype) {
        .Elevation => i64,
        .Path => PathDetails,
    };

    return struct {
        /// `prev` value of a node that has no predecessor yet.
        const no_prev = std.math.maxInt(u32);

        /// Per-node search state, indexed by node index. The array is handed out
        /// uninitialised, so a slot only holds a real state when its `stamp`
        /// matches the generation of the current search. `distance` is stored as
        /// `u32`: it is either bounded by `end_condition.max_distance` or, in the
        /// `at_least_elevation` case, by the diameter of the graph, which is far
        /// below 4_294_967_295 m for any real network.
        const NodeState = struct {
            distance: u32,
            elevation: i32,
            prev: u32,
            stamp: u32,
        };

        const Search = struct {
            states: []NodeState,
            generation: u32,

            fn find(search: *const Search, node_idx: u32) ?*const NodeState {
                const state = &search.states[node_idx];
                return if (state.stamp == search.generation) state else null;
            }
        };

        /// Queue entry: the distance the node had when it was queued. An entry
        /// whose distance no longer matches the node's state is stale and is
        /// skipped when it surfaces.
        const Entry = struct {
            distance: u32,
            idx: u32,

            fn compareForDistance(_: void, a: Entry, b: Entry) std.math.Order {
                return std.math.order(a.distance, b.distance);
            }
        };

        pub fn run(
            allocator: std.mem.Allocator,
            start_idx: u32,
            end_condition: EndCondition,
            edges: []const s.Edge,
            outgoing: []std.ArrayList(u32),
        ) !ReturnType {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const generation = nextSearchGeneration();
            var search = Search{
                .states = try arena.allocator().alloc(NodeState, outgoing.len),
                .generation = generation,
            };

            const initial = NodeState{
                .distance = 0,
                .elevation = 0,
                .prev = no_prev,
                .stamp = generation,
            };
            search.states[start_idx] = initial;
            var best = initial;
            var best_idx: u32 = start_idx;

            var pq = std.PriorityQueue(Entry, void, Entry.compareForDistance).initContext({});
            try pq.push(arena.allocator(), .{ .distance = 0, .idx = start_idx });

            while (pq.pop()) |entry| {
                const current_idx = entry.idx;
                const u = search.find(current_idx) orelse unreachable;
                if (entry.distance != u.distance) continue;
                if (end_condition == .at_least_elevation and u.elevation >= end_condition.at_least_elevation) {
                    best = u.*;
                    best_idx = current_idx;
                    break;
                }

                for (outgoing[current_idx].items) |outgoing_edge_idx| {
                    const edge = edges[outgoing_edge_idx];
                    const new_distance = @as(u64, u.distance) + edge.distance;
                    const new_elevation = u.elevation + @as(i32, edge.elev_gain) - @as(i32, edge.elev_loss);

                    if (end_condition == .max_distance and new_distance > end_condition.max_distance) {
                        continue;
                    }

                    if (search.find(edge.v_idx)) |v| {
                        if (new_distance >= v.distance) continue;
                    }

                    std.debug.assert(new_distance <= std.math.maxInt(u32));
                    search.states[edge.v_idx] = .{
                        .distance = @intCast(new_distance),
                        .elevation = new_elevation,
                        .prev = edge.u_idx,
                        .stamp = generation,
                    };
                    try pq.push(arena.allocator(), .{ .distance = @intCast(new_distance), .idx = edge.v_idx });

                    if (new_elevation > best.elevation) {
                        best = search.states[edge.v_idx];
                        best_idx = edge.v_idx;
                    }
                }
            }

            switch (dtype) {
                .Elevation => return best.elevation,
                .Path => {
                    // Non-arena allocator
                    var path = std.ArrayList(u32).empty;
                    try path.append(allocator, best_idx);
                    var current = best;
                    while (current.prev != no_prev) {
                        const prev = current.prev;
                        try path.append(allocator, prev);
                        current = (search.find(prev) orelse unreachable).*;
                    }

                    const owned = try path.toOwnedSlice(allocator);
                    std.mem.reverse(u32, owned);
                    return .{ .indices = owned, .distance = best.distance, .elevation = best.elevation };
                },
            }
        }
    };
}

/// Generation tag handed out to every search, shared by both `Dijkstra`
/// instantiations so that recycled memory can never look like a fresh state.
/// Zero is skipped: memory that was never written reads as zero.
var search_generation = std.atomic.Value(u32).init(0x9e37_79b9);

fn nextSearchGeneration() u32 {
    const generation = search_generation.fetchAdd(1, .monotonic) +% 1;
    return if (generation == 0) 1 else generation;
}

pub const PathDetails = struct {
    indices: []u32,
    distance: i64,
    elevation: i32,
};

// ======================================== Tests ========================================

/// Minimal in-memory graph builder for the tests. Edges are laid out exactly the
/// way `DynamicGraph.fromReader` lays them out: one directed record per
/// direction, plus a per-node list of outgoing edge indices.
const TestGraph = struct {
    node_count: usize,
    edges: std.ArrayList(s.Edge),
    outgoing: std.ArrayList(std.ArrayList(u32)),

    fn init(allocator: std.mem.Allocator, node_count: usize) !TestGraph {
        var self = TestGraph{
            .node_count = node_count,
            .edges = .empty,
            .outgoing = .empty,
        };
        try self.outgoing.ensureTotalCapacity(allocator, node_count);
        for (0..node_count) |_| try self.outgoing.append(allocator, .empty);
        return self;
    }

    fn deinit(self: *TestGraph, allocator: std.mem.Allocator) void {
        for (self.outgoing.items) |*node_edges| node_edges.deinit(allocator);
        self.outgoing.deinit(allocator);
        self.edges.deinit(allocator);
    }

    /// Adds an edge that can be walked in both directions.
    fn connect(self: *TestGraph, allocator: std.mem.Allocator, u: u32, v: u32, gain: u16, loss: u16, distance: u32) !void {
        std.debug.assert(u < self.node_count and v < self.node_count);
        try self.addDirected(allocator, u, v, gain, loss, distance);
        try self.addDirected(allocator, v, u, loss, gain, distance);
    }

    fn addDirected(self: *TestGraph, allocator: std.mem.Allocator, u: u32, v: u32, gain: u16, loss: u16, distance: u32) !void {
        const edge_idx: u32 = @intCast(self.edges.items.len);
        try self.edges.append(allocator, .{
            .u_idx = u,
            .v_idx = v,
            .elev_gain = gain,
            .elev_loss = loss,
            .distance = distance,
        });
        try self.outgoing.items[u].append(allocator, edge_idx);
    }

    fn elevation(self: *TestGraph, allocator: std.mem.Allocator, start: u32, end_condition: EndCondition) !i64 {
        return Dijkstra(.Elevation).run(allocator, start, end_condition, self.edges.items, self.outgoing.items);
    }

    fn path(self: *TestGraph, allocator: std.mem.Allocator, start: u32, end_condition: EndCondition) !PathDetails {
        return Dijkstra(.Path).run(allocator, start, end_condition, self.edges.items, self.outgoing.items);
    }
};

test "solve: dijkstra honours the distance limit" {
    const testing = std.testing;
    var g = try TestGraph.init(testing.allocator, 4);
    defer g.deinit(testing.allocator);
    // 0 <-> 1 <-> 2 <-> 3, 100 m per hop, climbing 10 m, 20 m and 5 m.
    try g.connect(testing.allocator, 0, 1, 10, 0, 100);
    try g.connect(testing.allocator, 1, 2, 20, 0, 100);
    try g.connect(testing.allocator, 2, 3, 5, 0, 100);

    // 50 m only reaches the start node itself.
    try testing.expectEqual(@as(i64, 0), try g.elevation(testing.allocator, 0, .{ .max_distance = 50 }));

    // 250 m reaches node 2 (200 m) but not node 3 (300 m).
    try testing.expectEqual(@as(i64, 30), try g.elevation(testing.allocator, 0, .{ .max_distance = 250 }));

    const path = try g.path(testing.allocator, 0, .{ .max_distance = 250 });
    defer testing.allocator.free(path.indices);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, path.indices);
    try testing.expectEqual(@as(i64, 200), path.distance);
    try testing.expectEqual(@as(i32, 30), path.elevation);

    // An edge that lands exactly on the limit can still be walked.
    try testing.expectEqual(@as(i64, 35), try g.elevation(testing.allocator, 0, .{ .max_distance = 300 }));
}

test "solve: dijkstra never reports an elevation below the start" {
    const testing = std.testing;
    var g = try TestGraph.init(testing.allocator, 2);
    defer g.deinit(testing.allocator);
    // Walking to node 1 descends 50 m.
    try g.connect(testing.allocator, 0, 1, 0, 50, 100);

    try testing.expectEqual(@as(i64, 0), try g.elevation(testing.allocator, 0, .{ .max_distance = 1_000 }));

    const path = try g.path(testing.allocator, 0, .{ .max_distance = 1_000 });
    defer testing.allocator.free(path.indices);
    try testing.expectEqualSlices(u32, &.{0}, path.indices);
    try testing.expectEqual(@as(i64, 0), path.distance);
    try testing.expectEqual(@as(i32, 0), path.elevation);
}

test "solve: dijkstra expands nodes with their best distance" {
    const testing = std.testing;
    var g = try TestGraph.init(testing.allocator, 4);
    defer g.deinit(testing.allocator);
    // 0 -> 1 costs 20 m, 0 -> 2 -> 1 costs 15 m. Node 3 is only inside a 25 m
    // budget if node 1 is expanded with the improved 15 m distance.
    try g.connect(testing.allocator, 0, 1, 0, 0, 20);
    try g.connect(testing.allocator, 0, 2, 0, 0, 10);
    try g.connect(testing.allocator, 2, 1, 0, 0, 5);
    try g.connect(testing.allocator, 1, 3, 100, 0, 10);

    try testing.expectEqual(@as(i64, 100), try g.elevation(testing.allocator, 0, .{ .max_distance = 25 }));

    const path = try g.path(testing.allocator, 0, .{ .max_distance = 25 });
    defer testing.allocator.free(path.indices);
    try testing.expectEqualSlices(u32, &.{ 0, 2, 1, 3 }, path.indices);
    try testing.expectEqual(@as(i64, 25), path.distance);
    try testing.expectEqual(@as(i32, 100), path.elevation);
}

test "solve: dijkstra stops at the first node above the elevation target" {
    const testing = std.testing;
    var g = try TestGraph.init(testing.allocator, 4);
    defer g.deinit(testing.allocator);
    try g.connect(testing.allocator, 0, 1, 10, 0, 100);
    try g.connect(testing.allocator, 1, 2, 20, 0, 100);
    try g.connect(testing.allocator, 2, 3, 5, 0, 100);

    try testing.expectEqual(@as(i64, 30), try g.elevation(testing.allocator, 0, .{ .at_least_elevation = 25 }));

    const path = try g.path(testing.allocator, 0, .{ .at_least_elevation = 25 });
    defer testing.allocator.free(path.indices);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, path.indices);
    try testing.expectEqual(@as(i64, 200), path.distance);
    try testing.expectEqual(@as(i32, 30), path.elevation);
}

test "solve: dijkstra from a node without edges" {
    const testing = std.testing;
    var g = try TestGraph.init(testing.allocator, 3);
    defer g.deinit(testing.allocator);
    try g.connect(testing.allocator, 1, 2, 50, 0, 100);

    try testing.expectEqual(@as(i64, 0), try g.elevation(testing.allocator, 0, .{ .max_distance = 1_000 }));

    const path = try g.path(testing.allocator, 0, .{ .max_distance = 1_000 });
    defer testing.allocator.free(path.indices);
    try testing.expectEqualSlices(u32, &.{0}, path.indices);
    try testing.expectEqual(@as(i64, 0), path.distance);
}

test "solve: dijkstra is deterministic" {
    const testing = std.testing;
    const node_count: u32 = 512;
    var g = try TestGraph.init(testing.allocator, node_count);
    defer g.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x2117_4a11);
    const rand = prng.random();

    // A connected backbone plus pseudo-random shortcuts, so that the search has
    // plenty of equally short alternatives for the queue to order.
    for (0..node_count - 1) |i| {
        try g.connect(
            testing.allocator,
            @intCast(i),
            @intCast(i + 1),
            rand.intRangeAtMost(u16, 0, 200),
            rand.intRangeAtMost(u16, 0, 200),
            rand.intRangeAtMost(u32, 10, 40),
        );
    }
    for (0..node_count * 3) |_| {
        const u = rand.intRangeLessThan(u32, 0, node_count);
        const v = rand.intRangeLessThan(u32, 0, node_count);
        if (u == v) continue;
        try g.connect(
            testing.allocator,
            u,
            v,
            rand.intRangeAtMost(u16, 0, 200),
            rand.intRangeAtMost(u16, 0, 200),
            rand.intRangeAtMost(u32, 10, 400),
        );
    }

    const start: u32 = 3;
    const condition: EndCondition = .{ .max_distance = 2_000 };
    const expected_elevation = try g.elevation(testing.allocator, start, condition);
    const expected_path = try g.path(testing.allocator, start, condition);
    defer testing.allocator.free(expected_path.indices);

    // Both entry points optimise for the same thing.
    try testing.expectEqual(@as(i64, expected_path.elevation), expected_elevation);

    for (0..8) |_| {
        try testing.expectEqual(expected_elevation, try g.elevation(testing.allocator, start, condition));

        const path = try g.path(testing.allocator, start, condition);
        defer testing.allocator.free(path.indices);
        try testing.expectEqualSlices(u32, expected_path.indices, path.indices);
        try testing.expectEqual(expected_path.distance, path.distance);
        try testing.expectEqual(expected_path.elevation, path.elevation);
    }
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

const DijkstraTestType = enum {
    HighestPath,
    HighestInt,
};

fn GenBenchDijkstra(comptime dtype: DijkstraTestType, comptime node_idx: u32, comptime g: *const graph.DynamicGraph) type {
    switch (dtype) {
        .HighestPath => {
            return struct {
                fn run(allocator: std.mem.Allocator) void {
                    const result = Dijkstra(.Path).run(
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
        .HighestInt => {
            return struct {
                fn run(allocator: std.mem.Allocator) void {
                    _ = Dijkstra(.Elevation).run(
                        allocator,
                        node_idx,
                        .{ .max_distance = 1_000 },
                        g.edges.items,
                        g.node_edges.items,
                    ) catch @panic("dijkstra2 failed");
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

    bench_g = try loadBenchGraph(arena.allocator(), testing.io);

    var bench = zbench.Benchmark.init(testing.allocator, .{});
    defer bench.deinit();

    const target = comptime blk: {
        var prng = std.Random.DefaultPrng.init(0);
        const rand = prng.random();
        break :blk rand.intRangeAtMost(u32, 0, 10000);
    };

    // ======== Setup done ========

    const Bench1 = GenBenchDijkstra(.HighestPath, target, &bench_g);
    try bench.add("Benchmark path determining Dijkstra", Bench1.run, .{ .track_allocations = true });

    const Bench2 = GenBenchDijkstra(.HighestInt, target, &bench_g);
    try bench.add("Benchmark peak finder Dijkstra (new impl)", Bench2.run, .{ .track_allocations = true });

    try bench.run(testing.io, std.Io.File.stderr());
}

// =================== Deterministic benchmark ===================

const bench_graph_path = "data/switzerland_walkable.zl";

/// One-time graph load. The arena-backed allocator keeps the 190 MB parse
/// quick; the debug `testing.allocator` makes it take tens of seconds.
fn loadBenchGraph(allocator: std.mem.Allocator, io: std.Io) !graph.DynamicGraph {
    const file = try std.Io.Dir.cwd().openFile(io, bench_graph_path, .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [1 << 18]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return graph.DynamicGraph.fromReader(allocator, &reader.interface);
}

/// Deterministic workload. Every knob is a comptime constant so that
/// consecutive runs measure exactly the same work.
const BenchWorkload = struct {
    /// Short walk: the search stays in the neighbourhood of the start node.
    const local_distance: u32 = 1_000;
    const local_starts: usize = 128;
    /// Long walk: the search spills over a large part of the graph.
    const regional_distance: u32 = 10_000;
    const regional_starts: usize = 8;
    /// Timed repetitions per start node. Each start node contributes the median
    /// of its repetitions, so one disturbed repetition cannot move the metric.
    const repetitions: usize = 5;
    /// Start nodes whose returned path is audited before measuring.
    const audited_starts: usize = 4;
};

/// Allocator wrapper recording how many bytes the code under test asks for.
/// The count is reset before every timed run.
const CountingAllocator = struct {
    parent: std.mem.Allocator,
    bytes: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.bytes += len;
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.parent.vtable.resize(self.parent.ptr, memory, alignment, new_len, ret_addr)) return false;
        if (new_len > memory.len) self.bytes += new_len - memory.len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.parent.vtable.remap(self.parent.ptr, memory, alignment, new_len, ret_addr);
        if (result != null and new_len > memory.len) self.bytes += new_len - memory.len;
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ret_addr);
    }
};

const Timed = struct {
    ns: u64,
    elevation: i64,
};

fn runTimed(
    comptime dtype: DijkstraReturn,
    allocator: std.mem.Allocator,
    io: std.Io,
    start_idx: u32,
    max_distance: u32,
    g: *const graph.DynamicGraph,
) !Timed {
    const condition: EndCondition = .{ .max_distance = max_distance };
    const begin = std.Io.Clock.awake.now(io).nanoseconds;
    const elevation: i64 = switch (dtype) {
        .Elevation => try Dijkstra(.Elevation).run(allocator, start_idx, condition, g.edges.items, g.node_edges.items),
        .Path => blk: {
            const details = try Dijkstra(.Path).run(allocator, start_idx, condition, g.edges.items, g.node_edges.items);
            defer allocator.free(details.indices);
            break :blk details.elevation;
        },
    };
    const end = std.Io.Clock.awake.now(io).nanoseconds;
    return .{ .ns = @intCast(end - begin), .elevation = elevation };
}

/// Picks `count` start nodes spread over the whole graph from a fixed seed.
fn benchStarts(allocator: std.mem.Allocator, node_count: usize, count: usize, seed: u64) ![]u32 {
    const starts = try allocator.alloc(u32, count);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    for (starts) |*start| start.* = rand.intRangeLessThan(u32, 0, @intCast(node_count));
    return starts;
}

/// Mean per-start cost in microseconds, taking the median of the repetitions of
/// each start node before averaging.
fn perOpUs(samples: []const u64, start_count: usize) f64 {
    const reps = BenchWorkload.repetitions;
    var sorted: [reps]u64 = undefined;
    var total: u64 = 0;
    for (0..start_count) |i| {
        for (0..reps) |rep| sorted[rep] = samples[rep * start_count + i];
        std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
        total += sorted[reps / 2];
    }
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(start_count * std.time.ns_per_us));
}

fn mixChecksum(acc: u32, elevation: i64) u32 {
    const bits: u32 = @truncate(@as(u64, @bitCast(elevation)));
    return acc *% 0x0100_0193 ^ bits;
}

fn findEdge(g: *const graph.DynamicGraph, u: u32, v: u32) ?s.Edge {
    for (g.node_edges.items[u].items) |edge_idx| {
        const edge = g.edges.items[edge_idx];
        if (edge.v_idx == v) return edge;
    }
    return null;
}

const PathAudit = struct {
    distance_mismatches: u32 = 0,
    elevation_mismatches: u32 = 0,
};

/// Audits a returned path against the graph: every hop must be a real edge and
/// the walk must fit the budget. The reported totals come from the relaxation
/// that produced the best node, while the indices are rebuilt from the final
/// search state, so disagreements are counted rather than asserted: they mean
/// the reported totals describe a walk that is no longer the one returned.
fn auditPath(
    allocator: std.mem.Allocator,
    g: *const graph.DynamicGraph,
    start_idx: u32,
    max_distance: u32,
) !PathAudit {
    const testing = std.testing;
    const condition: EndCondition = .{ .max_distance = max_distance };
    const details = try Dijkstra(.Path).run(allocator, start_idx, condition, g.edges.items, g.node_edges.items);
    defer allocator.free(details.indices);

    try testing.expect(details.indices.len > 0);
    try testing.expectEqual(start_idx, details.indices[0]);
    try testing.expect(details.distance <= max_distance);

    var walked_distance: u64 = 0;
    var walked_elevation: i64 = 0;
    for (details.indices[0 .. details.indices.len - 1], details.indices[1..]) |from, to| {
        const edge = findEdge(g, from, to) orelse return error.PathNotConnected;
        walked_distance += edge.distance;
        walked_elevation += @as(i64, edge.elev_gain) - @as(i64, edge.elev_loss);
    }

    try testing.expect(walked_distance <= max_distance);

    return .{
        .distance_mismatches = @intFromBool(walked_distance != details.distance),
        .elevation_mismatches = @intFromBool(walked_elevation != details.elevation),
    };
}

const RegimeStats = struct {
    peak_us: f64,
    path_us: f64,
    alloc_bytes: usize,
    checksum: u32,
    audit: PathAudit,

    fn totalUs(stats: RegimeStats) f64 {
        return stats.peak_us + stats.path_us;
    }
};

/// Runs the same workload `repetitions` times over a fixed set of start nodes
/// and reports per-run microseconds. Every repetition must produce bit-identical
/// results, and the two entry points must agree on the elevation they return.
fn measureRegime(
    allocator: std.mem.Allocator,
    io: std.Io,
    g: *const graph.DynamicGraph,
    starts: []const u32,
    max_distance: u32,
    counter: *CountingAllocator,
) !RegimeStats {
    const reps = BenchWorkload.repetitions;
    const peak_ns = try allocator.alloc(u64, starts.len * reps);
    defer allocator.free(peak_ns);
    const path_ns = try allocator.alloc(u64, starts.len * reps);
    defer allocator.free(path_ns);

    var audit = PathAudit{};
    for (starts[0..@min(BenchWorkload.audited_starts, starts.len)]) |start_idx| {
        const result = try auditPath(allocator, g, start_idx, max_distance);
        audit.distance_mismatches += result.distance_mismatches;
        audit.elevation_mismatches += result.elevation_mismatches;
    }

    var alloc_bytes: usize = 0;
    var checksum: u32 = 0;

    for (0..reps) |rep| {
        var repetition_checksum: u32 = 0;
        for (starts, 0..) |start_idx, i| {
            counter.bytes = 0;
            const peak = try runTimed(.Elevation, allocator, io, start_idx, max_distance, g);
            peak_ns[rep * starts.len + i] = peak.ns;
            alloc_bytes = @max(alloc_bytes, counter.bytes);

            counter.bytes = 0;
            const path = try runTimed(.Path, allocator, io, start_idx, max_distance, g);
            path_ns[rep * starts.len + i] = path.ns;
            alloc_bytes = @max(alloc_bytes, counter.bytes);

            try std.testing.expectEqual(peak.elevation, path.elevation);
            repetition_checksum = mixChecksum(repetition_checksum, peak.elevation);
            repetition_checksum = mixChecksum(repetition_checksum, path.elevation);
        }

        if (rep == 0) {
            checksum = repetition_checksum;
        } else {
            try std.testing.expectEqual(checksum, repetition_checksum);
        }
    }

    return .{
        .peak_us = perOpUs(peak_ns, starts.len),
        .path_us = perOpUs(path_ns, starts.len),
        .alloc_bytes = alloc_bytes,
        .checksum = checksum,
        .audit = audit,
    };
}

test "solve: benchmark dijkstra" {
    // The workload is far too slow to be meaningful outside of a release build.
    if (builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall) return error.SkipZigTest;

    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const g = try loadBenchGraph(arena.allocator(), io);

    var counter = CountingAllocator{ .parent = std.heap.smp_allocator };
    const allocator = counter.allocator();

    const local_starts = try benchStarts(arena.allocator(), g.nodes.items.len, BenchWorkload.local_starts, 0x5eed_0001);
    const regional_starts = try benchStarts(arena.allocator(), g.nodes.items.len, BenchWorkload.regional_starts, 0x5eed_0002);

    const local = try measureRegime(allocator, io, &g, local_starts, BenchWorkload.local_distance, &counter);
    const regional = try measureRegime(allocator, io, &g, regional_starts, BenchWorkload.regional_distance, &counter);

    const local_us = local.totalUs();
    const regional_us = regional.totalUs();
    const distance_mismatches = local.audit.distance_mismatches + regional.audit.distance_mismatches;
    const elevation_mismatches = local.audit.elevation_mismatches + regional.audit.elevation_mismatches;

    // The leading newline keeps the first line separate from the test runner's
    // progress line, which is written without a trailing newline.
    std.debug.print("\nMETRIC dijkstra_local_peak_us={d:.3}\n", .{local.peak_us});
    std.debug.print("METRIC dijkstra_local_path_us={d:.3}\n", .{local.path_us});
    std.debug.print("METRIC dijkstra_regional_peak_us={d:.3}\n", .{regional.peak_us});
    std.debug.print("METRIC dijkstra_regional_path_us={d:.3}\n", .{regional.path_us});
    std.debug.print("METRIC dijkstra_local_us={d:.3}\n", .{local_us});
    std.debug.print("METRIC dijkstra_regional_us={d:.3}\n", .{regional_us});
    // Primary metric: geometric mean of the two regimes, so that both the short
    // and the long walk carry the same relative weight.
    std.debug.print("METRIC dijkstra_us={d:.3}\n", .{@sqrt(local_us * regional_us)});
    std.debug.print("METRIC dijkstra_alloc_bytes={d}\n", .{@max(local.alloc_bytes, regional.alloc_bytes)});
    std.debug.print("METRIC dijkstra_local_checksum={d}\n", .{local.checksum});
    std.debug.print("METRIC dijkstra_regional_checksum={d}\n", .{regional.checksum});
    std.debug.print("METRIC dijkstra_path_distance_mismatches={d}\n", .{distance_mismatches});
    std.debug.print("METRIC dijkstra_path_elevation_mismatches={d}\n", .{elevation_mismatches});
}
