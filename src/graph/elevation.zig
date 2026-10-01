const std = @import("std");

const graph = @import("graph.zig");
const s = @import("shared.zig");
const solve = @import("solve.zig");

pub const PathDetails = struct {
    distance: i64,
    elevation_gain: u32,
    elevation_loss: u32,
};

pub const EndCondition = struct {
    above_distance_m: u32,
};

pub fn compute(
    allocator: std.mem.Allocator,
    start_idx: u32,
    nodes: []const s.Node,
    edges: []const s.Edge,
    outgoing: []std.ArrayList(u32),
    end_condition: EndCondition,
) !?PathDetails {
    const StackNode = struct {
        idx: u32,
        node: std.SinglyLinkedList.Node = .{},
        distance: i64,
        elevation_gain: u16,
        elevation_loss: u16,
        prev: ?u32,
        edge_idx: u32 = 0,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var visited = std.AutoHashMap(u32, *const StackNode).init(arena.allocator());
    var initial = StackNode{ .idx = start_idx, .distance = 0, .elevation_gain = 0, .elevation_loss = 0, .prev = null };
    try visited.put(start_idx, &initial);
    var q = std.SinglyLinkedList{ .first = &initial.node };

    var in_path = std.AutoHashMap(u32, void).init(arena.allocator());

    var best: ?*const StackNode = null;

    while (q.first) |n| {
        const stack_node: *StackNode = @fieldParentPtr("node", n);

        if (stack_node.edge_idx == 0) {
            try in_path.put(stack_node.idx, {});

            if (stack_node.distance >= end_condition.above_distance_m) {
                if (best == null or stack_node.elevation_gain > best.?.elevation_gain) {
                    best = stack_node;
                }
                _ = in_path.remove(stack_node.idx);
                _ = q.popFirst();
                continue;
            }
        }

        var advanced = false;
        const out_edges = outgoing[stack_node.idx].items;
        while (stack_node.edge_idx < out_edges.len) {
            const edge_idx = out_edges[stack_node.edge_idx];
            const edge = edges[edge_idx];
            stack_node.edge_idx += 1;

            // already in current path => ignore
            if (in_path.contains(edge.v_idx)) continue;

            const new_distance = stack_node.distance + edge.distance;
            const new_elevation_gain = stack_node.elevation_gain + edge.elev_gain;
            const new_elevation_loss = stack_node.elevation_loss + edge.elev_loss;

            // higher elevation route exists to v already
            if (visited.get(edge.v_idx)) |e| {
                if (new_elevation_gain <= e.elevation_gain) {
                    continue;
                }
            }
            const next_node = try arena.allocator().create(StackNode);
            next_node.* = .{
                .idx = edge.v_idx,
                .distance = new_distance,
                .elevation_gain = new_elevation_gain,
                .elevation_loss = new_elevation_loss,
                .prev = stack_node.idx,
            };

            try visited.put(edge.v_idx, next_node);
            q.prepend(&next_node.node);

            advanced = true;
            break;
        }

        if (!advanced) {
            // no more valid children to visit
            _ = in_path.remove(stack_node.idx);
            _ = q.popFirst();
        }
    }

    if (best) |b| {
        std.debug.print("{d}", .{nodes[b.idx].id});
        while (b.prev) |prev_idx| {
            std.debug.print(",{d}", .{nodes[prev_idx].id});
        }
        std.debug.print("\n", .{});
        return PathDetails{ .distance = b.distance, .elevation_gain = b.elevation_gain, .elevation_loss = b.elevation_loss };
    } else {
        return null;
    }
}

test "find elevation route" {
    const testing = std.testing;

    var f = try std.Io.Dir.cwd().openFile(testing.io, "data/switzerland_walkable_100m.zl", .{ .mode = .read_only });
    defer f.close(testing.io);

    var buffer: [1024]u8 = undefined;
    var reader = f.reader(testing.io, &buffer);
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    var bench_g = try graph.DynamicGraph.fromReader(arena.allocator(), &reader.interface);

    const start_idx = bench_g.osm_id_to_node_idx.get(7098605254) orelse @panic("start node not found");

    const dijkstra_details = try solve.Dijkstra(.Path).run(testing.allocator, start_idx, .{ .max_distance = 1000 }, bench_g.nodes.items, bench_g.edges.items, bench_g.outgoing.items);
    defer testing.allocator.free(dijkstra_details.indices);
    const path_details = try compute(testing.allocator, start_idx, bench_g.nodes.items, bench_g.edges.items, bench_g.outgoing.items, .{ .above_distance_m = 1000 }) orelse @panic("no path found");

    std.debug.print("Dijkstra: distance={d}, elevation={d}\n", .{ dijkstra_details.distance, dijkstra_details.elevation });
    std.debug.print("Compute: distance={d}, elevation_gain={d}, elevation_loss={d}\n", .{ path_details.distance, path_details.elevation_gain, path_details.elevation_loss });
}
