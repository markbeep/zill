const std = @import("std");
const s = @import("shared.zig");
const solve = @import("solve.zig");
const dedup = @import("dedup.zig");

/// A "route" that gains less than this is a segment, not a climb: without a
/// floor, a list of N results fills up with 50 m stubs from dead-end nodes.
pub const MIN_CLIMB_GAIN_M: i64 = 50;

/// When nothing in the pool can climb at all - a small or flat area - the floor
/// would answer with an empty list. The strongest lines the distance allows are
/// ranked anyway, however little they rise: the visitor asked about that patch
/// of ground and deserves to see what is on it. Dead-flat is still nothing.
pub const FALLBACK_GAIN_M: i64 = 1;

/// Progressive version of the CLI's search: instead of returning only the final
/// ranking, it walks the start nodes in chunks and republishes the strongest
/// set of *distinct* routes it has seen so far after every chunk. That is what
/// lets a browser draw climbs while the algorithm is still running.
pub fn Engine(comptime G: type) type {
    return struct {
        const Self = @This();

        pub const Route = struct {
            start_idx: u32,
            elevation: i64,
            distance: i64,
            /// Path nodes from start to summit; owned by the engine.
            points: []u32,
        };

        pub const Stats = struct {
            scanned: u32,
            total: u32,
            /// Candidates that got a full path computed.
            considered: u32,
            accepted: u32,
            /// Candidates dropped because they overlap an accepted route.
            suppressed: u32,
            best_elevation: i64,
            finished: bool,
            /// Bumped whenever the accepted set changes, so a UI knows to refetch.
            revision: u32,
        };

        const Candidate = struct {
            idx: u32,
            elevation: i64,
            /// Elevation this candidate was last evaluated at; it is only
            /// re-evaluated when it improves.
            evaluated: ?i64 = null,
        };

        fn candidateOrder(_: void, a: Candidate, b: Candidate) std.math.Order {
            return std.math.order(a.elevation, b.elevation);
        }

        fn descending(_: void, a: Candidate, b: Candidate) bool {
            return a.elevation > b.elevation;
        }

        allocator: std.mem.Allocator,
        graph: G,
        starts: []const u32,
        end_condition: solve.EndCondition,
        max_results: usize,
        threshold: f64,

        heap: std.PriorityQueue(Candidate, void, candidateOrder),
        scratch: std.ArrayList(Candidate),
        accepted: std.ArrayList(Route),
        dedup_scratch: dedup.Scratch,

        next: u32 = 0,
        considered: u32 = 0,
        suppressed: u32 = 0,
        revision: u32 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            graph: G,
            starts: []const u32,
            end_condition: solve.EndCondition,
            max_results: usize,
            threshold: f64,
        ) !Self {
            const cap = @max(64, max_results * 16);
            var heap = std.PriorityQueue(Candidate, void, candidateOrder).empty;
            try heap.ensureTotalCapacity(allocator, cap);
            return .{
                .allocator = allocator,
                .graph = graph,
                .starts = starts,
                .end_condition = end_condition,
                .max_results = @max(1, max_results),
                .threshold = threshold,
                .heap = heap,
                .scratch = std.ArrayList(Candidate).empty,
                .accepted = std.ArrayList(Route).empty,
                .dedup_scratch = dedup.Scratch.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.accepted.items) |route| self.allocator.free(route.points);
            self.accepted.deinit(self.allocator);
            self.scratch.deinit(self.allocator);
            self.heap.deinit(self.allocator);
            self.dedup_scratch.deinit();
            self.* = undefined;
        }

        pub fn routes(self: *const Self) []const Route {
            return self.accepted.items;
        }

        pub fn stats(self: *const Self) Stats {
            const best: i64 = if (self.accepted.items.len == 0) 0 else self.accepted.items[0].elevation;
            return .{
                .scanned = self.next,
                .total = @intCast(self.starts.len),
                .considered = self.considered,
                .accepted = @intCast(self.accepted.items.len),
                .suppressed = self.suppressed,
                .best_elevation = best,
                .finished = self.next >= self.starts.len,
                .revision = self.revision,
            };
        }

        /// Runs the maximum-elevation search for up to `budget` more start
        /// nodes, then republishes. Returns true while start nodes are left.
        pub fn step(self: *Self, budget: u32) !bool {
            const cap = self.heap.cap;
            const end = @min(self.starts.len, @as(usize, self.next) + budget);
            while (self.next < @as(u32, @intCast(end))) : (self.next += 1) {
                const start_idx = self.starts[self.next];
                const elevation = try solve.Dijkstra(.Elevation).run(self.allocator, self.graph, start_idx, self.end_condition);

                if (self.heap.count() < cap) {
                    try self.heap.push(self.allocator, .{ .idx = start_idx, .elevation = elevation });
                } else if (self.heap.peek().?.elevation < elevation) {
                    _ = self.heap.pop();
                    try self.heap.push(self.allocator, .{ .idx = start_idx, .elevation = elevation });
                }
            }

            try self.publish();
            return self.next < self.starts.len;
        }

        /// Re-ranks the candidate pool and publishes any route that is both
        /// stronger than the weakest accepted one and not a duplicate of the
        /// routes kept above it.
        fn publish(self: *Self) !void {
            self.scratch.clearRetainingCapacity();
            try self.scratch.appendSlice(self.allocator, self.heap.items[0..self.heap.count()]);
            std.mem.sort(Candidate, self.scratch.items, {}, descending);
            // Sorted descending, so the head of the pool is the best this area
            // can do. If even that is below the floor, the floor is off.
            const floor: i64 = if (self.scratch.items.len > 0 and self.scratch.items[0].elevation < MIN_CLIMB_GAIN_M)
                FALLBACK_GAIN_M
            else
                MIN_CLIMB_GAIN_M;

            for (self.scratch.items) |cand| {
                const weakest: i64 = if (self.accepted.items.len >= self.max_results)
                    self.accepted.items[self.accepted.items.len - 1].elevation
                else
                    std.math.minInt(i64);
                if (cand.elevation <= weakest) break;
                if (cand.evaluated) |evaluated| {
                    if (evaluated >= cand.elevation) continue;
                }

                const details = try solve.Dijkstra(.Path).run(self.allocator, self.graph, cand.idx, self.end_condition);
                self.considered += 1;
                self.markEvaluated(cand.idx, cand.elevation);

                // A start node whose best "route" is itself, or less gain than
                // this area can offer: not a route, and not something to rank.
                if (details.indices.len < 2 or details.elevation < floor) {
                    self.allocator.free(details.indices);
                    continue;
                }

                var duplicate = false;
                const full = self.accepted.items.len >= self.max_results;
                for (self.accepted.items, 0..) |route, i| {
                    // The weakest accepted route is replaceable by this one.
                    if (full and i == self.accepted.items.len - 1) continue;
                    if (dedup.overlapRatio(route.points, details.indices, self.graph, &self.dedup_scratch) > self.threshold) {
                        duplicate = true;
                        break;
                    }
                }

                if (duplicate) {
                    self.suppressed += 1;
                    self.allocator.free(details.indices);
                    continue;
                }

                try self.insert(Route{
                    .start_idx = cand.idx,
                    .elevation = details.elevation,
                    .distance = details.distance,
                    .points = details.indices,
                });
                self.revision += 1;
            }
        }

        /// Keeps `accepted` ordered by descending elevation.
        fn insert(self: *Self, route: Route) !void {
            var at: usize = self.accepted.items.len;
            while (at > 0 and self.accepted.items[at - 1].elevation < route.elevation) : (at -= 1) {}
            try self.accepted.insert(self.allocator, at, route);
            while (self.accepted.items.len > self.max_results) {
                const dropped = self.accepted.pop().?;
                self.allocator.free(dropped.points);
            }
        }

        fn markEvaluated(self: *Self, idx: u32, elevation: i64) void {
            for (self.heap.items[0..self.heap.count()]) |*item| {
                if (item.idx == idx) {
                    item.evaluated = elevation;
                    return;
                }
            }
        }
    };
}

// ======================================== Tests ========================================

const testing = std.testing;

/// Two climbs 10 km apart. Each has a pair of start nodes ~11 m apart that
/// meet at a junction and share the whole climb from there, which is exactly
/// the duplication this engine has to collapse.
fn testGraph(allocator: std.mem.Allocator) !@import("dynamic.zig").DynamicGraph {
    var g = @import("dynamic.zig").DynamicGraph.init(allocator);
    errdefer g.deinit();
    const a1 = try g.addNode(1, 46.0000, 7.0000, 1000);
    const a2 = try g.addNode(2, 46.0001, 7.0000, 1000);
    const junction_a = try g.addNode(3, 46.0005, 7.0000, 1010);
    const summit_a = try g.addNode(4, 46.0176, 7.0000, 1500);
    const b1 = try g.addNode(5, 46.1000, 7.1000, 800);
    const b2 = try g.addNode(6, 46.1001, 7.1000, 800);
    const junction_b = try g.addNode(7, 46.1005, 7.1000, 810);
    const summit_b = try g.addNode(8, 46.1176, 7.1000, 1300);

    try g.addEdge(a1, junction_a, 10, 0, 50);
    try g.addEdge(a2, junction_a, 5, 0, 50); // the weaker twin of the same start
    try g.addEdge(junction_a, summit_a, 490, 0, 1900);
    try g.addEdge(b1, junction_b, 10, 0, 50);
    try g.addEdge(b2, junction_b, 5, 0, 50);
    try g.addEdge(junction_b, summit_b, 490, 0, 1900);
    return g;
}

/// A nearly flat ridge: twelve nodes each 3 m above the last, 100 m apart.
fn flatGraph(allocator: std.mem.Allocator) !@import("dynamic.zig").DynamicGraph {
    var g = @import("dynamic.zig").DynamicGraph.init(allocator);
    errdefer g.deinit();
    var previous: ?u32 = null;
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const step: f32 = @floatFromInt(i);
        const idx = try g.addNode(@intCast(i + 1), 46.0 + step * 0.001, 7.0, 1000 + step * 3);
        if (previous) |p| try g.addEdge(p, idx, 3, 0, 100);
        previous = idx;
    }
    return g;
}

/// The engine runs on the same zero-copy representation the browser loads.
/// The returned bytes stay owned by the caller and must outlive the graph.
fn LoadedGraph(comptime G: type) type {
    return struct {
        bytes: []u8,
        graph: G,

        fn init(assembled: *@import("dynamic.zig").DynamicGraph, allocator: std.mem.Allocator) !@This() {
            const bytes = try allocator.alloc(u8, s.fileSize(assembled.nodes.items.len, assembled.edges.items.len));
            errdefer allocator.free(bytes);
            var writer = std.Io.Writer.fixed(bytes);
            try assembled.exportToWriter(&writer);
            var graph = try G.init(allocator, bytes);
            errdefer graph.deinit();
            try graph.index();
            return .{ .bytes = bytes, .graph = graph };
        }

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.graph.deinit();
            allocator.free(self.bytes);
            self.* = undefined;
        }
    };
}

test "engine suppresses the twin of a climb and keeps distinct climbs" {
    const Packed = @import("packed_graph.zig").PackedGraph;
    var g = try testGraph(testing.allocator);
    defer g.deinit();
    var loaded = try LoadedGraph(Packed).init(&g, testing.allocator);
    defer loaded.deinit(testing.allocator);

    // Starts: a1, a2, b1, b2 — in graph order.
    const starts = [_]u32{ 0, 1, 4, 5 };
    var engine = try Engine(Packed).init(
        testing.allocator,
        loaded.graph,
        &starts,
        .{ .max_distance = 2000 },
        3,
        0.5,
    );
    defer engine.deinit();

    var more = true;
    while (more) more = try engine.step(2);

    const st = engine.stats();
    try testing.expectEqual(@as(u32, 4), st.scanned);
    try testing.expect(st.finished);
    // a1 and b1 are kept; a2 and b2 are the same two climbs from 11 m away.
    try testing.expectEqual(@as(u32, 2), st.accepted);
    try testing.expectEqual(@as(u32, 2), st.suppressed);

    const routes = engine.routes();
    try testing.expectEqual(@as(i64, 500), routes[0].elevation);
    try testing.expectEqual(@as(i64, 500), routes[1].elevation);
    try testing.expect(routes[0].start_idx < 2);
    try testing.expect(routes[1].start_idx >= 4);
    try testing.expectEqual(@as(usize, 3), routes[0].points.len);
    try testing.expectEqual(@as(i64, 1950), routes[0].distance);
}

test "a flat area still gets routes, ranked by what little they rise" {
    const Packed = @import("packed_graph.zig").PackedGraph;
    var g = try flatGraph(testing.allocator);
    defer g.deinit();
    var loaded = try LoadedGraph(Packed).init(&g, testing.allocator);
    defer loaded.deinit(testing.allocator);

    // Two starts on the ridge; a 1 km budget reaches about 30 m of gain, which
    // the climb floor alone would throw away as nothing.
    const starts = [_]u32{ 0, 1 };
    var engine = try Engine(Packed).init(
        testing.allocator,
        loaded.graph,
        &starts,
        .{ .max_distance = 1000 },
        10,
        0.5,
    );
    defer engine.deinit();

    var more = true;
    while (more) more = try engine.step(2);

    try testing.expect(engine.stats().finished);
    try testing.expect(engine.stats().accepted > 0);
    const routes = engine.routes();
    try testing.expect(routes[0].elevation < MIN_CLIMB_GAIN_M);
    try testing.expect(routes[0].elevation >= FALLBACK_GAIN_M);
    try testing.expect(routes[0].points.len > 2);
}

test "engine reports progress while it runs" {
    const Packed = @import("packed_graph.zig").PackedGraph;
    var g = try testGraph(testing.allocator);
    defer g.deinit();
    var loaded = try LoadedGraph(Packed).init(&g, testing.allocator);
    defer loaded.deinit(testing.allocator);

    const starts = [_]u32{ 0, 1, 4, 5 };
    var engine = try Engine(Packed).init(
        testing.allocator,
        loaded.graph,
        &starts,
        .{ .max_distance = 2000 },
        3,
        1.0, // a ratio of one means "suppress nothing"
    );
    defer engine.deinit();

    try testing.expect(try engine.step(1));
    try testing.expectEqual(@as(u32, 1), engine.stats().scanned);
    try testing.expect(!engine.stats().finished);
    try testing.expect(try engine.step(1));
    try testing.expectEqual(@as(u32, 2), engine.stats().scanned);
    try testing.expect(!try engine.step(10));
    try testing.expectEqual(@as(u32, 4), engine.stats().scanned);
    try testing.expect(engine.stats().finished);
    // Nothing is treated as a duplicate, so the list fills to max_results.
    try testing.expectEqual(@as(u32, 3), engine.stats().accepted);
    try testing.expectEqual(@as(u32, 0), engine.stats().suppressed);
    try testing.expect(engine.stats().revision > 0);
}
