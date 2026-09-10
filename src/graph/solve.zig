const std = @import("std");
const s = @import("shared.zig");

pub const Coord = struct {
    lat: f64,
    lon: f64,
};

pub const PathState = struct {
    distance: i64,
    elevation: i32,
    path: []u32,
};

fn comparePath(_: bool, a: PathState, b: PathState) std.math.Order {
    return std.math.order(a.elevation, b.elevation);
}

const MaxState = struct {
    distance: i64,
    elevation: i32,
    prev: ?u32,
    path_len: usize,
};

const IndexedMaxState = struct { ms: MaxState, last_v_idx: u32 };

fn compareIndexedMaxState(_: bool, a: IndexedMaxState, b: IndexedMaxState) std.math.Order {
    return std.math.order(a.ms.elevation, b.ms.elevation);
}

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
    max_results: []?PathState,
) !usize {
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

    // lower values are first, to allow for efficient popping
    var results = std.PriorityQueue(PathState, bool, comparePath).empty;
    defer results.deinit(allocator);
    {
        const search_progress = progress.start("searching from close nodes", close.items.len);
        defer search_progress.end();

        const DijkstraResult = @typeInfo(@TypeOf(dijkstra)).@"fn".return_type.?;

        var futures = try allocator.alloc(std.Io.Future(DijkstraResult), close.items.len);
        defer allocator.free(futures);
        for (close.items, 0..) |c, i| {
            futures[i] = io.async(dijkstra, .{ allocator, c, max_distance_m, nodes, edges, outgoing, max_results.len });
            search_progress.completeOne();
        }
        for (futures) |*f| {
            const node_results: []PathState = try f.await(io);
            defer allocator.free(node_results);

            for (node_results) |r| {
                try results.push(allocator, r);
                if (results.count() > max_results.len) {
                    if (results.pop()) |old_path| {
                        allocator.free(old_path.path);
                    }
                }
            }
        }
    }

    for (results.items, 0..) |r, i| {
        max_results[i] = r;
    }
    return results.items.len;
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
    max_results_len: usize,
) ![]PathState {
    var pq = std.PriorityQueue(u32, []const s.Node, compareForMaxElev).initContext(nodes);
    defer pq.deinit(allocator);
    try pq.push(allocator, start);

    // lower values are first, to allow for efficient popping
    var results = std.PriorityQueue(IndexedMaxState, bool, compareIndexedMaxState).empty;
    defer results.deinit(allocator);

    // Goal: minimize distance, maximize elevation
    var visited = try allocator.alloc(?MaxState, nodes.len);
    @memset(visited, null);
    defer allocator.free(visited);
    visited[start] = MaxState{ .distance = 0, .elevation = 0, .prev = null, .path_len = 1 };

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
                if (new_ratio <= old_ratio) {
                    continue;
                }
            }

            const state = MaxState{
                .distance = new_distance,
                .elevation = new_elevation,
                .prev = current,
                .path_len = cur_count.path_len + 1,
            };
            visited[edge.v_idx] = state;
            try pq.push(allocator, edge.v_idx);
            try results.push(allocator, .{ .ms = state, .last_v_idx = edge.v_idx });
            if (results.count() > max_results_len) {
                _ = results.pop();
            }
        }
    }

    const res = try allocator.alloc(PathState, results.count());
    for (results.items, 0..) |r, i| {
        var path = try allocator.alloc(u32, r.ms.path_len);
        path[r.ms.path_len - 1] = r.last_v_idx;

        var idx: usize = r.ms.path_len - 1;
        var prev_opt = r.ms.prev;
        while (prev_opt) |p| {
            if (idx == 0) break;
            idx -= 1;
            path[idx] = p;
            if (visited[p]) |new_state| {
                prev_opt = new_state.prev;
            } else {
                break;
            }
        }

        res[i] = .{
            .distance = r.ms.distance,
            .elevation = r.ms.elevation,
            .path = path,
        };
    }
    return res;
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

pub fn writeGpx(io: std.Io, path: []const u8, name: []const u8, nodes: []const s.Node, c: PathState) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
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
        c.path.len,
    });

    for (c.path) |node_id| {
        const n = nodes[node_id];
        if (n.elev) |ele| {
            try out.print("<trkpt lat=\"{d:.7}\" lon=\"{d:.7}\"><ele>{d}</ele></trkpt>\n", .{ n.lat, n.lon, ele });
        } else {
            try out.print("<trkpt lat=\"{d:.7}\" lon=\"{d:.7}\"/>\n", .{ n.lat, n.lon });
        }
    }

    try out.print("</trkseg>\n</trk>\n</gpx>\n", .{});
    try out.flush();

    std.debug.print("wrote {s} with elev {d}m, dist {d}m, {d} pts\n", .{ path, c.elevation, c.distance, c.path.len });
}
