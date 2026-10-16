const std = @import("std");
const s = @import("shared.zig");
const solve = @import("solve.zig");

/// One found route: node indices from start to summit, in order.
/// `path` is borrowed, the caller keeps it alive.
pub const Candidate = struct {
    start_idx: u32,
    elevation: i64,
    path: []const u32,
    distance: i64,
};

pub const Selection = struct {
    accepted: []Candidate,
    suppressed: usize,
};

pub fn defaultThreshold() f64 {
    return 0.5;
}

/// Reusable hop table for `overlapRatio`. Both the CLI and the browser call
/// this thousands of times per search, so it must not allocate in the loop.
pub const Scratch = struct {
    hops: std.ArrayList(Hop) = .empty,
    /// Node positions snapped to a `STOP_DEGREES` grid, so two routes that
    /// start 10 m apart on the same climb are the same climb even though they
    /// begin at different graph nodes.
    stops: std.AutoHashMap(u64, u32),
    next_stop: u32 = 0,
    allocator: std.mem.Allocator,

    const Hop = struct { key: u64, meters: f64 };

    pub fn init(allocator: std.mem.Allocator) Scratch {
        return .{ .allocator = allocator, .stops = std.AutoHashMap(u64, u32).init(allocator) };
    }

    pub fn deinit(self: *Scratch) void {
        self.hops.deinit(self.allocator);
        self.stops.deinit();
        self.* = undefined;
    }
};

/// ~33 m per cell. Matching looks at the cell and its eight neighbours, so a
/// pair of nodes a few metres apart counts as the same place even when a cell
/// boundary runs between them — which is the whole point of the metric.
const STOP_DEGREES: f64 = 0.0003;

fn stopOf(scratch: *Scratch, graph: anytype, idx: u32) u32 {
    const lat: f64 = graph.nodeLat(idx);
    const lon: f64 = graph.nodeLon(idx);
    const key: u64 = @as(u64, @bitCast(@as(i64, @intFromFloat(@round(lat / STOP_DEGREES))))) << 32 |
        @as(u32, @bitCast(@as(i32, @intFromFloat(@round(lon / STOP_DEGREES)))));
    const entry = scratch.stops.getOrPut(key) catch return idx;
    if (!entry.found_existing) {
        entry.value_ptr.* = scratch.next_stop;
        scratch.next_stop += 1;
    }
    return entry.value_ptr.*;
}

fn pairKey(u: u32, v: u32) u64 {
    return (@as(u64, @min(u, v)) << 32) | @max(u, v);
}

fn hopMeters(u: u32, v: u32, graph: anytype) f64 {
    return solve.haversineMeters(
        .{ .lat = graph.nodeLat(u), .lon = graph.nodeLon(u) },
        .{ .lat = graph.nodeLat(v), .lon = graph.nodeLon(v) },
    );
}

fn trackMeters(path: []const u32, graph: anytype) f64 {
    var total: f64 = 0;
    for (path[1..], path[0 .. path.len - 1]) |v, u| total += hopMeters(u, v, graph);
    return total;
}

fn hopLessThan(_: void, a: Scratch.Hop, b: Scratch.Hop) bool {
    return a.key < b.key;
}

fn findHop(hops: []const Scratch.Hop, key: u64) ?Scratch.Hop {
    var lo: usize = 0;
    var hi: usize = hops.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (hops[mid].key < key) lo = mid + 1 else hi = mid;
    }
    if (lo < hops.len and hops[lo].key == key) return hops[lo];
    return null;
}

/// Looks for the hop in the table under any neighbouring cell pair.
fn findHopNear(hops: []const Scratch.Hop, from: u32, to: u32) ?Scratch.Hop {
    // The exact cell pair first: without it, a neighbour match could shadow the
    // hop's own entry and two identical routes would score below 1.0.
    if (findHop(hops, pairKey(from, to))) |hop| return hop;
    const from_i: i64 = from;
    const to_i: i64 = to;
    var da: i64 = -1;
    while (da <= 1) : (da += 1) {
        if (from_i + da < 0) continue;
        var db: i64 = -1;
        while (db <= 1) : (db += 1) {
            if (to_i + db < 0) continue;
            const a: u32 = @intCast(from_i + da);
            const b: u32 = @intCast(to_i + db);
            if (findHop(hops, pairKey(a, b))) |hop| return hop;
        }
    }
    return null;
}

/// Share of the shorter route's distance that both routes walk, undirected.
/// 1.0 means the same track, 0.0 no shared hop. `graph` may be any type with
/// `nodeLat`/`nodeLon` — the in-memory graph or the packed one.
pub fn overlapRatio(a: []const u32, b: []const u32, graph: anytype, scratch: *Scratch) f64 {
    if (a.len < 2 or b.len < 2) return 0;
    const short = if (a.len <= b.len) a else b;
    const long = if (a.len <= b.len) b else a;

    // Under-allocation degrades to "no shared hops": routes are kept, never
    // wrongly merged, which is the safe direction for a deduplicator.
    scratch.hops.clearRetainingCapacity();
    scratch.stops.clearRetainingCapacity();
    scratch.next_stop = 0;
    scratch.hops.ensureTotalCapacity(scratch.allocator, short.len - 1) catch return 0;
    for (short[1..], short[0 .. short.len - 1]) |v, u| {
        scratch.hops.appendAssumeCapacity(.{
            .key = pairKey(stopOf(scratch, graph, u), stopOf(scratch, graph, v)),
            .meters = hopMeters(u, v, graph),
        });
    }
    std.mem.sort(Scratch.Hop, scratch.hops.items, {}, hopLessThan);

    var shared: f64 = 0;
    for (long[1..], long[0 .. long.len - 1]) |v, u| {
        if (findHopNear(scratch.hops.items, stopOf(scratch, graph, u), stopOf(scratch, graph, v))) |hop| {
            shared += hop.meters;
        }
    }

    const denom = @min(trackMeters(a, graph), trackMeters(b, graph));
    if (denom <= 0) return 0;
    return @min(1.0, shared / denom);
}

/// Keeps the highest routes that are not near-duplicates of an already kept one,
/// so many starts 10 m apart on the same climb yield one entry.
pub fn selectDiverse(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
    max_results: usize,
    threshold: f64,
    graph: anytype,
    scratch: *Scratch,
) !Selection {
    const sorted = try allocator.dupe(Candidate, candidates);
    defer allocator.free(sorted);
    std.mem.sortUnstable(Candidate, sorted, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            if (a.elevation != b.elevation) return a.elevation > b.elevation;
            return a.start_idx < b.start_idx;
        }
    }.lessThan);

    var accepted = std.ArrayList(Candidate).empty;
    errdefer accepted.deinit(allocator);
    var suppressed: usize = 0;

    for (sorted) |cand| {
        if (accepted.items.len >= max_results) break;
        if (cand.path.len < 2) {
            suppressed += 1;
            continue;
        }
        var duplicate = false;
        for (accepted.items) |kept| {
            if (overlapRatio(cand.path, kept.path, graph, scratch) > threshold) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            suppressed += 1;
        } else {
            try accepted.append(allocator, cand);
        }
    }

    return .{
        .accepted = try accepted.toOwnedSlice(allocator),
        .suppressed = suppressed,
    };
}

const testing = std.testing;
const DynamicGraph = @import("dynamic.zig").DynamicGraph;

// Lat-only separations, so haversine distances are exact metres of latitude.
// 0/1 share a ~30 m hop; 6/7/8 are a 1 km-per-hop chain; 9/10 sit on it.
const NODES = [_]s.Node{
    .{ .id = 0, .lat = 46.00000, .lon = 8.0, .elev = 400 },
    .{ .id = 1, .lat = 46.00027, .lon = 8.0, .elev = 430 },
    .{ .id = 2, .lat = 46.03000, .lon = 8.0, .elev = 900 },
    .{ .id = 3, .lat = 46.05000, .lon = 8.0, .elev = 1200 },
    .{ .id = 4, .lat = 46.03000, .lon = 8.1, .elev = 950 },
    .{ .id = 5, .lat = 46.05000, .lon = 8.2, .elev = 1300 },
    .{ .id = 6, .lat = 46.01000, .lon = 8.0, .elev = 500 },
    .{ .id = 7, .lat = 46.02000, .lon = 8.0, .elev = 600 },
    .{ .id = 8, .lat = 46.04000, .lon = 8.0, .elev = 700 },
    .{ .id = 9, .lat = 45.99000, .lon = 8.0, .elev = 300 },
    .{ .id = 10, .lat = 45.98000, .lon = 8.0, .elev = 280 },
};

fn testGraph() !DynamicGraph {
    var graph = DynamicGraph.init(testing.allocator);
    errdefer graph.deinit();
    for (NODES) |node| _ = try graph.addNode(node.id, node.lat, node.lon, @floatFromInt(node.elev.?));
    return graph;
}

test "dedup: identical paths fully overlap" {
    var graph = try testGraph();
    defer graph.deinit();
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();

    const a = [_]u32{ 0, 6, 7, 8 };
    const b = [_]u32{ 0, 6, 7, 8 };
    try testing.expectEqual(@as(f64, 1.0), overlapRatio(&a, &b, &graph, &scratch));
}

test "dedup: disjoint paths do not overlap" {
    var graph = try testGraph();
    defer graph.deinit();
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();

    const a = [_]u32{ 0, 1 };
    const b = [_]u32{ 2, 3 };
    try testing.expectEqual(@as(f64, 0.0), overlapRatio(&a, &b, &graph, &scratch));
}

test "dedup: shared tail dominates the ratio" {
    var graph = try testGraph();
    defer graph.deinit();
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();

    // Same 1 km-per-hop tail, different ~1 km and ~2 km approaches.
    const a = [_]u32{ 9, 0, 6, 7, 8 };
    const b = [_]u32{ 10, 0, 6, 7, 8 };
    const r = overlapRatio(&a, &b, &graph, &scratch);
    try testing.expect(r > 0.6 and r < 1.0);
    try testing.expectApproxEqAbs(@as(f64, 0.8), r, 0.01);
}

test "dedup: two starts in the same 33 m cell are the same climb" {
    var graph = try testGraph();
    defer graph.deinit();
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();

    // Nodes 0 and 1 are 30 m apart and share the whole climb after that.
    const a = [_]u32{ 0, 6, 7, 8 };
    const b = [_]u32{ 1, 6, 7, 8 };
    const r = overlapRatio(&a, &b, &graph, &scratch);
    try testing.expect(r > 0.9);
}

test "dedup: shared 30 m start with different tails is not a duplicate" {
    var graph = try testGraph();
    defer graph.deinit();
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();

    const a = [_]u32{ 0, 1, 2, 3 };
    const b = [_]u32{ 0, 1, 4, 5 };
    const r = overlapRatio(&a, &b, &graph, &scratch);
    try testing.expect(r > 0.0 and r < 0.5);
}

test "dedup: suppresses the lower-elevation twin of the same climb" {
    var graph = try testGraph();
    defer graph.deinit();
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();

    const p = [_]u32{ 0, 6, 7, 8 };
    const candidates = [_]Candidate{
        .{ .start_idx = 0, .elevation = 900, .path = &p, .distance = 5000 },
        .{ .start_idx = 1, .elevation = 1000, .path = &p, .distance = 5000 },
    };
    const sel = try selectDiverse(testing.allocator, &candidates, 5, defaultThreshold(), &graph, &scratch);
    defer testing.allocator.free(sel.accepted);

    try testing.expectEqual(@as(usize, 1), sel.accepted.len);
    try testing.expectEqual(@as(i64, 1000), sel.accepted[0].elevation);
    try testing.expectEqual(@as(usize, 1), sel.suppressed);
}

test "dedup: respects max_results and drops stub paths" {
    var graph = try testGraph();
    defer graph.deinit();
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();

    const p1 = [_]u32{ 0, 6, 7 };
    const p2 = [_]u32{ 1, 2, 3 };
    const p3 = [_]u32{ 4, 5 };
    const stub = [_]u32{2};
    const candidates = [_]Candidate{
        .{ .start_idx = 0, .elevation = 900, .path = &p1, .distance = 3000 },
        .{ .start_idx = 1, .elevation = 800, .path = &p2, .distance = 3000 },
        .{ .start_idx = 2, .elevation = 700, .path = &p3, .distance = 3000 },
        .{ .start_idx = 3, .elevation = 5000, .path = &stub, .distance = 0 },
    };
    const sel = try selectDiverse(testing.allocator, &candidates, 2, defaultThreshold(), &graph, &scratch);
    defer testing.allocator.free(sel.accepted);

    try testing.expectEqual(@as(usize, 2), sel.accepted.len);
    try testing.expectEqual(@as(i64, 900), sel.accepted[0].elevation);
    try testing.expectEqual(@as(i64, 800), sel.accepted[1].elevation);
    try testing.expectEqual(@as(usize, 1), sel.suppressed);
}

test "dedup: keeps genuinely different climbs" {
    var graph = try testGraph();
    defer graph.deinit();
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();

    const p1 = [_]u32{ 0, 6, 7 };
    const p2 = [_]u32{ 1, 2, 3 };
    const p3 = [_]u32{ 4, 5 };
    const candidates = [_]Candidate{
        .{ .start_idx = 0, .elevation = 900, .path = &p1, .distance = 3000 },
        .{ .start_idx = 1, .elevation = 800, .path = &p2, .distance = 3000 },
        .{ .start_idx = 2, .elevation = 700, .path = &p3, .distance = 3000 },
    };
    const sel = try selectDiverse(testing.allocator, &candidates, 5, defaultThreshold(), &graph, &scratch);
    defer testing.allocator.free(sel.accepted);

    try testing.expectEqual(@as(usize, 3), sel.accepted.len);
    try testing.expectEqual(@as(usize, 0), sel.suppressed);
}

test "dedup: equal elevations order by start_idx" {
    var graph = try testGraph();
    defer graph.deinit();
    var scratch = Scratch.init(testing.allocator);
    defer scratch.deinit();

    const p1 = [_]u32{ 0, 6, 7 };
    const p2 = [_]u32{ 1, 2, 3 };
    const candidates = [_]Candidate{
        .{ .start_idx = 9, .elevation = 1000, .path = &p1, .distance = 3000 },
        .{ .start_idx = 2, .elevation = 1000, .path = &p2, .distance = 3000 },
    };
    const sel = try selectDiverse(testing.allocator, &candidates, 5, defaultThreshold(), &graph, &scratch);
    defer testing.allocator.free(sel.accepted);

    try testing.expectEqual(@as(usize, 2), sel.accepted.len);
    try testing.expectEqual(@as(u32, 2), sel.accepted[0].start_idx);
    try testing.expectEqual(@as(u32, 9), sel.accepted[1].start_idx);
}
