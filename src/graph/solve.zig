const std = @import("std");
const s = @import("shared.zig");

pub const Coord = struct {
    lat: f64,
    lon: f64,
};

pub fn findMax(
    allocator: std.mem.Allocator,
    io: std.Io,
    progress: std.Progress.Node,
    from: Coord,
    max_radius_m: f64,
    max_distance_m: i64,
    nodes: []const s.Node,
    edges: []const s.Edge,
    outgoing: []std.ArrayList(u32),
) !void {
    var close = std.ArrayList(u32).empty;
    defer close.deinit(allocator);

    {
        const close_progress = progress.start("checking close nodes", nodes.len);
        defer close_progress.end();
        for (nodes, 0..) |n, i| {
            const dist = haversineMeters(from, .{ .lat = n.lat, .lon = n.lon });
            if (dist <= max_radius_m) {
                try close.append(allocator, @intCast(i));
            }
            close_progress.completeOne();
        }
    }

    {
        const search_progress = progress.start("searching from close nodes", close.items.len);
        defer search_progress.end();

        const DijkstraResult = @typeInfo(@TypeOf(dijkstra)).@"fn".return_type.?;

        var futures = try allocator.alloc(std.Io.Future(DijkstraResult), close.items.len);
        defer allocator.free(futures);
        for (close.items, 0..) |c, i| {
            futures[i] = io.async(dijkstra, .{ allocator, c, max_distance_m, nodes, edges, outgoing });
            search_progress.completeOne();
        }
        for (futures) |*f| {
            try f.await(io);
        }
    }
}

fn compareForMaxElev(nodes: []const s.Node, a: u32, b: u32) std.math.Order {
    // higher elev => lower on prioq
    const node_a = nodes[a];
    const node_b = nodes[b];

    if (node_a.elev == null and node_b.elev == null) return .eq;
    if (node_a.elev == null) return .gt;
    if (node_b.elev == null) return .lt;

    if (node_a.elev.? < node_b.elev.?) return .gt;
    if (node_a.elev.? > node_b.elev.?) return .lt;
    return .eq;
}

fn dijkstra(
    allocator: std.mem.Allocator,
    start: u32,
    max_distance: i64,
    nodes: []const s.Node,
    edges: []const s.Edge,
    outgoing: []std.ArrayList(u32),
) !void {
    var pq = std.PriorityQueue(u32, []const s.Node, compareForMaxElev).initContext(nodes);
    defer pq.deinit(allocator);
    try pq.push(allocator, start);

    // Goal: minimize distance, maximize elevation
    const MaxState = struct {
        distance: i64,
        elevation: i32,
        prev: ?u32,
    };
    var visited = try allocator.alloc(?MaxState, nodes.len);
    @memset(visited, null);
    defer allocator.free(visited);

    visited[start] = MaxState{ .distance = 0, .elevation = 0, .prev = null };

    while (pq.pop()) |current| {
        const cur_count = visited[current] orelse continue;
        for (outgoing[current].items) |out| {
            const edge = edges[out];
            const out_count = visited[edge.v_idx];

            const new_distance = cur_count.distance + edge.distance;
            if (new_distance == 0) continue;
            if (new_distance > max_distance) continue;

            const new_elevation = cur_count.elevation + edge.elev_gain - edge.elev_loss;
            if (out_count) |c| {
                const new_ratio = @divTrunc(new_elevation, new_distance);
                if (c.distance == 0) continue;
                const old_ratio = @divTrunc(c.elevation, c.distance);
                if (new_ratio > old_ratio) {
                    visited[edge.v_idx] = .{
                        .distance = new_distance,
                        .elevation = new_elevation,
                        .prev = current,
                    };
                    try pq.push(allocator, edge.v_idx);
                }
            } else {
                visited[edge.v_idx] = .{
                    .distance = new_distance,
                    .elevation = new_elevation,
                    .prev = current,
                };
                try pq.push(allocator, edge.v_idx);
            }
        }
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
