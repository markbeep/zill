const std = @import("std");
const s = @import("shared.zig");

/// Growable graph used by the converter while assembling a `.zl` file. Readers
/// (CLI and wasm) use `PackedGraph`, which reads the file in place instead.
pub const DynamicGraph = struct {
    allocator: std.mem.Allocator,

    nodes: std.ArrayList(s.Node),
    edges: std.ArrayList(s.Edge),
    node_edges: std.ArrayList(std.ArrayList(u32)),
    osm_id_to_node_idx: std.AutoHashMap(i64, u32),

    pub fn init(allocator: std.mem.Allocator) DynamicGraph {
        return DynamicGraph{
            .allocator = allocator,
            .nodes = std.ArrayList(s.Node).empty,
            .edges = std.ArrayList(s.Edge).empty,
            .node_edges = std.ArrayList(std.ArrayList(u32)).empty,
            .osm_id_to_node_idx = std.AutoHashMap(i64, u32).init(allocator),
        };
    }

    pub fn deinit(self: *DynamicGraph) void {
        for (self.node_edges.items) |*edge_list| {
            edge_list.deinit(self.allocator);
        }
        self.node_edges.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.osm_id_to_node_idx.deinit();
    }

    pub fn addNode(self: *DynamicGraph, id: i64, lat: f32, lon: f32, elev: ?f32) !u32 {
        if (self.osm_id_to_node_idx.get(id)) |existing_idx| {
            return existing_idx;
        }
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(
            self.allocator,
            s.Node{
                .id = id,
                .lat = lat,
                .lon = lon,
                .elev = if (elev) |e| @trunc(e) else null,
            },
        );
        try self.node_edges.append(self.allocator, std.ArrayList(u32).empty);
        try self.osm_id_to_node_idx.put(id, idx);
        return idx;
    }

    /// Stores one direction of a way segment. The reverse direction is derived
    /// from it at read time, so the file holds each segment exactly once.
    pub fn addEdge(self: *DynamicGraph, u_idx: u32, v_idx: u32, elev_gain: u16, elev_loss: u16, distance: u32) !void {
        const idx: u32 = @intCast(self.edges.items.len);
        try self.edges.append(
            self.allocator,
            s.Edge{
                .u_idx = u_idx,
                .v_idx = v_idx,
                .elev_gain = elev_gain,
                .elev_loss = elev_loss,
                .distance = distance,
            },
        );
        try self.node_edges.items[u_idx].append(self.allocator, idx);
    }

    pub inline fn nodeCount(self: *const DynamicGraph) u32 {
        return @intCast(self.nodes.items.len);
    }

    pub inline fn nodeLat(self: *const DynamicGraph, idx: u32) f32 {
        return self.nodes.items[idx].lat;
    }

    pub inline fn nodeLon(self: *const DynamicGraph, idx: u32) f32 {
        return self.nodes.items[idx].lon;
    }

    pub inline fn nodeElev(self: *const DynamicGraph, idx: u32) ?u16 {
        return self.nodes.items[idx].elev;
    }

    pub inline fn outDegree(self: *const DynamicGraph, idx: u32) u32 {
        return @intCast(self.node_edges.items[idx].items.len);
    }

    pub inline fn halfEdge(self: *const DynamicGraph, idx: u32, k: u32) s.HalfEdge {
        const e = self.edges.items[self.node_edges.items[idx].items[k]];
        return .{ .to = e.v_idx, .gain = e.elev_gain, .loss = e.elev_loss, .distance = e.distance };
    }

    const CHUNK = 4096;

    pub fn exportToWriter(self: *DynamicGraph, writer: *std.Io.Writer) !void {
        const n = self.nodes.items.len;
        const e = self.edges.items.len;
        const layout = s.Sections.init(n, e);

        const header = s.FileHeader{ .node_count = n, .edge_count = e };
        try writer.writeAll(std.mem.asBytes(&header));
        var pos: u64 = @sizeOf(s.FileHeader);

        try padTo(writer, &pos, layout.ids);
        for (self.nodes.items) |nd| try writeU(i64, writer, &pos, nd.id);
        try padTo(writer, &pos, layout.lats);
        for (self.nodes.items) |nd| try writeU(u32, writer, &pos, @bitCast(nd.lat));
        try padTo(writer, &pos, layout.lons);
        for (self.nodes.items) |nd| try writeU(u32, writer, &pos, @bitCast(nd.lon));
        try padTo(writer, &pos, layout.elevs);
        for (self.nodes.items) |nd| try writeU(u16, writer, &pos, nd.elev orelse s.INVALID_ELEV);

        try padTo(writer, &pos, layout.edges_u);
        for (self.edges.items) |ed| try writeU(u32, writer, &pos, ed.u_idx);
        try padTo(writer, &pos, layout.edges_v);
        for (self.edges.items) |ed| try writeU(u32, writer, &pos, ed.v_idx);
        try padTo(writer, &pos, layout.edges_gain);
        for (self.edges.items) |ed| try writeU(u16, writer, &pos, ed.elev_gain);
        try padTo(writer, &pos, layout.edges_loss);
        for (self.edges.items) |ed| try writeU(u16, writer, &pos, ed.elev_loss);
        try padTo(writer, &pos, layout.edges_dist);
        for (self.edges.items) |ed| try writeU(u32, writer, &pos, ed.distance);

        try padTo(writer, &pos, layout.total);
        try writer.flush();
    }
};

pub fn padTo(writer: *std.Io.Writer, pos: *u64, target: u64) !void {
    if (target < pos.*) return error.InvalidFileFormat;
    const zeroes = [_]u8{0} ** 8;
    while (pos.* < target) {
        const len = @min(target - pos.*, zeroes.len);
        try writer.writeAll(zeroes[0..len]);
        pos.* += len;
    }
}

pub fn writeU(comptime T: type, writer: *std.Io.Writer, pos: *u64, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
    pos.* += @sizeOf(T);
}

test "basic graph" {
    var dyn = DynamicGraph.init(std.testing.allocator);
    defer dyn.deinit();

    const node_idx1 = try dyn.addNode(1, 10.0, 20.0, 100.0);
    const node_idx2 = try dyn.addNode(2, 11.0, 21.0, 200.0);
    try dyn.addEdge(node_idx1, node_idx2, 50, 30, 100);

    try std.testing.expect(dyn.nodes.items.len == 2);
    try std.testing.expect(dyn.edges.items.len == 1);

    const edge = dyn.edges.items[0];
    try std.testing.expect(edge.u_idx == node_idx1);
    try std.testing.expect(edge.v_idx == node_idx2);
    try std.testing.expect(edge.elev_gain == 50);
    try std.testing.expect(edge.elev_loss == 30);
    try std.testing.expect(edge.distance == 100);
}

test "outgoing half edges" {
    var dyn = DynamicGraph.init(std.testing.allocator);
    defer dyn.deinit();

    const a = try dyn.addNode(1, 10.0, 20.0, 100.0);
    const b = try dyn.addNode(2, 11.0, 21.0, 200.0);
    const c = try dyn.addNode(3, 12.0, 22.0, 300.0);
    try dyn.addEdge(a, b, 50, 30, 100);
    try dyn.addEdge(a, c, 60, 40, 150);

    try std.testing.expectEqual(@as(u32, 2), dyn.outDegree(a));
    try std.testing.expectEqual(@as(u32, b), dyn.halfEdge(a, 0).to);
    try std.testing.expectEqual(@as(u32, 50), dyn.halfEdge(a, 0).gain);
    try std.testing.expectEqual(@as(u32, 150), dyn.halfEdge(a, 1).distance);
    try std.testing.expectEqual(@as(u32, 0), dyn.outDegree(b));
}

test "export" {
    var dyn = DynamicGraph.init(std.testing.allocator);
    defer dyn.deinit();

    const node_idx1 = try dyn.addNode(1, 10.0, 20.0, 100.0);
    const node_idx2 = try dyn.addNode(2, 11.0, 21.0, 200.0);
    try dyn.addEdge(node_idx1, node_idx2, 50, 30, 100);

    const bytes = try std.testing.allocator.alloc(u8, s.fileSize(2, 1));
    defer std.testing.allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try dyn.exportToWriter(&writer);

    var loaded = try @import("packed_graph.zig").PackedGraph.init(std.testing.allocator, bytes);
    defer loaded.deinit();
    try loaded.index();

    try std.testing.expectEqual(@as(u32, 2), loaded.nodeCount());
    try std.testing.expectEqual(@as(u32, 1), loaded.edgeCount());
    try std.testing.expectEqual(@as(f32, 10.0), loaded.nodeLat(0));
    try std.testing.expectEqual(@as(f32, 21.0), loaded.nodeLon(1));
    try std.testing.expectEqual(@as(?u16, 100), loaded.nodeElev(0));
    try std.testing.expectEqual(@as(u32, 1), loaded.outDegree(0));
    try std.testing.expectEqual(@as(u32, 1), loaded.outDegree(1));
    const out = loaded.halfEdge(0, 0);
    try std.testing.expectEqual(@as(u32, 1), out.to);
    try std.testing.expectEqual(@as(u16, 50), out.gain);
    const back = loaded.halfEdge(1, 0);
    try std.testing.expectEqual(@as(u32, 0), back.to);
    try std.testing.expectEqual(@as(u16, 30), back.gain);
    try std.testing.expectEqual(@as(u16, 50), back.loss);
}
